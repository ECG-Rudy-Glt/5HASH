# Terraform — Taylor Shift's Ticket Shop

Documentation du code Terraform : architecture provisionnée, comment le lancer, et comment l'utiliser sur plusieurs environnements (dev / staging / prod).

Pour le schéma détaillé et l'état d'avancement (ce qui est fait / pas encore fait), voir [docs/architecture-current.md](../docs/architecture-current.md). Pour le plan multi-région à venir, voir [docs/architecture-multi-region.md](../docs/architecture-multi-region.md).

## 1. Architecture provisionnée

```
terraform/
  provider.tf     # provider aws pointé sur Floci (localhost.floci.io:4566)
  versions.tf      # contraintes de version (aws ~>6.0, random ~>3.6)
  variables.tf      # variables du root module
  locals.tf         # local.name = "<project_name>-<environment>", tags communs
  main.tf           # câblage des modules
  outputs.tf
  backend.tf         # backend S3 distant + verrouillage natif
  ansible.tf          # inventaire décrit par Terraform (ansible_host/ansible_group)
  envs/
    dev.tfvars
    staging.tfvars
    prod.tfvars
  modules/
    network/    # VPC, subnets publics/privés (2 AZ), IGW, NAT Gateway, routage
    security/   # security groups (alb, app, database)
    compute/    # ALB + target group + listener, launch template, ASG, scaling policy CPU
    database/   # RDS MySQL + mot de passe généré + secret Secrets Manager
```

Chaque module est indépendant et ne connaît que ses `variables.tf` / `outputs.tf` — c'est `main.tf` à la racine qui les relie (`module.network.vpc_id` → `module.security`, etc.). Toutes les ressources sont nommées via `local.name` (`<project_name>-<environment>`, ex. `ticket-shop-dev`) pour cohabiter sans collision entre environnements dans le même backend.

**Chemin du trafic** : Internet → ALB (subnets publics, SG `alb`) → target group (health check `/`) → instances EC2 de l'ASG (subnets privés, SG `app`, exécutent PrestaShop en Docker, déployé par Ansible) → RDS MySQL (subnet privé, SG `database`). Le mot de passe RDS est généré par Terraform (`random_password`) et publié dans un secret Secrets Manager unique (`<name>/rds/master`) qu'Ansible lit au déploiement — jamais dupliqué en clair.

**L'inventaire Ansible aussi vient de Terraform** ([`ansible.tf`](ansible.tf)) : des ressources `ansible_host`/`ansible_group` (provider `ansible/ansible`) qui n'existent que dans le state, lues par le greffon `cloud.terraform.terraform_provider` côté Ansible — voir [`ansible/README.md`](../ansible/README.md) pour le détail.

## 2. Prérequis

- Terraform >= 1.5
- Docker + Docker Compose (pour Floci)
- Floci démarré **depuis la racine du dépôt** :
  ```sh
  docker compose up -d
  ```
- Une paire de clés SSH pour Ansible (la clé **publique** est passée à Terraform, jamais la privée) :
  ```sh
  mkdir -p .keys
  ssh-keygen -t ed25519 -f .keys/ticket_shop -N ""
  ```

## 3. Lancer le projet (environnement par défaut : dev)

```sh
cd terraform
terraform init

terraform apply \
  -var-file=envs/dev.tfvars \
  -var "ssh_public_key=$(cat .keys/ticket_shop.pub)"
```

> La séquence de test officielle du projet (`terraform -chdir=terraform init && terraform -chdir=terraform apply`, sans `-var-file`) applique les valeurs par défaut du root module, équivalentes à l'environnement `dev`.

Outputs utiles après apply :

```sh
terraform output alb_dns_name     # endpoint HTTP de l'application
terraform output db_secret_arn    # ARN du secret RDS (lu par Ansible)
```

## 4. Utiliser plusieurs environnements (dev / staging / prod)

La séparation d'environnement combine deux mécanismes :

1. **Un fichier de variables par environnement** (`envs/dev.tfvars`, `envs/staging.tfvars`, `envs/prod.tfvars`) — capacité de l'ASG, taille d'instance, RDS Multi-AZ.
2. **Un workspace Terraform par environnement** — isole le state (donc les ressources) de chaque environnement dans le même backend, sans dupliquer le code.

```sh
# Première utilisation d'un environnement : créer son workspace
terraform workspace new staging
terraform workspace new prod

# Basculer sur un environnement et le déployer
terraform workspace select staging
terraform apply -var-file=envs/staging.tfvars -var "ssh_public_key=$(cat .keys/ticket_shop.pub)"

terraform workspace select prod
terraform apply -var-file=envs/prod.tfvars -var "ssh_public_key=$(cat .keys/ticket_shop.pub)"

# Revenir sur dev
terraform workspace select default
```

| Environnement | Fichier | Instance | ASG (min/max/desired) | RDS Multi-AZ |
|---|---|---|---|---|
| dev | `envs/dev.tfvars` | t3.micro | 1 / 2 / 1 | non |
| staging | `envs/staging.tfvars` | t3.micro | 2 / 3 / 2 | non |
| prod | `envs/prod.tfvars` | t3.small | 2 / 6 / 2 | oui |

Chaque workspace a son propre state (`terraform.tfstate.d/<workspace>/` en local, ou préfixé par workspace dans un backend S3 distant), donc `terraform destroy` sur `staging` n'affecte jamais `prod` ou `dev`. Toutes les ressources sont en plus nommées et taguées `Environment = <env>` (voir `local.common_tags` dans `locals.tf`) pour les repérer facilement dans la console/CLI.

## 5. Nettoyage

```sh
terraform workspace select <env>
terraform destroy -var-file=envs/<env>.tfvars -var "ssh_public_key=..."
```

## 6. Limitations connues (dues à Floci, pas au code)

- **Security groups non appliqués** : Floci accepte et restitue les SG (control-plane) mais ne filtre pas réellement le trafic — voir commentaire dans [`modules/security/main.tf`](modules/security/main.tf) et [floci-io/floci#2564](https://github.com/floci-io/floci/issues/2564). Le code reste correct et portable vers un vrai compte AWS.
- **`aws_autoscaling_policy`** : Floci ne persiste pas l'attribut `enabled` des scaling policies (bascule `false → true` à chaque apply). Comportement normal sur AWS réel — non corrigé côté code pour ne pas masquer une vraie dérive avec `ignore_changes`.
- **Backend S3 sur Floci** : state distant (`s3://ticket-shop-tfstate/ticket-shop/terraform.tfstate`, verrouillage natif `use_lockfile`) déclaré dans [`backend.tf`](backend.tf) — voir bootstrap au README racine §7. Reste pour l'instant hébergé sur Floci (donc local à la machine de dev, pas accessible par une CI hébergée) ; migration vers un bucket réel (Scaleway Object Storage ou AWS S3) à faire si on active une CI/CD fonctionnelle.
- **Floci est un service partagé** sur la machine du poste de dev (un seul conteneur pour tous les projets du cours) : `terraform destroy` ne touche que les ressources de ce state, mais penser à filtrer par tag `Project`/`Environment` avant toute commande AWS CLI manuelle pour ne pas impacter d'autres projets.
- **Floci ne persiste pas l'état complet entre redémarrages du conteneur** : recréer le conteneur Floci (`docker compose up -d` après une modification de `compose.yml`, par ex.) efface toute l'infra émulée (vérifié empiriquement — VPC, ALB, RDS, secrets, tout). Le state Terraform distant survit (c'est du S3 émulé, donc lui aussi perdu en fait) : après un redémarrage de Floci, repartir du bootstrap (§ README racine 7) puis d'un `apply` complet.
- **`ami_id` doit être un nom reconnu du catalogue Floci** (`ami-debian12` par défaut) : un id arbitraire retombe sur Amazon Linux 2023 sans bootstrap sshd, rendant l'instance injoignable en SSH.
- **Changer le launch template (AMI, clé SSH, type d'instance) ne remplace pas les instances existantes de l'ASG** : `terraform apply` met à jour le launch template, mais les instances déjà lancées continuent de tourner avec l'ancienne version tant qu'elles ne sont pas recréées. Forcer un rafraîchissement : `aws ... autoscaling start-instance-refresh --auto-scaling-group-name <asg_name>`.
- **L'ALB émulé ne transmet pas le header `Host` d'origine** : Floci le réécrit en `<private_ip>:80`. PrestaShop compare ce header à `PS_SHOP_DOMAIN` et redirige sinon vers son domaine canonique — boucle infinie puisque la redirection repasse par le même ALB. Corrigé côté rôle Ansible : [`force-host.conf`](../ansible/roles/prestashop/templates/force-host.conf.j2) force le `Host` via `mod_headers` avant qu'il n'atteigne l'appli (`ansible/roles/prestashop/tasks/main.yml`, `docker-compose.yml.j2`). Le mot-clé `early` est nécessaire : sans lui, PHP voit le bon `Host` mais pas `mod_rewrite`, et les règles de réécriture d'images restent cassées (404 sur toutes les images produit). Sans effet sur un vrai AWS.
