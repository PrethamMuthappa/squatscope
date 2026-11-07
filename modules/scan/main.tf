data "aws_ecr_repository" "scorer" {
  name = "squatscope-scorer"
}

locals {
  # Same image as the API; each function just runs a different handler in it
  image_uri = "${data.aws_ecr_repository.scorer.repository_url}:${var.image_tag}"
}

# ---------- SQS: the list of domains waiting to be checked ----------

# Messages that failed 3 times end up here, so they can be inspected instead of lost
resource "aws_sqs_queue" "dlq" {
  name                      = "squatscope-${var.env}-scan-dlq"
  message_retention_seconds = 1209600 # 14 days, the maximum
}

resource "aws_sqs_queue" "scan" {
  name                      = "squatscope-${var.env}-scan"
  message_retention_seconds = 86400 # a day: tomorrow's scan re-queues anything stale

  # Must be longer than the enricher's timeout, or a message reappears while still being worked on
  visibility_timeout_seconds = 360

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

# Only the scan queue may send messages into the DLQ
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.scan.arn]
  })
}

# ---------- Shared: Lambda trust policy ----------

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ---------- Generator: builds the lookalike list for one brand ----------

resource "aws_iam_role" "generator" {
  name               = "squatscope-${var.env}-generator"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "generator_logs" {
  role       = aws_iam_role.generator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Put messages on the scan queue, read the findings table (to re-check tracked domains)
data "aws_iam_policy_document" "generator" {
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.scan.arn]
  }

  statement {
    actions   = ["dynamodb:Scan"]
    resources = [var.findings_table_arn]
  }
}

resource "aws_iam_role_policy" "generator" {
  name   = "queue-and-findings"
  role   = aws_iam_role.generator.id
  policy = data.aws_iam_policy_document.generator.json
}

resource "aws_cloudwatch_log_group" "generator" {
  name              = "/aws/lambda/squatscope-${var.env}-generator"
  retention_in_days = 14
}

resource "aws_lambda_function" "generator" {
  function_name = "squatscope-${var.env}-generator"
  role          = aws_iam_role.generator.arn
  package_type  = "Image"
  image_uri     = local.image_uri
  architectures = ["x86_64"]
  memory_size   = 256
  timeout       = 60 # crt.sh can take a while

  image_config {
    command = ["generator.handler"]
  }

  environment {
    variables = {
      SCAN_QUEUE_URL = aws_sqs_queue.scan.url
      FINDINGS_TABLE = var.findings_table_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.generator, aws_iam_role_policy_attachment.generator_logs]
}

# ---------- Enricher: checks and scores each domain from the queue ----------

resource "aws_iam_role" "enricher" {
  name               = "squatscope-${var.env}-enricher"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "enricher_logs" {
  role       = aws_iam_role.enricher.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Read from the scan queue, read/write findings, publish finding events
data "aws_iam_policy_document" "enricher" {
  statement {
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.scan.arn]
  }

  statement {
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [var.findings_table_arn]
  }

  statement {
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.findings.arn]
  }
}

resource "aws_iam_role_policy" "enricher" {
  name   = "queue-and-findings"
  role   = aws_iam_role.enricher.id
  policy = data.aws_iam_policy_document.enricher.json
}

resource "aws_cloudwatch_log_group" "enricher" {
  name              = "/aws/lambda/squatscope-${var.env}-enricher"
  retention_in_days = 14
}

resource "aws_lambda_function" "enricher" {
  function_name = "squatscope-${var.env}-enricher"
  role          = aws_iam_role.enricher.arn
  package_type  = "Image"
  image_uri     = local.image_uri
  architectures = ["x86_64"]
  memory_size   = 256
  timeout       = 60

  image_config {
    command = ["enricher.handler"]
  }

  environment {
    variables = {
      FINDINGS_TABLE = var.findings_table_name
      EVENT_BUS_NAME = aws_cloudwatch_event_bus.findings.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.enricher, aws_iam_role_policy_attachment.enricher_logs]
}

# Lambda polls the queue and hands the enricher 5 messages at a time
resource "aws_lambda_event_source_mapping" "scan_queue" {
  event_source_arn = aws_sqs_queue.scan.arn
  function_name    = aws_lambda_function.enricher.arn
  batch_size       = 5

  # The function reports which messages failed, so only those are retried
  function_response_types = ["ReportBatchItemFailures"]

  # At most 2 copies running: gentle on the free DNS/RDAP services
  scaling_config {
    maximum_concurrency = 2
  }

  depends_on = [aws_iam_role_policy.enricher]
}

# ---------- Alerts: email when failed messages land in the DLQ ----------

resource "aws_sns_topic" "alerts" {
  name = "squatscope-${var.env}-alerts"
}

# AWS emails a confirmation link first; alerts only arrive after it's clicked
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Anything in the DLQ means a domain failed 3 times and needs a look
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "squatscope-${var.env}-scan-dlq-not-empty"
  alarm_description   = "Scan messages failed 3 times and were moved to the dead-letter queue"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn] # email when it fills up
  ok_actions    = [aws_sns_topic.alerts.arn] # and again when it's emptied
}

# ---------- Events: new or changed findings, and who gets told ----------

# The enricher publishes every new or changed finding here; rules pick what matters
resource "aws_cloudwatch_event_bus" "findings" {
  name = "squatscope-${var.env}-findings"
}

# Only high-risk findings that are new or changed are worth an email
resource "aws_cloudwatch_event_rule" "high_risk" {
  name           = "squatscope-${var.env}-high-risk-finding"
  description    = "New or changed findings with high risk"
  event_bus_name = aws_cloudwatch_event_bus.findings.name

  event_pattern = jsonencode({
    source        = ["squatscope.scan"]
    "detail-type" = ["Finding"]
    detail = {
      risk   = ["high"]
      status = ["new", "changed"]
    }
  })
}

# Send matches to the alerts topic, reshaped into a readable email
resource "aws_cloudwatch_event_target" "high_risk_email" {
  rule           = aws_cloudwatch_event_rule.high_risk.name
  event_bus_name = aws_cloudwatch_event_bus.findings.name
  arn            = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      domain       = "$.detail.defanged"
      brand        = "$.detail.brand"
      score        = "$.detail.score"
      status       = "$.detail.status"
      changes      = "$.detail.changes_text"
      reasons      = "$.detail.reasons_text"
      first_seen   = "$.detail.first_seen"
      last_changed = "$.detail.last_changed"
    }
    input_template = "\"[SquatScope] <domain> is <status> (risk <score>/100)\\n\\nWatched brand: <brand>\\nWhat changed: <changes>\\nWhy it's risky: <reasons>\\nFirst seen: <first_seen>\\nLast changed: <last_changed>\""
  }
}

# Who may publish to the alerts topic: this account, CloudWatch alarms, and the rule above
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid       = "AccountOwner"
    actions   = ["SNS:Publish", "SNS:Subscribe", "SNS:GetTopicAttributes", "SNS:SetTopicAttributes", "SNS:ListSubscriptionsByTopic"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchAlarms"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "HighRiskRule"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.high_risk.arn]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}
