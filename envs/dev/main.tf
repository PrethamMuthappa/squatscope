module "website" {
  source = "../../modules/website"
  env    = "dev"
}

module "auth" {
  source   = "../../modules/auth"
  env      = "dev"
  site_url = module.website.url
}

module "api" {
  source            = "../../modules/api"
  env               = "dev"
  image_tag         = var.scorer_image_tag
  state_machine_arn = module.automation.state_machine_arn
  site_url          = module.website.url
  jwt_issuer        = module.auth.issuer
  jwt_audience      = module.auth.client_id
}

module "scan" {
  source              = "../../modules/scan"
  env                 = "dev"
  image_tag           = var.scorer_image_tag
  findings_table_name = module.api.findings_table
  findings_table_arn  = module.api.findings_table_arn
  alert_email         = var.alert_email
}

module "automation" {
  source                 = "../../modules/automation"
  env                    = "dev"
  brands_table_name      = module.api.brands_table
  generator_function_arn = module.scan.generator_function_arn
  alerts_topic_arn       = module.scan.alerts_topic_arn
}
