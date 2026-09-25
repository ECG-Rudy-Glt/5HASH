# Empêche d'appliquer les variables d'un environnement dans le state d'un autre.
resource "terraform_data" "workspace_guard" {
  lifecycle {
    precondition {
      condition     = (terraform.workspace == "default" ? "dev" : terraform.workspace) == var.environment
      error_message = "Workspace \"${terraform.workspace}\" incompatible avec environment = \"${var.environment}\" (dev → default, staging → staging, prod → prod)."
    }
  }
}

module "network" {
  source = "./modules/network"

  name                 = local.name
  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}

module "security" {
  source = "./modules/security"

  name   = local.name
  vpc_id = module.network.vpc_id
}

module "compute" {
  source = "./modules/compute"

  name               = local.name
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids
  alb_sg_id          = module.security.alb_sg_id
  app_sg_id          = module.security.app_sg_id

  ami_id           = var.ami_id
  instance_type    = var.instance_type
  ssh_public_key   = local.ssh_public_key
  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity
}

module "database" {
  source = "./modules/database"

  name               = local.name
  private_subnet_ids = module.network.private_subnet_ids
  database_sg_id     = module.security.database_sg_id

  db_name     = var.db_name
  db_username = var.db_username
  multi_az    = var.multi_az
}
