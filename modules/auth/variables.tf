variable "env" {
  description = "Environment name, e.g. dev or prod"
  type        = string
}

variable "site_url" {
  description = "Website URL; Cognito sends people back here after login and logout"
  type        = string
}
