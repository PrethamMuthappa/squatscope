module "website" {
  source = "../../modules/website"
  env    = "dev"
}

module "api" {
  source    = "../../modules/api"
  env       = "dev"
  image_tag = var.scorer_image_tag
}
