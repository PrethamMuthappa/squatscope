variable "env" {
  description = "Environment name, e.g. dev or prod"
  type        = string
}

variable "image_tag" {
  description = "Tag of the scorer image in ECR (the scan Lambdas use the same image)"
  type        = string
}

variable "findings_table_name" {
  type = string
}

variable "findings_table_arn" {
  type = string
}
