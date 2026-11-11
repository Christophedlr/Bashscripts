# Sauvegarde et restauration Docker

Deux scripts Bash pour sauvegarder puis restaurer les images Docker installées
et les données des volumes.

| Script              | Rôle                                                        |
|---------------------|-------------------------------------------------------------|
| `docker-backup.sh`  | Sauvegarde les images et les volumes dans un dossier daté   |
| `docker-restore.sh` | Restaure tout ou partie d'une sauvegarde                    |
| `docker-backup.cron` | Tâche cron de sauvegarde hebdomadaire (pour `/etc/cron.d`) |

## Prérequis

- Bash, `gzip`, `sha256sum` (coreutils)
- Docker, avec les droits pour l'utiliser (groupe `docker` ou `sudo`)
- `jq` (recommandé, pour la restauration) : sert à recréer les volumes avec
  leurs labels, leur pilote et leurs options. Sans `jq`, les volumes sont
  recréés sans ces informations et un avertissement est affiché.
- Une image utilitaire pour archiver et extraire les volumes, `alpine:3.20`
  par défaut. Elle est téléchargée automatiquement si elle est absente. Pour
  en utiliser une autre, définissez la variable `HELPER_IMAGE`.

## Sauvegarde : `docker-backup.sh`

```
docker-backup.sh [-o DOSSIER] [-i] [-v] [-s] [-k JOURS] [-h]
```

| Option     | Effet                                                                  |
|------------|------------------------------------------------------------------------|
| `-o DOSSIER` | Dossier racine des sauvegardes (défaut : `./backups`)                |
| `-i`       | Sauvegarder uniquement les images                                      |
| `-v`       | Sauvegarder uniquement les volumes                                     |
| `-s`       | Arrêter les conteneurs utilisant un volume pendant sa sauvegarde, puis les redémarrer |
| `-k JOURS` | Supprimer les sauvegardes de plus de `JOURS` jours                     |
| `-h`       | Afficher l'aide                                                        |

### Exemples

```bash
./docker-backup.sh                  # images + volumes dans ./backups
./docker-backup.sh -o /mnt/nas -s   # autre dossier, conteneurs arrêtés pendant la sauvegarde
./docker-backup.sh -v -k 7          # volumes seulement, supprime les sauvegardes de plus de 7 jours
```

### Fonctionnement

- **Images** : chaque image taguée est enregistrée avec `docker save` puis
  compressée. Une image portant plusieurs tags n'est enregistrée qu'une fois,
  avec tous ses tags. Les images sans tag (`<none>`) sont ignorées.
- **Volumes** : un conteneur temporaire monte chaque volume **en lecture
  seule** et en fait une archive `tar.gz`. La configuration du volume
  (`docker volume inspect`) est enregistrée à côté, dans un fichier `.json`.
  Les fichiers produits appartiennent à l'utilisateur qui lance le script.
- Un fichier `SHA256SUMS` est créé pour vérifier les archives.
- Le script s'arrête avec le code `1` si un élément n'a pas pu être
  sauvegardé ; les autres éléments sont tout de même traités.

> **Bases de données** : utilisez `-s` pour les volumes de bases de données
> (MariaDB, PostgreSQL…). Copier les fichiers d'une base en cours
> d'utilisation peut donner une sauvegarde incohérente. Avec `-s`, les
> conteneurs sont redémarrés même si le script est interrompu.

### Contenu d'une sauvegarde

```
backups/
└── 20261111-144307/
    ├── SHA256SUMS
    ├── images/
    │   ├── manifest.tsv               # ID  fichier  tags
    │   └── bateau_openttd_15.3.tar.gz
    └── volumes/
        ├── php_mariadb_data.json      # configuration du volume (labels, pilote…)
        └── php_mariadb_data.tar.gz    # données du volume
```

Dans les noms de fichiers des images, les caractères `/`, `:` et `@` sont
remplacés par `_`.

## Restauration : `docker-restore.sh`

```
docker-restore.sh [-i] [-v] [-f] [-s] [-n] [-l] [-h] DOSSIER [NOM...]
```

| Argument / option | Effet                                                           |
|-------------------|-----------------------------------------------------------------|
| `DOSSIER`         | Dossier d'une sauvegarde (ex. `./backups/20261111-144307`)       |
| `NOM...`          | Ne restaurer que ces éléments : nom de volume, référence d'image (`nginx:latest`) ou nom de fichier sans `.tar.gz` |
| `-i`              | Restaurer uniquement les images                                  |
| `-v`              | Restaurer uniquement les volumes                                 |
| `-f`              | Écraser le contenu des volumes existants non vides               |
| `-s`              | Arrêter les conteneurs utilisant un volume pendant sa restauration, puis les redémarrer |
| `-n`              | Ne pas vérifier les sommes de contrôle                           |
| `-l`              | Lister le contenu de la sauvegarde sans rien restaurer           |
| `-h`              | Afficher l'aide                                                  |

### Exemples

```bash
./docker-restore.sh -l backups/20261111-144307                         # voir le contenu
./docker-restore.sh backups/20261111-144307                            # tout restaurer
./docker-restore.sh backups/20261111-144307 php_mariadb_data           # un seul volume
./docker-restore.sh -i backups/20261111-144307 bateau/openttd:15.3     # une seule image
./docker-restore.sh -v -f -s backups/20261111-144307 php_mariadb_data  # écraser un volume utilisé
```

### Fonctionnement

1. **Vérification** : les archives sont contrôlées avec `SHA256SUMS`. Le
   script s'arrête si l'une d'elles est corrompue (`-n` pour passer outre).
2. **Images** : elles sont rechargées avec `docker load`, tags compris.
3. **Volumes** :
   - un volume absent est recréé avec ses labels, son pilote et ses options.
     Les labels permettent à Docker Compose de reconnaître ses volumes (sinon
     il signale qu'ils n'ont « pas été créés par Compose ») ;
   - le contenu du volume est vidé puis remplacé par celui de l'archive ;
   - les propriétaires et les droits des fichiers sont conservés.

### Protections

- Un volume qui existe déjà **et contient des données** est ignoré. Pour
  l'écraser, ajoutez `-f` : son contenu sera **entièrement remplacé**.
- Si un conteneur en cours d'exécution utilise ce volume, `-f` ne suffit pas :
  ajoutez `-s` pour que le conteneur soit arrêté pendant la restauration puis
  redémarré. Sinon, le volume est compté en échec.
- Un volume existant mais vide est restauré sans option particulière.

### Restauration manuelle

Sans le script, une sauvegarde se restaure aussi à la main :

```bash
# Image
gunzip -c images/<fichier>.tar.gz | docker load

# Volume
docker volume create <nom>
docker run --rm -v <nom>:/data -v "$PWD/volumes":/backup alpine:3.20 \
  tar xzf /backup/<nom>.tar.gz -C /data
```

## Sauvegarde automatique (cron)

Le fichier `docker-backup.cron` lance une sauvegarde complète **chaque
dimanche à 3 h 00** :

- toutes les images et tous les volumes ;
- arrêt des conteneurs pendant la sauvegarde de leurs volumes (`-s`) ;
- suppression des sauvegardes de plus de 28 jours (`-k 28`), soit environ
  4 sauvegardes conservées ;
- journal dans `/var/log/docker-backup.log` ;
- `flock` empêche deux sauvegardes de tourner en même temps.

> Avec `-s`, les services concernés sont **indisponibles** pendant la
> sauvegarde de leurs volumes (quelques secondes à quelques minutes selon la
> taille des données).

### Installation sur le VPS

Chemins utilisés par défaut :

| Élément     | Chemin                           |
|-------------|----------------------------------|
| Scripts     | `/opt/scripts/docker/`           |
| Sauvegardes | `/var/backups/docker/`           |
| Journal     | `/var/log/docker-backup.log`     |

Si vous en choisissez d'autres, modifiez la dernière ligne de
`docker-backup.cron`.

```bash
# 1. Copier les scripts depuis votre machine
scp docker-backup.sh docker-restore.sh docker-backup.cron utilisateur@vps:/tmp/

# 2. Sur le VPS : installer les scripts
sudo mkdir -p /opt/scripts/docker /var/backups/docker
sudo install -m 755 /tmp/docker-backup.sh /tmp/docker-restore.sh /opt/scripts/docker/
sudo chmod 700 /var/backups/docker

# 3. Installer la tâche cron (le nom ne doit PAS contenir de point,
#    sinon cron ignore le fichier)
sudo install -m 644 -o root -g root /tmp/docker-backup.cron /etc/cron.d/docker-backup

# 4. Installer jq, utile pour la restauration
sudo apt install jq

# 5. Faire un premier essai manuel
sudo /opt/scripts/docker/docker-backup.sh -o /var/backups/docker -s
```

Le fichier de `/etc/cron.d` est pris en compte automatiquement, sans
redémarrer cron. La tâche tourne en `root`, ce qui lui donne accès à Docker.

### Vérifier que la tâche fonctionne

```bash
sudo tail -n 30 /var/log/docker-backup.log   # journal des sauvegardes
ls -l /var/backups/docker/                   # sauvegardes présentes
grep CRON /var/log/syslog | tail             # exécutions de cron (ou : journalctl -u cron)
```

### Changer la fréquence

Les cinq premiers champs de la ligne sont `minute heure jour mois
jour-de-la-semaine` (0 = dimanche). Exemples :

| Planification         | Champs        |
|-----------------------|---------------|
| Dimanche à 3 h 00     | `0 3 * * 0`   |
| Lundi à 2 h 30        | `30 2 * * 1`  |
| Tous les jours à 4 h  | `0 4 * * *`   |

> **Conseil** : des sauvegardes stockées sur le VPS lui-même ne protègent pas
> contre la perte du VPS. Copiez régulièrement `/var/backups/docker` vers une
> autre machine (`rsync`, stockage objet…).

## Codes de sortie

| Code | Signification                                                     |
|------|-------------------------------------------------------------------|
| `0`  | Tout s'est bien passé (des volumes ont pu être ignorés)           |
| `1`  | Au moins un élément en échec, sauvegarde corrompue ou erreur d'usage |
