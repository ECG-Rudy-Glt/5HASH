# Plan d'architecture multi-région — Taylor Shift's Ticket Shop

## 1. Objectif

Passer d'une architecture mono-région (VPC unique, 2 AZ) à une architecture **multi-région** : une région primaire qui sert le trafic normal, une région secondaire prête à prendre le relais en cas d'indisponibilité de la région primaire (haute disponibilité) et/ou pour rapprocher les utilisateurs (latence) lors des pics de vente de billets.

## 2. Schéma cible

```
                              Route 53 (routing latency / failover)
                                        │
                ┌───────────────────────┴───────────────────────┐
                │                                                │
        RÉGION A (primaire, ex: eu-west-3)              RÉGION B (secondaire, ex: eu-west-1)
                │                                                │
        ┌───────▼────────┐                              ┌───────▼────────┐
        │  ALB (public)   │                              │  ALB (public)   │
        └───────┬────────┘                              └───────┬────────┘
                │                                                │
      ┌─────────┴─────────┐                            ┌─────────┴─────────┐
      │  ASG PrestaShop    │                            │  ASG PrestaShop    │
      │  (EC2, 2 AZ)       │                            │  (EC2, 2 AZ)       │
      └─────────┬─────────┘                            └─────────┬─────────┘
                │                                                │
        ┌───────▼────────┐                              ┌───────▼────────┐
        │  EFS (région A)  │◄──── réplication ──────────►│ EFS (région B)  │
        └──────────────────┘      (backup/restore ou     └──────────────────┘
                                    DataSync, async)
                │                                                │
        ┌───────▼────────┐                              ┌───────▼────────┐
        │ RDS MySQL        │──── réplique en lecture ───►│ RDS Read Replica│
        │ (writer, région A)│      cross-region           │ (région B)      │
        └──────────────────┘                              └──────────────────┘
```

## 3. Composants par région

| Composant | Région A (primaire) | Région B (secondaire) |
|---|---|---|
| Réseau | VPC + 2 subnets publics + 2 subnets privés (2 AZ) | idem, VPC distinct (CIDR non chevauchant) |
| Calcul | ALB + ASG EC2 (PrestaShop/Docker) | ALB + ASG EC2, capacité réduite (scale-to-zero ou minimale) en veille |
| Base de données | RDS MySQL, instance **writer** | RDS **read replica** cross-region (promue manuellement/automatiquement en cas de bascule) |
| Stockage médias | EFS (source) | EFS répliqué (AWS Backup / DataSync) |
| DNS / routage | Route 53 : politique **latency-based** ou **failover** vers les deux ALB, avec health checks | idem |

## 4. Stratégie de bascule (failover)

1. Route 53 effectue des health checks HTTP sur l'ALB de chaque région.
2. **Politique latency-based** (répartition par proximité) combinée à des enregistrements en **failover** : si la région A ne répond plus aux health checks, Route 53 route tout le trafic vers la région B.
3. Côté données : la read replica RDS de la région B doit être **promue en instance writer** (opération manuelle documentée dans le runbook, ou automatisée via Lambda/Step Functions dans une itération future).
4. EFS n'étant pas nativement multi-région, la réplication se fait par tâche planifiée (AWS Backup cross-region copy ou DataSync) — la fraîcheur des médias sur la région B dépend de la fréquence de cette tâche (RPO à documenter, ex. 15-60 min).

## 5. Pourquoi ce découpage

- **RDS read replica cross-region** plutôt qu'Aurora Global : suffisant pour ce projet (MySQL/MariaDB standard sur PrestaShop), pas besoin de la complexité/coût d'Aurora Global Database.
- **Route 53 failover/latency** plutôt qu'un load balancer global type Global Accelerator : reste dans les services couverts par le projet et par Floci, suffisant pour illustrer la stratégie de bascule.
- **ASG en veille (capacité réduite) sur la région B** plutôt qu'arrêt complet : réduit le temps de bascule (pas de cold start complet) tout en limitant les coûts hors incident.

## 6. Limites assumées

- **RPO non nul** : les données écrites juste avant l'incident (commandes, panier) entre la dernière réplication RDS et la coupure peuvent être perdues — la réplication RDS cross-region est asynchrone.
- **RTO manuel** : la promotion de la réplique RDS n'est pas automatisée dans cette version — bascule en quelques minutes, pas instantanée. À documenter comme axe d'amélioration (Lambda déclenchée par une alarme CloudWatch/Route 53).
- **Médias (EFS)** : la réplication planifiée introduit un décalage ; un produit ajouté juste avant l'incident peut apparaître sans image côté région B jusqu'à la prochaine synchro.
- **Coût double** : deux VPC, deux ASG, deux RDS actifs (writer + replica) — trade-off HA vs coût, à assumer explicitement dans la présentation.

## 7. Implication sur Terraform / Ansible

- **Terraform** : un module `region` (network + compute + database + storage) instancié deux fois via `providers = { aws = aws.region_a }` / `aws.region_b` (alias de provider), plutôt que deux copies de code. Un module `dns` séparé gère les enregistrements Route 53 et référence les deux ALB en sortie des modules régionaux.
- **Ansible** : l'inventaire dynamique (`cloud.terraform.terraform_provider`) doit regrouper les hôtes par région (groupe `region_a` / `region_b`) pour permettre des playbooks ciblés (ex. jouer un rôle spécifique de promotion uniquement sur la région B en cas de bascule).
- **Environnements (dev/staging/prod)** : le multi-région ne s'applique qu'à `prod` (et éventuellement `staging`) pour limiter le coût de `dev`, qui reste mono-région.

## 8. Limite liée à Floci (émulation locale)

Floci tourne comme une **instance unique locale** ([floci.io](https://floci.io/)) : il n'émule pas physiquement deux régions séparées. Pour la démonstration locale, le multi-région sera simulé en :
- déclarant deux providers AWS avec un `region` différent (`region_a` / `region_b`) mais pointant vers le **même endpoint Floci** (`http://localhost.floci.io:4566`) ;
- gardant les ressources logiquement séparées par région/tags/CIDR pour que le code Terraform et les playbooks Ansible soient corrects et portables tels quels vers un vrai compte AWS multi-région.
- documenter explicitement cette limite dans le README et la présentation : le comportement de latence/panne réelle entre régions n'est pas observable en local, seule la structure (réplication, failover DNS, promotion RDS) est démontrée.

## 9. Étapes suivantes

1. Valider le choix des deux régions (ex. `eu-west-3` / `eu-west-1`) et les CIDR VPC.
2. Écrire le module Terraform `region` réutilisable (network + compute + database + storage) avec provider en paramètre.
3. Ajouter le module `dns` (Route 53 : zone, health checks, failover/latency records).
4. Étendre l'inventaire Ansible pour grouper par région.
5. Rédiger le runbook de bascule (promotion RDS, vérification Route 53) dans `docs/`.
6. Mettre à jour le README principal (§ Gestion du trafic et scaling) avec le schéma multi-région et ses limites.
