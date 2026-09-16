variable "name" {
  description = "Préfixe de nommage des ressources compute"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "Subnets publics pour l'ALB"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Subnets privés pour les instances applicatives"
  type        = list(string)
}

variable "alb_sg_id" {
  type = string
}

variable "app_sg_id" {
  type = string
}

variable "ami_id" {
  description = "AMI de base pour les instances EC2 (Ansible installe Docker + déploie PrestaShop ensuite)"
  type        = string
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "ssh_public_key" {
  description = "Clé publique SSH injectée sur les instances (utilisée par Ansible) — jamais la clé privée"
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

variable "cpu_target_value" {
  description = "Cible de la politique de scaling target-tracking (% CPU moyen)"
  type        = number
  default     = 60
}
