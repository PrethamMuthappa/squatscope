output "user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "issuer" {
  description = "Who signs the login tokens; the API checks tokens against this"
  value       = "https://${aws_cognito_user_pool.this.endpoint}"
}

output "login_domain" {
  value = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
}
