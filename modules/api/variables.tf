variable "env" {
  description = "Environment name, e.g. dev or prod"
  type        = string
}

variable "image_tag" {
  description = "Tag of the scorer image in ECR to run"
  type        = string
}

variable "state_machine_arn" {
  description = "Scan workflow that POST /scan starts"
  type        = string
}

variable "site_url" {
  description = "Website URL, the only origin allowed to call the API from a browser"
  type        = string
}

variable "jwt_issuer" {
  description = "Cognito user pool URL that signs login tokens"
  type        = string
}

variable "jwt_audience" {
  description = "Cognito app client ID the tokens must be issued for"
  type        = string
}
