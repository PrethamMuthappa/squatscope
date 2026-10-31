variable "scorer_image_tag" {
  description = "Scorer image tag to deploy; CI passes the git commit SHA"
  type        = string
  default     = "v1"
}
