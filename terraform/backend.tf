# Backend distant S3 (verrouillage natif "use_lockfile", pas de DynamoDB requis
# depuis Terraform >= 1.10) — hébergé sur Floci pour le moment.
# Bootstrap du bucket : voir terraform/README.md §7.
terraform {
  backend "s3" {
    bucket = "ticket-shop-tfstate"
    key    = "ticket-shop/terraform.tfstate"
    region = "us-east-1"

    access_key = "test"
    secret_key = "test"

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    skip_region_validation      = true
    use_path_style               = true
    use_lockfile                = true

    endpoints = {
      s3 = "http://localhost.floci.io:4566"
    }
  }
}
