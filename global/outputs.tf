output "plan_role_arn" {
  value = aws_iam_role.plan.arn
}

output "deploy_role_arn" {
  value = aws_iam_role.deploy.arn
}

output "scorer_repository_url" {
  value = aws_ecr_repository.scorer.repository_url
}
