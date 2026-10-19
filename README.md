# TD2 — NovaShop sur K3s

Auteur : IMANI Mourad — INSA CVL

Application 3-tiers déployée sur une VM OpenStack :
- frontend nginx : 2 réplicas ;
- backend Python : 2 réplicas ;
- PostgreSQL 16 : StatefulSet avec PVC de 1 Gi.

## Organisation

- terraform/ : provisionnement OpenStack.
- ansible/ : prérequis système, installation K3s et récupération du kubeconfig.
- helm/postgres/ : base et données initiales.
- helm/backend/ : API Python.
- helm/frontend/ : interface web, nginx et Ingress.
- sql/ : migration du compteur de visites.

## Architecture

Terraform crée la VM, le groupe de sécurité et l'IP flottante.
Ansible configure la VM par SSH et installe K3s.
Helm déploie les trois charts via un tunnel SSH vers l'API Kubernetes.

Trafic applicatif :
Navigateur → Traefik → nginx → API Python → PostgreSQL.

## Prérequis

Exécuter les outils sur l'hôte DevStack avec le compte stack.

Installer Terraform, Ansible, sshpass, Helm, kubectl et le client OpenStack.
Charger les identifiants OpenStack dans les variables d'environnement.

Les ressources suivantes doivent déjà exister :
- projet asl-project et utilisateur autorisé ;
- réseau asl-net, sous-réseau asl-subnet et routeur vers public ;
- réseau externe public ;
- image ubuntu-22.04-asl ;
- flavor m1.medium ;
- paire de clés asl-key.

Ces ressources existantes sont référencées par des data sources lorsque nécessaire.

## Provisionnement

```bash
source ~/devstack/asl-openrc
cd terraform
cp example.tfvars terraform.tfvars
# Adapter login dans terraform.tfvars.
terraform init
terraform validate
terraform plan
terraform apply
terraform output -raw ansible_inventory > ../ansible/inventory.ini
chmod 600 ../ansible/inventory.ini
```

## Configuration

```bash
cd ../ansible
ansible-playbook playbook.yml --ask-pass
```

L'inventaire utilise l'authentification SSH par mot de passe du laboratoire.
Le mot de passe est saisi à l'exécution et n'est pas enregistré dans l'inventaire.
Le kubeconfig est enregistré localement avec les permissions 0600.

## Tunnel Kubernetes

Depuis la racine du projet, dans un terminal dédié :

```bash
FIP=$(terraform -chdir=terraform output -raw floating_ip)
ssh -N -L 127.0.0.1:6443:127.0.0.1:6443 \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  "ubuntu@$FIP"
```

Laisser ce terminal ouvert. Dans le terminal de travail :

```bash
export KUBECONFIG="$PWD/ansible/kubeconfig"
kubectl get nodes
```

Le groupe de sécurité autorise les ports entrants 22, 80 et 443.
L'API Kubernetes sur 6443 est utilisée à travers SSH.

## Déploiement applicatif, bonus inclus

Depuis la racine du projet, avec KUBECONFIG défini et le tunnel actif :

```bash
helm upgrade --install postgres ./helm/postgres \
  -n td2 --create-namespace --wait --timeout 5m

kubectl -n td2 exec -i postgres-0 -- \
  psql -v ON_ERROR_STOP=1 -U app -d appdb \
  < sql/001-create-visits.sql

helm upgrade --install backend ./helm/backend \
  -n td2 --wait --timeout 5m

helm upgrade --install frontend ./helm/frontend \
  -n td2 --wait --timeout 5m
```

La migration doit précéder l'utilisation du compteur.
Le script d'initialisation PostgreSQL ne s'exécute que sur une base vide.

## Vérifications

```bash
helm list -n td2
kubectl -n td2 get pods,svc,ingress,pvc
FIP=$(terraform -chdir=terraform output -raw floating_ip)
curl -I "http://$FIP/"
curl -s "http://$FIP/api/items"
curl -s "http://$FIP/api/visits"
```

Le header X-Pod-Name permet d'identifier le frontend répondant.
L'API renvoie également le nom du pod backend.

Le compteur enregistre un appel à /api/visits, pas un visiteur unique.
L'interface l'appelle à chaque actualisation, toutes les cinq secondes.

## Idempotence et restauration

- Terraform : un nouveau plan indique No changes.
- Ansible : un second passage immédiat indique changed=0.
- Le cache APT peut être actualisé après expiration de cache_valid_time.
- Helm : un upgrade sans modification conserve les UID des pods.
- Les annotations checksum déclenchent un rollout lorsque le code change.
- La suppression d'un pod frontend entraîne son remplacement automatique.

Bonus validé :
- backend révision 3 : ajout du compteur ;
- rollback vers la révision 2 : nouvelle révision 4, /api/visits renvoie 404 ;
- les données de visites restent présentes ;
- redéploiement du chart local : révision 5, compteur de nouveau disponible.

Les numéros de révision correspondent à cette exécution du TD.

## Choix et limites du laboratoire

PostgreSQL utilise un StatefulSet pour son identité stable et son volume associé.
PGDATA pointe vers /var/lib/postgresql/data/pgdata.

Le stockage local-path conserve les données lors du remplacement du pod,
mais reste lié au disque de la VM. Il ne protège pas contre sa destruction.

Le cluster est mono-nœud : deux réplicas applicatifs ne constituent pas
une haute disponibilité face à une panne de la VM.

Les identifiants de démonstration présents dans cloud-init et les values Helm
sont réservés à ce laboratoire. Les identifiants OpenStack, les clés privées,
le state Terraform et le kubeconfig ne doivent pas être publiés.

Les images utilisent des tags et pg8000 est installé au démarrage :
ces dépendances ne sont pas toutes figées pour une reproduction à l'identique.

## Nettoyage final

Après avoir conservé les preuves :

```bash
helm uninstall frontend backend postgres -n td2
kubectl -n td2 delete pvc data-postgres-0
kubectl delete namespace td2
terraform -chdir=terraform destroy
```

Terraform gère sept ressources : VM, groupe de sécurité, trois règles entrantes,
IP flottante et association de cette IP.

Le réseau, le sous-réseau, le routeur, l'image, le flavor et la paire de clés
préexistants ne sont pas détruits par ce projet Terraform.

## Pipeline en une commande

Après chargement de l'OpenRC et création de terraform/terraform.tfvars :

```bash
./deploy.sh
```

Le script enchaîne Terraform, la génération de l'inventaire, Ansible,
un tunnel SSH temporaire, les trois charts Helm et la migration SQL.

Il demande les mots de passe SSH nécessaires et la confirmation Terraform
si des changements sont proposés. Il automatise l'enchaînement mais reste interactif.

Le tunnel temporaire utilise le port local 16443 et se ferme à la fin.
Le tunnel interactif sur 6443 reste indépendant.
