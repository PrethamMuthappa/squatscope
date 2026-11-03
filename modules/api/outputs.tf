output "url" {
  value = aws_apigatewayv2_stage.default.invoke_url
}

output "function_name" {
  value = aws_lambda_function.scorer.function_name
}

output "brands_table" {
  value = aws_dynamodb_table.brands.name
}

output "findings_table" {
  value = aws_dynamodb_table.findings.name
}
