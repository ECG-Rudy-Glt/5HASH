# Inventaire Ansible stocké dans le state, lu par cloud.terraform.terraform_provider.

data "aws_instances" "app" {
  filter {
    name   = "tag:Name"
    values = ["${local.name}-app"]
  }

  instance_state_names = ["running"]

  depends_on = [module.compute]
}

# Les ids de l'ASG ne sont connus qu'à l'apply : clés statiques, valeurs via element().
resource "ansible_host" "app" {
  for_each = { for idx in range(var.desired_capacity) : tostring(idx) => idx }

  name   = "app-${each.key}"
  groups = ["prestashop"]

  variables = {
    floci_instance = element(data.aws_instances.app.ids, each.value)
    ansible_user   = "root"
    private_ip     = element(data.aws_instances.app.private_ips, each.value)

    # Chemin et non contenu : la clé privée ne doit pas finir dans le state.
    ansible_ssh_private_key_file = ".keys/ticket_shop"
  }

  lifecycle {
    precondition {
      condition     = length(data.aws_instances.app.ids) >= var.desired_capacity
      error_message = "Moins d'instances running que desired_capacity : relancer terraform apply une fois l'ASG stabilisé."
    }
  }
}

resource "ansible_group" "prestashop" {
  name = "prestashop"

  variables = {
    # "environment" est un mot réservé d'Ansible.
    app_environment = var.environment

    db_secret_arn = module.database.secret_arn
    db_endpoint   = module.database.endpoint
    db_port       = module.database.port

    alb_dns_name = module.compute.alb_dns_name
  }
}
