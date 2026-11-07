data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------- Cognito: who may log in ----------

resource "aws_cognito_user_pool" "this" {
  name           = "squatscope-${var.env}"
  user_pool_tier = "LITE" # free for up to 10,000 monthly users; has everything needed here

  # Log in with an email address
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # Nobody can sign themselves up: users are created by the admin (you)
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  # Every login needs a 6-digit code from an authenticator app
  mfa_configuration = "ON"

  software_token_mfa_configuration {
    enabled = true
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

# Cognito's hosted login page lives at https://<prefix>.auth.us-east-1.amazoncognito.com
resource "aws_cognito_user_pool_domain" "this" {
  domain       = "squatscope-${var.env}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.this.id
}

# The website's entry in Cognito. A browser app can't keep secrets, so there's no client
# secret: it uses the authorization code flow with PKCE instead
resource "aws_cognito_user_pool_client" "web" {
  name         = "squatscope-${var.env}-web"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = ["${var.site_url}/"]
  logout_urls                          = ["${var.site_url}/"]

  explicit_auth_flows = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]

  # Logins last an hour; the site then sends you back to the login page
  access_token_validity = 60
  id_token_validity     = 60
  token_validity_units {
    access_token = "minutes"
    id_token     = "minutes"
  }

  # Don't reveal whether an email address has an account
  prevent_user_existence_errors = "ENABLED"
}
