locals {
  # Toutes les ressources sont nommées et taguées par environnement, pour
  # cohabiter dans le même compte/backend sans collision (dev/staging/prod).
  name = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
