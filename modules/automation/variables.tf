variable "env" {
  description = "Environment name, e.g. dev or prod"
  type        = string
}

variable "brands_table_name" {
  type = string
}

variable "generator_function_arn" {
  type = string
}

variable "alerts_topic_arn" {
  description = "SNS topic that emails alerts (created by the scan module)"
  type        = string
}

variable "schedule" {
  description = "When the daily scan runs (EventBridge Scheduler cron, UTC)"
  type        = string
  default     = "cron(0 6 * * ? *)" # 06:00 UTC = 11:30 IST
}
