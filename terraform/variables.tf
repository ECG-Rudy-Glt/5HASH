variable "aws_region" {
  description = "Région AWS (émulée par Floci)"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Préfixe de nommage des ressources"
  type        = string
  default     = "ticket-shop"
}

variable "azs" {
  description = "Zones de disponibilité utilisées"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "ami_id" {
  description = "AMI de base pour les instances EC2 applicatives"
  type        = string
  default     = "ami-12345678"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "ssh_public_key" {
  description = "Clé publique SSH (Ansible) — fournie par l'appelant, jamais committée"
  type        = string
}

variable "min_size" {
  type    = number
  default = 2
}

variable "max_size" {
  type    = number
  default = 4
}

variable "desired_capacity" {
  type    = number
  default = 2
}

variable "db_name" {
  type    = string
  default = "prestashop"
}

variable "db_username" {
  type    = string
  default = "prestashop_admin"
}
