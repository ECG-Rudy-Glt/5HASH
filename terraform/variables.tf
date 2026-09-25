variable "aws_region" {
  description = "Région AWS"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Préfixe de nommage des ressources"
  type        = string
  default     = "ticket-shop"
}

variable "environment" {
  description = "Environnement déployé (dev, staging, prod) — isole le nommage, la capacité et l'état (via workspace Terraform)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment doit être dev, staging ou prod."
  }
}

variable "multi_az" {
  description = "RDS Multi-AZ (haute disponibilité) — activé en prod"
  type        = bool
  default     = false
}

variable "azs" {
  description = "Zones de disponibilité utilisées"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "vpc_cidr" {
  description = "Bloc CIDR du VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Blocs CIDR des subnets publics (un par AZ)"
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Blocs CIDR des subnets privés (un par AZ)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "ami_id" {
  description = "AMI de base pour les instances EC2 applicatives. Un id inconnu de Floci retombe sur Amazon Linux 2023 sans bootstrap sshd (connexion SSH impossible) : on utilise un nom reconnu du catalogue Floci."
  type        = string
  default     = "ami-debian12"
}

variable "instance_type" {
  description = "Type d'instance EC2 applicative"
  type        = string
  default     = "t3.micro"
}

variable "ssh_public_key" {
  description = "Clé publique SSH (Ansible). Par défaut : contenu de .keys/ticket_shop.pub à la racine du dépôt"
  type        = string
  default     = null
}

variable "min_size" {
  description = "Nombre minimum d'instances dans l'ASG"
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Nombre maximum d'instances dans l'ASG"
  type        = number
  default     = 2
}

variable "desired_capacity" {
  description = "Nombre d'instances souhaité dans l'ASG (aussi le nombre d'hôtes de l'inventaire Ansible)"
  type        = number
  default     = 1
}

variable "db_name" {
  description = "Nom de la base PrestaShop"
  type        = string
  default     = "prestashop"
}

variable "db_username" {
  description = "Utilisateur master RDS"
  type        = string
  default     = "prestashop_admin"
}
