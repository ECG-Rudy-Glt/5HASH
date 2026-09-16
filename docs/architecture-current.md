# Architecture actuelle (état du code Terraform)

Ce schéma reflète ce qui est réellement provisionné par [`terraform/`](../terraform) à ce stade — pas encore la cible complète décrite dans le [README](../README.md#1-architecture) (EFS et présentation applicative PrestaShop restent à faire via Ansible).

```mermaid
flowchart TB
    subgraph internet[" "]
        client["Client HTTP"]
    end

    subgraph floci["Floci (émulateur AWS local — localhost.floci.io:4566)"]
        subgraph vpc["VPC ticket-shop — 10.0.0.0/16"]
            subgraph pub["Subnets publics (10.0.0.0/24, 10.0.1.0/24)"]
                alb["ALB ticket-shop-alb\nSG alb: 80 depuis 0.0.0.0/0"]
                nat["NAT Gateway"]
            end

            subgraph priv["Subnets privés (10.0.10.0/24, 10.0.11.0/24)"]
                asg["Auto Scaling Group\nmin 2 / max 4 / desired 2\nLaunch Template (AMI + clé SSH)\nSG app: 80 depuis SG alb"]
                rds[("RDS MySQL\nticket-shop-db\nSG database: 3306 depuis SG app")]
            end

            igw["Internet Gateway"]
        end

        sm["Secrets Manager\nticket-shop/rds/master\n(user/password/host/port générés)"]
    end

    client --> alb
    alb -->|target group\nhealth check /| asg
    asg -.->|EC2 instances\npas encore configurées par Ansible| asg
    asg --> rds
    nat --- igw
    alb --- igw

    tf["random_password"] -.génère.-> sm
    rds -.valeurs publiées.-> sm

    classDef todo stroke-dasharray: 5 5
    class asg,rds todo
```

## Ce qui est en place

- **Réseau** : 1 VPC, 2 subnets publics + 2 subnets privés (2 AZ), Internet Gateway, NAT Gateway + EIP, tables de routage.
- **Sécurité** : 3 security groups (`alb`, `app`, `database`) déclarés avec les bonnes restrictions logiques — ⚠️ non appliquées par Floci (voir limite documentée dans [`modules/security/main.tf`](../terraform/modules/security/main.tf) et confirmée par [floci-io/floci#2564](https://github.com/floci-io/floci/issues/2564)).
- **Calcul** : ALB public + target group (health check `/`) + listener HTTP, Launch Template, Auto Scaling Group (2-4 instances), policy de scaling target-tracking CPU.
- **Base de données** : RDS MySQL en subnet privé, mot de passe généré (`random_password`), publié dans un secret Secrets Manager unique (`ticket-shop/rds/master`) au format JSON (`username`, `password`, `host`, `port`, `dbname`).

## Ce qui manque encore (prochaines étapes)

- **EFS** (stockage médias partagé entre instances) — pas encore codé.
- **Ansible** : inventaire dynamique, rôles `docker`/`prestashop`, lecture du secret RDS, déploiement du conteneur PrestaShop sur les instances de l'ASG — les instances EC2 existent mais ne font tourner aucune application pour l'instant.
- **Backend Terraform distant** (S3 + DynamoDB) — actuellement état local, à migrer.
- **Séparation d'environnements** (dev/staging/prod).
- **Multi-région** — voir [architecture-multi-region.md](architecture-multi-region.md) pour le plan cible.
