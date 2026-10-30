provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "squatscope"
      ManagedBy   = "terraform"
      Environment = "dev"
    }
  }
}
