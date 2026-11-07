output "site_bucket" {
  value = module.website.bucket_name
}

output "site_url" {
  value = module.website.url
}

output "distribution_id" {
  value = module.website.distribution_id
}

output "api_url" {
  value = module.api.url
}

output "scan_queue_url" {
  value = module.scan.queue_url
}

output "scan_dlq_url" {
  value = module.scan.dlq_url
}

output "generator_function_name" {
  value = module.scan.generator_function_name
}

output "state_machine_arn" {
  value = module.automation.state_machine_arn
}
