# Terraform — Taylor Shift's Ticket Shop

Mise en place et déploiement : [README racine](../README.md) §4 et §5. Schéma et limites d'architecture : [docs/architecture.md](../docs/architecture.md).

## 1. Organisation

```
provider.tf    provider aws pointé sur Floci
backend.tf     backend S3 + verrouillage natif (use_lockfile)
versions.tf    Terraform ≥ 1.10, aws ~> 6.0, random ~> 3.6, ansible/ansible
variables.tf   variables racine (valeurs par défaut = environnement dev)
locals.tf      local.name = "<project_name>-<environment>", tags communs
main.tf        câblage des modules
outputs.tf     alb_dns_name, db_secret_arn, …
ansible.tf     inventaire Ansible (ansible_host / ansible_group)
envs/          dev.tfvars, staging.tfvars, prod.tfvars
modules/
  network/     VPC, subnets publics/privés (2 AZ), IGW, NAT, routage
  security/    security groups alb → app → database
  compute/     ALB, target group, listener, launch template, ASG, scaling CPU
  database/    RDS MySQL, mot de passe généré, secret Secrets Manager
```

- **Isolation des modules** : chaque module ne connaît que ses `variables.tf` et `outputs.tf`. C'est `main.tf` qui les relie, par exemple `module.network.vpc_id` → `module.security`.
- **Tags** : `default_tags` pose `Project`, `Environment` et `ManagedBy` sur toutes les ressources.
- **Clé SSH** : `ssh_public_key` vaut par défaut le contenu de `../.keys/ticket_shop.pub`. On peut la surcharger avec `-var ssh_public_key=...`. Seule la clé publique passe par Terraform.

## 2. Inventaire Ansible ([ansible.tf](ansible.tf))

- La data source `aws_instances` retrouve les instances de l'ASG grâce au tag `Name = <name>-app`.
- `ansible_host` crée un hôte par instance attendue, avec des clés statiques `0..desired_capacity-1`. Les ids ne sont connus qu'à l'`apply` et ne peuvent donc pas servir de clés `for_each`.
- Une `precondition` fait échouer l'`apply` s'il y a moins d'instances *running* que `desired_capacity`. Sans elle, `element()` dupliquerait un hôte en silence.
- `ansible_group "prestashop"` transmet à Ansible l'ARN du secret RDS, l'endpoint de la base et le DNS de l'ALB.

## 3. Environnements

La séparation combine un workspace par environnement (state isolé dans le même bucket) et un fichier `envs/<env>.tfvars`. La ressource `terraform_data.workspace_guard` ([main.tf](main.tf)) bloque le `plan` si les deux ne correspondent pas (par exemple `prod.tfvars` dans le workspace `default`). Commandes et tableau des capacités : [README racine §6](../README.md#6-environnements-dev--staging--prod).

Pour supprimer un environnement :

```sh
terraform -chdir=terraform workspace select <env>
terraform -chdir=terraform destroy -var-file=envs/<env>.tfvars
```

## 4. Limites dues à Floci

- **Security groups non appliqués** : Floci les enregistre mais ne filtre pas le trafic ([floci-io/floci#2564](https://github.com/floci-io/floci/issues/2564)). Le code reste correct pour AWS.
- **`plan` jamais vide après un `apply`** : Floci ne conserve ni l'attribut `enabled` des scaling policies, ni les tags de la key pair. Comme le module `compute` a donc toujours un changement en attente, la data source de `ansible.tf`, qui en dépend, n'est relue qu'à l'`apply` : `ansible_host` apparaît en *known after apply*. Nous ne masquons pas ces dérives avec `ignore_changes`, pour ne pas cacher une vraie dérive sur AWS.
- **Aucune persistance** : recréer le conteneur Floci efface toute l'infrastructure émulée, bucket de state compris. Il faut alors refaire le bootstrap ([README racine §4](../README.md#4-mise-en-place-à-faire-une-fois-avant-la-séquence-de-test)) puis un `apply`.
- **Service partagé** : filtrer par tag `Project` / `Environment` avant toute commande AWS CLI manuelle.
- **AMI** : `ami_id` doit être un nom du catalogue Floci (`ami-debian12`). Un id inconnu donne une Amazon Linux sans sshd.
- **Launch template modifié** : les instances existantes gardent l'ancienne version. Pour les remplacer : `aws … autoscaling start-instance-refresh --auto-scaling-group-name <asg_name>`.
- **Header `Host` réécrit par l'ALB** en `<private_ip>:80` : cela fait boucler la redirection canonique de PrestaShop. C'est corrigé côté Ansible par [force-host.conf.j2](../ansible/roles/prestashop/templates/force-host.conf.j2) (`RequestHeader set Host … early`). Le mot-clé `early` rend le header visible aussi par `mod_rewrite` : sans lui, les images renvoient une erreur 404. Ce réglage n'a aucun effet sur AWS.
