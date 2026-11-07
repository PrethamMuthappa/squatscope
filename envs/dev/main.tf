module "website" {
  source = "../../modules/website"
  env    = "dev"
}

module "api" {
  source    = "../../modules/api"
  env       = "dev"
  image_tag = var.scorer_image_tag
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
