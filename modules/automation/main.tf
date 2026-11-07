data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name = "squatscope-${var.env}-daily-scan"

  # Built from the name (not the resource) so the role can refer to it without a loop
  state_machine_arn = "arn:aws:states:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:stateMachine:${local.name}"
  brands_table_arn  = "arn:aws:dynamodb:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${var.brands_table_name}"
}

# ---------- Step Functions: one scan, step by step ----------

data "aws_iam_policy_document" "sfn_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${local.name}-sfn"
  assume_role_policy = data.aws_iam_policy_document.sfn_trust.json
}

# See its own running scans, read the brand list, run the generator
data "aws_iam_policy_document" "sfn" {
  statement {
    actions   = ["states:ListExecutions"]
    resources = [local.state_machine_arn]
  }

  statement {
    actions   = ["dynamodb:Scan"]
    resources = [local.brands_table_arn]
  }

  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [var.generator_function_arn]
  }
}

resource "aws_iam_role_policy" "sfn" {
  name   = "scan-steps"
  role   = aws_iam_role.sfn.id
  policy = data.aws_iam_policy_document.sfn.json
}

resource "aws_sfn_state_machine" "scan" {
  name     = local.name
  role_arn = aws_iam_role.sfn.arn

  definition = jsonencode({
    Comment = "Daily scan: for every watched brand, queue its lookalike domains for checking"
    StartAt = "CheckNotAlreadyRunning"
    States = {
      # This run counts itself, so more than 1 running means another scan is in progress
      CheckNotAlreadyRunning = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:sfn:listExecutions"
        Parameters = {
          "StateMachineArn.$" = "$$.StateMachine.Id"
          StatusFilter        = "RUNNING"
        }
        ResultSelector = { "running.$" = "States.ArrayLength($.Executions)" }
        ResultPath     = "$.check"
        Next           = "AlreadyRunning?"
      }

      "AlreadyRunning?" = {
        Type    = "Choice"
        Choices = [{ Variable = "$.check.running", NumericGreaterThan = 1, Next = "ScanAlreadyRunning" }]
        Default = "ListBrands"
      }

      ScanAlreadyRunning = {
        Type  = "Fail"
        Error = "ScanAlreadyRunning"
        Cause = "Another scan is still running; this one was skipped"
      }

      # Read the watched brands straight from DynamoDB, no Lambda needed
      ListBrands = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:dynamodb:scan"
        Parameters = {
          TableName                = var.brands_table_name
          ProjectionExpression     = "#n"
          ExpressionAttributeNames = { "#n" = "name" }
        }
        ResultSelector = { "items.$" = "$.Items" }
        ResultPath     = "$.brands"
        Next           = "ScanEachBrand"
      }

      # One brand at a time, so the free lookup services aren't hammered
      ScanEachBrand = {
        Type           = "Map"
        ItemsPath      = "$.brands.items"
        ItemSelector   = { "brand.$" = "$$.Map.Item.Value.name.S" }
        MaxConcurrency = 1
        ResultPath     = "$.results"
        ItemProcessor = {
          ProcessorConfig = { Mode = "INLINE" }
          StartAt         = "GenerateLookalikes"
          States = {
            GenerateLookalikes = {
              Type       = "Task"
              Resource   = "arn:aws:states:::lambda:invoke"
              Parameters = { FunctionName = var.generator_function_arn, "Payload.$" = "$" }
              OutputPath = "$.Payload"
              # Outside services have bad days: try again after 30s, then 60s
              Retry = [{
                ErrorEquals     = ["States.ALL"]
                IntervalSeconds = 30
                BackoffRate     = 2
                MaxAttempts     = 2
              }]
              End = true
            }
          }
        }
        Next = "Done"
      }

      Done = { Type = "Succeed" }
    }
  })
}

# ---------- Schedule: start the scan every morning ----------

data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.scan.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "start-scan"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "daily" {
  name                         = local.name
  schedule_expression          = var.schedule
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sfn_state_machine.scan.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ trigger = "schedule" })
  }
}

# ---------- Heartbeat: email if no scan has succeeded in 24 hours ----------

resource "aws_cloudwatch_metric_alarm" "scan_missed" {
  alarm_name          = "${local.name}-missed"
  alarm_description   = "No daily scan has succeeded in the last 24 hours"
  namespace           = "AWS/States"
  metric_name         = "ExecutionsSucceeded"
  dimensions          = { StateMachineArn = aws_sfn_state_machine.scan.arn }
  statistic           = "Sum"
  period              = 3600 # 24 one-hour windows...
  evaluation_periods  = 24
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching" # ...and an hour with no success counts as bad

  alarm_actions = [var.alerts_topic_arn]
  ok_actions    = [var.alerts_topic_arn]
}
