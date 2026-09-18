# Taylor Shift's Ticket Shop — Infrastructure

Déploiement et exploitation de l'infrastructure hébergeant l'application e-commerce PrestaShop (billetterie de concerts), provisionnée avec Terraform et configurée avec Ansible, sur un environnement AWS émulé localement avec **Floci** (`http://localhost.floci.io:4566`).

Docs détaillées : [terraform/README.md](terraform/README.md) (infra) · [ansible/README.md](ansible/README.md) (configuration) · [docs/architecture-current.md](docs/architecture-current.md) (schéma à jour) · [docs/architecture-multi-region.md](docs/architecture-multi-region.md) (plan multi-région).

> **Cible = Floci, pas AWS réel.** L'énoncé prévoit que l'évaluateur accède à un endpoint réel — ici, ça suppose que Floci tourne sur la machine qui sert d'évaluation (voir §5). Pas d'accès public en dehors de cette machine tant qu'on ne bascule pas sur du vrai AWS.

## 1. Architecture

```
                         Internet
                            │
                    ┌───────▼────────┐
                    │  ALB (public)  │  SG: 80 depuis 0.0.0.0/0
                    └───────┬────────┘
                            │ target group (health check /)
              ┌─────────────┴─────────────┐
      ┌───────▼───────┐           ┌───────▼───────┐
      │ EC2 (subnet    │   ...     │ EC2 (subnet    │   Auto Scaling Group
      │ privé) PrestaShop│         │ privé) PrestaShop│  SG: 80 depuis ALB SG uniquement
      │ (Docker, via   │           │ (Docker, via   │
      │ Ansible)       │           │ Ansible)       │
      └───────┬───────┘           └───────┬───────┘
              └─────────────┬─────────────┘
                    ┌────────▼────────┐
                    │  RDS MySQL       │  subnet privé
                    │  (managé)        │  SG: 3306 depuis EC2 SG uniquement
                    └──────────────────┘
```

- **Réseau** : 1 VPC, 2 AZ, subnets publics (ALB, NAT) et privés (EC2, RDS).
- **Calcul** : Auto Scaling Group d'instances EC2 exécutant PrestaShop via Docker (déployé par Ansible), derrière un Application Load Balancer.
- **Base de données** : Amazon RDS MySQL, managée, hors du périmètre de scaling applicatif. Multi-AZ activable par environnement (`multi_az`, activé en `prod`).
- **Secret RDS** : mot de passe généré par Terraform, publié dans Secrets Manager, lu par Ansible au déploiement (jamais dupliqué).
- **État Terraform** : backend S3 + verrouillage natif (bootstrap manuel documenté en §7).

### Pourquoi ce découpage EC2 / managé

- RDS géré simplifie la haute disponibilité, les sauvegardes et le failover — un composant qu'on ne veut pas réinventer avec Ansible.
- EC2 + Docker pour PrestaShop respecte la contrainte « au moins une instance EC2 provisionnée par Terraform et configurée par Ansible » tout en gardant le contrôle sur la configuration applicative.

### Ce qui n'est pas encore fait

- **Stockage partagé (EFS)** pour les médias/uploads PrestaShop entre instances scalées — pas encore codé. Tant que ce n'est pas en place, le scaling horizontal fonctionne pour la charge HTTP mais pas pour la cohérence des fichiers uploadés (chaque instance a son propre volume Docker).
- **Sessions PHP** non partagées entre instances (pas de sticky sessions ALB ni de store externalisé) — un panier peut être perdu lors d'un basculement d'instance.
- Voir [docs/architecture-current.md](docs/architecture-current.md) pour l'état détaillé du code par rapport à cette cible.

## 2. Gestion du trafic et scaling

- Le trafic entre par l'ALB, réparti vers les cibles saines du target group (health check HTTP `/`, intervalle 15s).
- L'ASG scale horizontalement sur une politique de target tracking CPU.
- **Instance indisponible** : l'ALB cesse de router vers une cible qui échoue au health check ; l'ASG détecte l'instance `Unhealthy`, la termine et en relance une nouvelle automatiquement.
- **Limites connues** :
  - Sessions PHP non partagées (voir ci-dessus).
  - Pas de stockage média partagé (EFS) — voir ci-dessus.
  - Pas de cache applicatif (Redis/ElastiCache) : sous forte charge, la base de données reste le goulot d'étranglement principal.
  - Le failover RDS Multi-AZ (quand activé) entraîne une coupure de quelques dizaines de secondes.

## 3. Structure du dépôt

```
compose.yml                  # lance Floci (émulateur AWS local, port 4566)
ansible.cfg                  # à la racine — voir ansible/README.md §3
terraform/
  provider.tf, backend.tf, versions.tf
  main.tf, variables.tf, locals.tf, outputs.tf
  ansible.tf                 # inventaire décrit par Terraform (ansible_host/ansible_group)
  envs/
    dev.tfvars, staging.tfvars, prod.tfvars
  modules/
    network/ security/ compute/ database/
ansible/
  inventory.yml               # dynamic inventory via cloud.terraform.terraform_provider
  requirements.yml            # collections & rôle Galaxy
  site.yml
  group_vars/
    prestashop.yml              # comment joindre les instances (port SSH Floci)
    all/vault.yml                 # secrets chiffrés (Ansible Vault)
  roles/
    prestashop/                   # notre rôle
    geerlingguy.docker/           # installé depuis Galaxy (gitignored)
docs/
  architecture-current.md
  architecture-multi-region.md
```

## 4. Prérequis

- Docker (pour Floci et pour PrestaShop sur les instances).
- Terraform >= 1.5, **Ansible-core >= 2.15** (testé en 2.19 et 2.20), AWS CLI.
  > `geerlingguy.docker` utilise `ansible.builtin.deb822_repository`, ajouté en ansible-core 2.15. Le paquet `apt` sur Debian/Ubuntu stable est souvent plus vieux (`2.14.18` sur Debian 12) : installer via `pipx install ansible-core` plutôt que `apt`.
- `python3-boto3`/`python3-botocore` sur le poste de contrôle (lookup Ansible qui lit le secret RDS, pas sur les instances). Sur macOS, injecter dans l'environnement d'Ansible : `pipx inject ansible-core boto3 botocore`.
- Une paire de clés SSH pour Ansible : `mkdir -p .keys && ssh-keygen -t ed25519 -f .keys/ticket_shop -N ""` (`.keys/` est gitignored — `ssh-keygen` ne crée pas le dossier parent tout seul, d'où le `mkdir -p`).
- Pas de compte AWS réel requis : toute l'infra est émulée localement par **Floci**.

## 5. Démarrer Floci

```sh
docker compose up -d
```

Floci écoute sur `http://localhost.floci.io:4566` (identifiants factices `test`/`test` — Floci ne les vérifie jamais, rien à protéger). Ce compose publie aussi le port `80` (écoute HTTP de l'ALB) sur l'hôte.

> Floci ne persiste pas l'état des ressources AWS entre redémarrages du conteneur : `docker compose up -d` qui recrée le conteneur repart d'une infra vide. Éviter de le redémarrer une fois l'infra déployée, sauf pour repartir de zéro (§7 + §8).

## 6. Provider Terraform (pattern commun à tous les modules)

Voir [terraform/provider.tf](terraform/provider.tf) — un seul bloc `provider "aws"` pour tout le projet, avec un `endpoints {}` par service utilisé (`ec2`, `elb`, `elbv2`, `autoscaling`, `rds`, `secretsmanager`, `s3`, `iam`, `sts`).

## 7. Bootstrap du backend Terraform (à faire une seule fois)

Le bucket S3 utilisé comme backend doit exister avant `terraform init`. Le verrouillage est géré nativement par le backend `s3` (`use_lockfile = true`, Terraform ≥ 1.10) — pas besoin de table DynamoDB.

```sh
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test

aws --endpoint-url=http://localhost.floci.io:4566 --region us-east-1 \
  s3api create-bucket --bucket ticket-shop-tfstate
aws --endpoint-url=http://localhost.floci.io:4566 --region us-east-1 \
  s3api put-bucket-versioning --bucket ticket-shop-tfstate --versioning-configuration Status=Enabled
```

Backend déclaré dans [terraform/backend.tf](terraform/backend.tf). Détails complets, environnements (dev/staging/prod) et limitations : [terraform/README.md](terraform/README.md).

## 8. Déploiement

```sh
terraform -chdir=terraform init
terraform -chdir=terraform apply -var-file=envs/dev.tfvars -var "ssh_public_key=$(cat .keys/ticket_shop.pub)"

ansible-galaxy install -r ansible/requirements.yml
ansible-inventory -i ansible/inventory.yml --graph

ansible-playbook -i ansible/inventory.yml ansible/site.yml --ask-vault-pass
ansible-playbook -i ansible/inventory.yml ansible/site.yml --ask-vault-pass   # doit annoncer 0 changement
```

> **Sur macOS** : le lookup Secrets Manager fait planter le worker Ansible forké (`A worker was found in a dead state`). Préfixer les commandes `ansible-playbook`/`ansible` par `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES`.

Endpoint applicatif : `terraform -chdir=terraform output alb_dns_name` (ex. `http://ticket-shop-dev-alb-xxxx.elb.localhost.floci.io/`). Détails du rôle, de l'inventaire dynamique et des limites Docker-in-Docker rencontrées : [ansible/README.md](ansible/README.md).

> **Limitation Floci (corrigée côté rôle Ansible)** : l'ALB émulé réécrit le header `Host` en `<private_ip>:80`, ce qui faisait boucler la redirection canonique de PrestaShop. Le rôle `prestashop` force ce header à la bonne valeur (`RequestHeader set Host`, `mod_headers`) — rien à faire côté opérateur. Détail : [terraform/README.md §6](terraform/README.md#6-limitations-connues-dues-à-floci-pas-au-code).

## 9. Secrets

Aucun secret en clair dans le dépôt, deux mécanismes selon l'origine :

| Secret | Généré par | Stocké dans | Lu par Ansible via |
|---|---|---|---|
| Mot de passe RDS | Terraform (`random_password`) | Secrets Manager | lookup `amazon.aws.secretsmanager_secret` |
| Identifiants admin PrestaShop | Défini par l'équipe | Ansible Vault (`ansible/group_vars/all/vault.yml`) | `--ask-vault-pass` |

Détail complet : [ansible/README.md §5](ansible/README.md#5-les-deux-secrets-deux-mécanismes).

## 10. Exploitation / maintenance

- **Mettre à jour l'application** : modifier le rôle `prestashop` (tag d'image, variables) puis rejouer `ansible-playbook` — le handler ne redéploie que si la configuration a changé.
- **Scaling manuel** : ajuster `min_size`/`max_size`/`desired_capacity` dans `envs/<env>.tfvars` puis `terraform apply`.
- **Rotation du secret RDS** : `terraform taint module.database.random_password.master` puis `apply` — le secret Secrets Manager est republié automatiquement, Ansible le relira au prochain déploiement.
- **Logs applicatifs** : `docker logs` sur le conteneur PrestaShop de chaque instance (accès via Ansible/SSH, pas encore centralisé — piste d'amélioration).

## 11. Contexte projet

Projet de groupe (3 personnes) — module 5HASH Supinfo. Voir l'énoncé complet dans [`readme`](readme) (brief original, traduit en français).
