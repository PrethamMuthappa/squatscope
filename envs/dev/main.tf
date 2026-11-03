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
}
