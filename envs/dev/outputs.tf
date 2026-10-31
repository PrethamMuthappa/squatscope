output "site_bucket" {
  value = module.website.bucket_name
}

output "site_url" {
  value = module.website.url
}

output "distribution_id" {
  value = module.website.distribution_id
}
