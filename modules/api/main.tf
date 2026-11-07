data "aws_ecr_repository" "scorer" {
  name = "squatscope-scorer"
}

# ---------- DynamoDB: user brands and scan results ----------

# Pay per request: no fixed cost, a few cents at most for a demo
resource "aws_dynamodb_table" "brands" {
  name         = "squatscope-${var.env}-brands"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "name"

  attribute {
    name = "name"
    type = "S"
  }
}

# One row per domain: the latest score for it
resource "aws_dynamodb_table" "findings" {
  name         = "squatscope-${var.env}-findings"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "domain"

  attribute {
    name = "domain"
    type = "S"
  }
}

# ---------- Lambda: runs the scorer container ----------

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scorer" {
  name               = "squatscope-${var.env}-scorer"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

# Lets the function write its logs, nothing else
resource "aws_iam_role_policy_attachment" "scorer_logs" {
  role       = aws_iam_role.scorer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Read/write only these two tables, and start the scan workflow ("Scan now")
data "aws_iam_policy_document" "scorer_tables" {
  statement {
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:Scan"]
    resources = [aws_dynamodb_table.brands.arn, aws_dynamodb_table.findings.arn]
  }

  statement {
    actions   = ["states:StartExecution"]
    resources = [var.state_machine_arn]
  }
}

resource "aws_iam_role_policy" "scorer_tables" {
  name   = "dynamodb-tables"
  role   = aws_iam_role.scorer.id
  policy = data.aws_iam_policy_document.scorer_tables.json
}

# Created up front so logs expire instead of being kept (and billed) forever
resource "aws_cloudwatch_log_group" "scorer" {
  name              = "/aws/lambda/squatscope-${var.env}-scorer"
  retention_in_days = 14
}

resource "aws_lambda_function" "scorer" {
  function_name = "squatscope-${var.env}-scorer"
  role          = aws_iam_role.scorer.arn
  package_type  = "Image"
  image_uri     = "${data.aws_ecr_repository.scorer.repository_url}:${var.image_tag}"
  architectures = ["x86_64"]
  memory_size   = 256
  timeout       = 10

  # Tells the code which tables to use
  environment {
    variables = {
      BRANDS_TABLE      = aws_dynamodb_table.brands.name
      FINDINGS_TABLE    = aws_dynamodb_table.findings.name
      STATE_MACHINE_ARN = var.state_machine_arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.scorer, aws_iam_role_policy_attachment.scorer_logs]
}

# ---------- HTTP API: the public URL in front of the Lambda ----------

resource "aws_apigatewayv2_api" "this" {
  name          = "squatscope-${var.env}"
  protocol_type = "HTTP"

  # Browsers may only call the API from the SquatScope website
  cors_configuration {
    allow_origins = [var.site_url]
    allow_methods = ["GET", "POST", "DELETE"]
    allow_headers = ["content-type", "authorization"]
    max_age       = 3600
  }
}

# Every route needs a valid Cognito login token (sent as "Authorization: Bearer ...")
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.this.id
  name             = "cognito"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    issuer   = var.jwt_issuer
    audience = [var.jwt_audience]
  }
}

resource "aws_apigatewayv2_integration" "scorer" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.scorer.invoke_arn
  payload_format_version = "2.0"
}

# Every route goes to the same Lambda; the code picks the handler by route
resource "aws_apigatewayv2_route" "this" {
  for_each = toset([
    "GET /score",
    "POST /score",
    "GET /brands",
    "POST /brands",
    "DELETE /brands/{name}",
    "GET /findings",
    "POST /scan",
  ])

  api_id             = aws_apigatewayv2_api.this.id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.scorer.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# The two routes used to be separate resources; tell Terraform they were renamed
# so it moves them in state instead of deleting and recreating them
moved {
  from = aws_apigatewayv2_route.score_get
  to   = aws_apigatewayv2_route.this["GET /score"]
}

moved {
  from = aws_apigatewayv2_route.score_post
  to   = aws_apigatewayv2_route.this["POST /score"]
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  # Rate limit so a script hammering the URL can't run up the bill
  default_route_settings {
    throttling_rate_limit  = 5
    throttling_burst_limit = 10
  }
}

# Allows API Gateway to call the function
resource "aws_lambda_permission" "api" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scorer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
