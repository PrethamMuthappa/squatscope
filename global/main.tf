locals {
  # GitHub OIDC sub claim uses owner/repo with immutable numeric IDs
  repo         = "PrethamMuthappa@98420696/squatscope@1431937389"
  state_bucket = "squatscope-tfstate-405134483173"
}

# Lets AWS trust tokens issued by GitHub Actions
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# Only pull request workflows in this repo may assume the plan role
data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.repo}:pull_request"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "squatscope-github-plan"
  assume_role_policy = data.aws_iam_policy_document.plan_trust.json
}

# Plan only needs to read
resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ...except the state lock file, which plan writes and deletes
data "aws_iam_policy_document" "plan_lock" {
  statement {
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/*.tflock"]
  }
}

resource "aws_iam_role_policy" "plan_lock" {
  name   = "state-lock"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_lock.json
}

# Only workflows running on the main branch of this repo may assume the deploy role
data "aws_iam_policy_document" "deploy_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "squatscope-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_trust.json
}

# Apply creates and changes resources across many services; scoped down later
resource "aws_iam_role_policy_attachment" "deploy_admin" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Container warehouse for the scorer Lambda image
resource "aws_ecr_repository" "scorer" {
  name                 = "squatscope-scorer"
  image_tag_mutability = "IMMUTABLE" # a tag always points at the same image

  image_scanning_configuration {
    scan_on_push = true # check each new image for known vulnerabilities
  }
}

# Keep storage costs near zero: only the 10 newest images are kept
resource "aws_ecr_lifecycle_policy" "scorer" {
  repository = aws_ecr_repository.scorer.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
