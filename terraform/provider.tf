# Provider pointé vers Floci (émulateur AWS local, http://localhost.floci.io:4566)
# Même pattern que workshop-2 : identifiants factices, validations réelles désactivées.
provider "aws" {
  region     = var.aws_region
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    ec2                   = "http://localhost.floci.io:4566"
    elb                   = "http://localhost.floci.io:4566"
    elbv2                 = "http://localhost.floci.io:4566"
    autoscaling           = "http://localhost.floci.io:4566"
    rds                   = "http://localhost.floci.io:4566"
    efs                   = "http://localhost.floci.io:4566"
    secretsmanager        = "http://localhost.floci.io:4566"
    s3                    = "http://localhost.floci.io:4566"
    dynamodb              = "http://localhost.floci.io:4566"
    iam                   = "http://localhost.floci.io:4566"
    sts                   = "http://localhost.floci.io:4566"
  }
}
