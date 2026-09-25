variable "name" {
  description = "Préfixe de nommage des ressources base de données"
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets privés pour le DB subnet group"
  type        = list(string)
}

variable "database_sg_id" {
  description = "Security group de l'instance RDS"
  type        = string
}

variable "engine" {
  description = "Moteur RDS"
  type        = string
  default     = "mysql"
}

variable "engine_version" {
  description = "Version du moteur RDS"
  type        = string
  default     = "8.0"
}

variable "instance_class" {
  description = "Classe d'instance RDS"
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Stockage alloué (Go)"
  type        = number
  default     = 20
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

variable "multi_az" {
  description = "Haute disponibilité RDS (Multi-AZ)"
  type        = bool
  default     = false
}
