module "network" {
  source = "./modules/network"

  name                  = var.project_name
  vpc_cidr              = var.vpc_cidr
  azs                   = var.azs
  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
}

module "security" {
  source = "./modules/security"

  name   = var.project_name
  vpc_id = module.network.vpc_id
}

module "compute" {
  source = "./modules/compute"

  name                = var.project_name
  vpc_id              = module.network.vpc_id
  public_subnet_ids   = module.network.public_subnet_ids
  private_subnet_ids  = module.network.private_subnet_ids
  alb_sg_id           = module.security.alb_sg_id
  app_sg_id           = module.security.app_sg_id

  ami_id            = var.ami_id
  instance_type     = var.instance_type
  ssh_public_key    = var.ssh_public_key
  min_size          = var.min_size
  max_size          = var.max_size
  desired_capacity  = var.desired_capacity
}

module "database" {
  source = "./modules/database"

  name                = var.project_name
  private_subnet_ids  = module.network.private_subnet_ids
  database_sg_id      = module.security.database_sg_id

  db_name     = var.db_name
  db_username = var.db_username
}
