#!/usr/bin/env bash
#
# docker-backup.sh — Sauvegarde des images Docker et des données des volumes.
#
# Usage : docker-backup.sh [-o DOSSIER] [-i] [-v] [-s] [-k JOURS] [-h]
#
#   -o DOSSIER  Dossier racine des sauvegardes (défaut : ./backups)
#   -i          Sauvegarder uniquement les images
#   -v          Sauvegarder uniquement les volumes
#   -s          Arrêter les conteneurs utilisant un volume pendant sa sauvegarde
#               (recommandé pour les bases de données), puis les redémarrer
#   -k JOURS    Supprimer les sauvegardes plus anciennes que JOURS jours
#   -h          Afficher cette aide
#
# Variables d'environnement :
#   HELPER_IMAGE  Image utilisée pour archiver les volumes (défaut : alpine:3.20)
#
# Restauration :
#   Image  : gunzip -c images/<fichier>.tar.gz | docker load
#   Volume : docker volume create <nom>
#            docker run --rm -v <nom>:/data -v "$PWD/volumes":/backup alpine:3.20 \
#              tar xzf /backup/<nom>.tar.gz -C /data

set -Eeuo pipefail

BACKUP_ROOT="./backups"
DO_IMAGES=1
DO_VOLUMES=1
STOP_CONTAINERS=0
KEEP_DAYS=""
HELPER_IMAGE="${HELPER_IMAGE:-alpine:3.20}"

# Conteneurs arrêtés par le script, à redémarrer en cas d'interruption
STOPPED=()

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] ATTENTION : %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf 'ERREUR : %s\n' "$*" >&2; exit 1; }

usage() { sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

restart_stopped() {
    if ((${#STOPPED[@]})); then
        log "Redémarrage des conteneurs : ${STOPPED[*]}"
        docker start "${STOPPED[@]}" >/dev/null || warn "Impossible de redémarrer certains conteneurs"
        STOPPED=()
    fi
}
trap restart_stopped EXIT

# Transforme "repo/nom:tag" en un nom de fichier sûr
safe_name() { printf '%s' "$1" | tr '/:@' '___'; }

while getopts ":o:ivsk:h" opt; do
    case "$opt" in
        o) BACKUP_ROOT="$OPTARG" ;;
        i) DO_VOLUMES=0 ;;
        v) DO_IMAGES=0 ;;
        s) STOP_CONTAINERS=1 ;;
        k) [[ "$OPTARG" =~ ^[0-9]+$ ]] || die "-k attend un nombre de jours"; KEEP_DAYS="$OPTARG" ;;
        h) usage 0 ;;
        :) die "L'option -$OPTARG attend un argument" ;;
        *) usage 1 ;;
    esac
done
((DO_IMAGES || DO_VOLUMES)) || die "-i et -v sont incompatibles"

command -v docker >/dev/null || die "docker introuvable"
docker info >/dev/null 2>&1 || die "Impossible de contacter le démon Docker (droits ? service démarré ?)"

DEST="$BACKUP_ROOT/$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"
log "Destination : $DEST"

ERRORS=0

# --- Images -----------------------------------------------------------------
backup_images() {
    mkdir -p "$DEST/images"
    log "Sauvegarde des images..."

    # Regroupe les tags par ID d'image pour ne sauvegarder chaque image qu'une fois
    declare -A tags_by_id=()
    local id ref
    while read -r id ref; do
        [[ "$ref" == *"<none>"* ]] && continue
        tags_by_id["$id"]+="$ref "
    done < <(docker image ls --format '{{.ID}} {{.Repository}}:{{.Tag}}')

    if ((${#tags_by_id[@]} == 0)); then
        log "Aucune image taguée à sauvegarder"
        return
    fi

    local refs file
    for id in "${!tags_by_id[@]}"; do
        read -ra refs <<<"${tags_by_id[$id]}"
        file="$DEST/images/$(safe_name "${refs[0]}").tar.gz"
        log "  ${refs[*]}"
        if docker save "${refs[@]}" | gzip -c >"$file"; then
            printf '%s\t%s\t%s\n' "$id" "$(basename "$file")" "${refs[*]}" >>"$DEST/images/manifest.tsv"
        else
            warn "Échec de la sauvegarde de ${refs[*]}"
            rm -f "$file"
            ERRORS=$((ERRORS + 1))
        fi
    done
}

# --- Volumes ----------------------------------------------------------------
backup_volumes() {
    mkdir -p "$DEST/volumes"
    log "Sauvegarde des volumes..."

    local volumes
    mapfile -t volumes < <(docker volume ls -q)
    if ((${#volumes[@]} == 0)); then
        log "Aucun volume à sauvegarder"
        return
    fi

    if ! docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1; then
        log "Téléchargement de l'image utilitaire $HELPER_IMAGE"
        docker pull -q "$HELPER_IMAGE" >/dev/null || die "Impossible de récupérer $HELPER_IMAGE"
    fi

    local vol users
    for vol in "${volumes[@]}"; do
        log "  $vol"

        if ((STOP_CONTAINERS)); then
            mapfile -t users < <(docker ps -q --filter "volume=$vol")
            if ((${#users[@]})); then
                log "    arrêt de ${#users[@]} conteneur(s)"
                docker stop "${users[@]}" >/dev/null
                STOPPED=("${users[@]}")
            fi
        fi

        if docker run --rm \
                -v "$vol":/data:ro \
                -v "$DEST/volumes":/backup \
                "$HELPER_IMAGE" \
                tar czf "/backup/$vol.tar.gz" -C /data . ; then
            docker volume inspect "$vol" >"$DEST/volumes/$vol.json"
        else
            warn "Échec de la sauvegarde du volume $vol"
            rm -f "$DEST/volumes/$vol.tar.gz"
            ERRORS=$((ERRORS + 1))
        fi

        restart_stopped
    done

    # Les fichiers créés par le conteneur appartiennent à root : on les rend à l'utilisateur
    docker run --rm -v "$DEST/volumes":/backup "$HELPER_IMAGE" \
        chown -R "$(id -u):$(id -g)" /backup
}

((DO_IMAGES))  && backup_images
((DO_VOLUMES)) && backup_volumes

# --- Sommes de contrôle -----------------------------------------------------
log "Calcul des sommes de contrôle..."
(cd "$DEST" && find . -name '*.tar.gz' -type f -print0 | sort -z | xargs -0r sha256sum >SHA256SUMS)

# --- Rotation ---------------------------------------------------------------
if [[ -n "$KEEP_DAYS" ]]; then
    log "Suppression des sauvegardes de plus de $KEEP_DAYS jours"
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*-[0-9]*' \
        -mtime +"$KEEP_DAYS" -exec rm -rf {} +
fi

log "Terminé : $(du -sh "$DEST" | cut -f1) dans $DEST"
if ((ERRORS)); then
    warn "$ERRORS élément(s) en échec"
    exit 1
fi
