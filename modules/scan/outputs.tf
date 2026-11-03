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
