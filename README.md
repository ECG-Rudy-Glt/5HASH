# Taylor Shift's Ticket Shop — Infrastructure

Déploiement et exploitation de l'infrastructure hébergeant l'application e-commerce PrestaShop (billetterie de concerts), provisionnée avec Terraform et configurée avec Ansible, sur un environnement AWS émulé localement avec **Floci** (`http://localhost.floci.io:4566`).

> Statut : infrastructure en cours de construction. Ce README documente l'architecture cible et sera complété au fil de l'implémentation (captures, valeurs de sortie réelles, limites observées).

> ⚠️ **Note d'évaluation** : l'énoncé prévoit que l'évaluateur accède à un endpoint réel et vérifie la connexion à la base de données. Avec Floci comme cible unique (pas d'AWS réel), l'accès externe et la persistance ne sont garantis que sur la machine où Floci tourne — à clarifier avec l'enseignant si la restitution doit se faire sur une VM/poste accessible à l'évaluateur.

## 1. Architecture

```
                         Internet
                            │
                        Route 53 (optionnel)
                            │
                    ┌───────▼────────┐
                    │  ALB (public)  │  SG: 80/443 depuis 0.0.0.0/0
                    └───────┬────────┘
                            │ target group (health check /)
              ┌─────────────┴─────────────┐
              │                           │
      ┌───────▼───────┐           ┌───────▼───────┐
      │ EC2 (AZ-a)     │           │ EC2 (AZ-b)     │   Auto Scaling Group
      │ PrestaShop     │  ...      │ PrestaShop     │   (subnets privés)
      │ (Docker)       │           │ (Docker)       │   SG: 80 depuis ALB SG uniquement
      └───────┬───────┘           └───────┬───────┘
              │                           │
              └─────────────┬─────────────┘
                    ┌────────▼────────┐
                    │   EFS (shared)   │  médias / uploads PrestaShop
                    └──────────────────┘
                            │
                    ┌────────▼────────┐
                    │  RDS MySQL       │  Multi-AZ, subnets privés
                    │  (managé)        │  SG: 3306 depuis EC2 SG uniquement
                    └──────────────────┘
```

- **Réseau** : VPC dédié, 2 AZ minimum, subnets publics (ALB, NAT) et privés (EC2, RDS, EFS).
- **Calcul** : Auto Scaling Group d'instances EC2 exécutant PrestaShop via Docker, derrière un Application Load Balancer.
- **Base de données** : Amazon RDS (MySQL/MariaDB), managée, hors du périmètre de scaling applicatif.
- **Stockage partagé** : Amazon EFS monté sur chaque instance pour les médias uploadés (nécessaire car les instances sont éphémères et interchangeables).
- **État Terraform** : backend S3 + verrouillage DynamoDB (bootstrap manuel documenté en §4).

### Pourquoi ce découpage EC2 / managé

- RDS géré simplifie la haute disponibilité (Multi-AZ), les sauvegardes et le failover automatique de la base — un composant qu'on ne veut pas réinventer avec Ansible.
- EC2 + Docker pour PrestaShop permet de respecter la contrainte « au moins une instance EC2 provisionnée par Terraform et configurée par Ansible » tout en gardant le contrôle sur la configuration applicative.
- EFS résout le problème de partage d'état (uploads produits, images) entre instances scalées horizontalement, sans quoi le scaling casserait la cohérence des données.

## 2. Gestion du trafic et scaling

- Le trafic entre par l'ALB, réparti vers les cibles saines du target group (health checks HTTP périodiques).
- L'ASG scale horizontalement sur une politique de target tracking (ex. CPU moyen ou nombre de requêtes ALB par cible).
- **Instance indisponible** : l'ALB cesse de router vers une cible qui échoue au health check ; l'ASG détecte l'instance `Unhealthy`, la termine et en relance une nouvelle automatiquement (remplacement, pas de perte de capacité).
- **Limites connues** :
  - Les sessions PHP de PrestaShop ne sont pas partagées entre instances par défaut : sans sticky sessions ALB (ou store de session externalisé), un utilisateur peut perdre son panier lors d'un basculement d'instance. À documenter comme compromis, et éventuellement activer la stickiness ALB en mitigation simple.
  - Le failover RDS Multi-AZ entraîne une coupure de quelques dizaines de secondes.
  - Pas de cache applicatif (Redis/ElastiCache) prévu dans la V1 : sous forte charge en pointe de vente, la base de données reste le goulot d'étranglement principal.

## 3. Structure du dépôt

```
compose.yml                # lance Floci (émulateur AWS local, port 4566)
floci-data/                # état persistant de Floci (ignoré par git)
terraform/
  envs/
    dev/
    staging/
    prod/
  modules/
    network/
    security/
    compute/
    database/
    storage/
ansible/
  inventory.yml            # dynamic inventory via cloud.terraform.terraform_provider
  requirements.yml         # collections & rôles Galaxy
  site.yml
  group_vars/
    all/
      vault.yml            # secrets chiffrés (Ansible Vault)
  roles/
    common/
    docker/
    prestashop/
docs/
  presentation/
```

## 4. Prérequis

- Docker (pour Floci et pour PrestaShop sur les instances).
- Terraform >= 1.x, Ansible >= 2.15, collection `cloud.terraform`.
- Une paire de clés SSH (ou accès SSM) pour Ansible.
- Pas de compte AWS réel requis : toute l'infra est émulée localement par **Floci**.

## 5. Démarrer Floci

```sh
docker compose up -d
```

Floci écoute sur `http://localhost.floci.io:4566` (compatible protocole AWS, identifiants factices `test`/`test`).

## 6. Provider Terraform (pattern commun à tous les modules/envs)

```hcl
provider "aws" {
  region     = "us-east-1"
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    ec2                = "http://localhost.floci.io:4566"
    elasticloadbalancing = "http://localhost.floci.io:4566"
    autoscaling         = "http://localhost.floci.io:4566"
    rds                 = "http://localhost.floci.io:4566"
    efs                 = "http://localhost.floci.io:4566"
    s3                  = "http://localhost.floci.io:4566"
    dynamodb            = "http://localhost.floci.io:4566"
    iam                 = "http://localhost.floci.io:4566"
    ssm                 = "http://localhost.floci.io:4566"
  }
}
```

## 7. Bootstrap du backend Terraform (à faire une seule fois)

Le backend S3 + DynamoDB (verrouillage) doit exister dans Floci avant `terraform init`. Étapes prévues, via AWS CLI pointé sur Floci (`--endpoint-url=http://localhost.floci.io:4566`) :

```sh
aws --endpoint-url=http://localhost.floci.io:4566 s3api create-bucket --bucket tfstate-5hash
aws --endpoint-url=http://localhost.floci.io:4566 dynamodb create-table --table-name tf-lock-5hash \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

(Détails exacts — noms de ressources — à préciser une fois le module `envs/<env>/backend.tf` écrit.)

## 8. Déploiement

```sh
terraform -chdir=terraform init
terraform -chdir=terraform apply

ansible-galaxy install -r ansible/requirements.yml
ansible-inventory -i ansible/inventory.yml --graph
ansible-playbook -i ansible/inventory.yml ansible/site.yml --ask-vault-pass
ansible-playbook -i ansible/inventory.yml ansible/site.yml --ask-vault-pass   # doit être idempotent : 0 changed
```

## 9. Secrets

Aucun secret en clair dans le dépôt. Les identifiants de base de données et autres secrets sont chiffrés avec Ansible Vault (`group_vars/all/vault.yml`) et injectés via templates. Le mot de passe vault est demandé à l'exécution (`--ask-vault-pass`), jamais committé.

## 10. Exploitation / maintenance

_À compléter au fil de l'implémentation :_ procédure de mise à jour de l'application, rotation des secrets, scaling manuel, restauration RDS, logs, etc.

## 11. Contexte projet

Projet de groupe (3 personnes) — module 5HASH Supinfo. Voir l'énoncé complet dans [`readme`](readme) (brief original).
