data "aws_ecr_repository" "scorer" {
  name = "squatscope-scorer"
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

  depends_on = [aws_cloudwatch_log_group.scorer, aws_iam_role_policy_attachment.scorer_logs]
}

# ---------- HTTP API: the public URL in front of the Lambda ----------

resource "aws_apigatewayv2_api" "this" {
  name          = "squatscope-${var.env}"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST"]
    allow_headers = ["content-type"]
  }
}

resource "aws_apigatewayv2_integration" "scorer" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.scorer.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "score_get" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /score"
  target    = "integrations/${aws_apigatewayv2_integration.scorer.id}"
}

resource "aws_apigatewayv2_route" "score_post" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /score"
  target    = "integrations/${aws_apigatewayv2_integration.scorer.id}"
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
