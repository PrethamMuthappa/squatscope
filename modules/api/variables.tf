variable "env" {
  description = "Environment name, e.g. dev or prod"
  type        = string
}

variable "image_tag" {
  description = "Tag of the scorer image in ECR to run"
  type        = string
}
