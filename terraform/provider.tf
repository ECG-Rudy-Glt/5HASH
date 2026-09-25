# Floci (émulateur AWS local) : identifiants factices, validations désactivées.
provider "aws" {
  region     = var.aws_region
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  default_tags {
    tags = local.common_tags
  }

  endpoints {
    ec2            = "http://localhost.floci.io:4566"
    elb            = "http://localhost.floci.io:4566"
    elbv2          = "http://localhost.floci.io:4566"
    autoscaling    = "http://localhost.floci.io:4566"
    rds            = "http://localhost.floci.io:4566"
    secretsmanager = "http://localhost.floci.io:4566"
    s3             = "http://localhost.floci.io:4566"
    iam            = "http://localhost.floci.io:4566"
    sts            = "http://localhost.floci.io:4566"
  }
}
