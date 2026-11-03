variable "scorer_image_tag" {
  description = "Scorer image tag to deploy. CI passes the git tree hash of app/scorer"
  type        = string
}

variable "alert_email" {
  description = "Where alert emails go. Kept out of the public repo: CI reads it from the ALERT_EMAIL repo secret"
  type        = string
  sensitive   = true
}
