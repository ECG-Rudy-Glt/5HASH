variable "name" {
  description = "Préfixe de nommage des ressources réseau"
  type        = string
}

variable "vpc_cidr" {
  description = "Bloc CIDR du VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Zones de disponibilité utilisées (2 minimum)"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "Blocs CIDR des subnets publics (un par AZ)"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "Blocs CIDR des subnets privés (un par AZ)"
  type        = list(string)
}
