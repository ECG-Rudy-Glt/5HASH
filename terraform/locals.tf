locals {
  name = "${var.project_name}-${var.environment}"

  ssh_public_key = var.ssh_public_key != null ? var.ssh_public_key : file("${path.root}/../.keys/ticket_shop.pub")

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
