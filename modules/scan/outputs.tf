output "queue_url" {
  value = aws_sqs_queue.scan.url
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}

output "generator_function_name" {
  value = aws_lambda_function.generator.function_name
}

output "enricher_function_name" {
  value = aws_lambda_function.enricher.function_name
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "generator_function_arn" {
  value = aws_lambda_function.generator.arn
}

output "findings_bus_name" {
  value = aws_cloudwatch_event_bus.findings.name
}
