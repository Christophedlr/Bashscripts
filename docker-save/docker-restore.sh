#!/usr/bin/env bash
#
# docker-restore.sh — Restauration d'une sauvegarde créée par docker-backup.sh.
#
# Usage : docker-restore.sh [-i] [-v] [-f] [-s] [-n] [-l] [-h] DOSSIER [NOM...]
#
#   DOSSIER     Dossier d'une sauvegarde (ex. ./backups/20261111-144307)
#   NOM...      Ne restaurer que ces volumes / images (nom de volume, référence
#               d'image comme "nginx:latest", ou nom de fichier sans .tar.gz)
#
#   -i          Restaurer uniquement les images
#   -v          Restaurer uniquement les volumes
#   -f          Écraser le contenu des volumes existants non vides
#               (par défaut, ils sont ignorés)
#   -s          Arrêter les conteneurs utilisant un volume pendant sa
#               restauration, puis les redémarrer (obligatoire avec -f si le
#               volume est utilisé par un conteneur en cours d'exécution)
#   -n          Ne pas vérifier les sommes de contrôle
#   -l          Lister le contenu de la sauvegarde sans rien restaurer
#   -h          Afficher cette aide
#
# Variables d'environnement :
#   HELPER_IMAGE  Image utilisée pour extraire les volumes (défaut : alpine:3.20)

set -Eeuo pipefail

DO_IMAGES=1
DO_VOLUMES=1
FORCE=0
STOP_CONTAINERS=0
CHECK_SUMS=1
LIST_ONLY=0
HELPER_IMAGE="${HELPER_IMAGE:-alpine:3.20}"

# Conteneurs arrêtés par le script, à redémarrer en cas d'interruption
STOPPED=()

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] ATTENTION : %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf 'ERREUR : %s\n' "$*" >&2; exit 1; }

usage() { sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

restart_stopped() {
    if ((${#STOPPED[@]})); then
        log "Redémarrage des conteneurs : ${STOPPED[*]}"
        docker start "${STOPPED[@]}" >/dev/null || warn "Impossible de redémarrer certains conteneurs"
        STOPPED=()
    fi
}
trap restart_stopped EXIT

while getopts ":ivfsnlh" opt; do
    case "$opt" in
        i) DO_VOLUMES=0 ;;
        v) DO_IMAGES=0 ;;
        f) FORCE=1 ;;
        s) STOP_CONTAINERS=1 ;;
        n) CHECK_SUMS=0 ;;
        l) LIST_ONLY=1 ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done
shift $((OPTIND - 1))
(($# >= 1)) || usage 1
((DO_IMAGES || DO_VOLUMES)) || die "-i et -v sont incompatibles"

SRC="$1"; shift
FILTER=("$@")
[[ -d "$SRC" ]] || die "Dossier introuvable : $SRC"
SRC="$(cd "$SRC" && pwd)"

# Vrai si aucun filtre n'est donné ou si l'un des noms passés en argument correspond
wanted() {
    ((${#FILTER[@]} == 0)) && return 0
    local candidate name
    for candidate in "$@"; do
        for name in "${FILTER[@]}"; do
            [[ "$candidate" == "$name" ]] && return 0
        done
    done
    return 1
}

# Références d'image associées à un fichier, d'après le manifeste
image_refs() {
    local manifest="$SRC/images/manifest.tsv"
    [[ -f "$manifest" ]] || return 0
    awk -F'\t' -v f="$1" '$2 == f { print $3 }' "$manifest"
}

# --- Liste ------------------------------------------------------------------
if ((LIST_ONLY)); then
    if [[ -d "$SRC/images" ]]; then
        echo "Images :"
        for file in "$SRC"/images/*.tar.gz; do
            [[ -e "$file" ]] || continue
            refs="$(image_refs "$(basename "$file")")"
            printf '  %-50s %8s  %s\n' "$(basename "$file" .tar.gz)" \
                "$(du -h "$file" | cut -f1)" "$refs"
        done
    fi
    if [[ -d "$SRC/volumes" ]]; then
        echo "Volumes :"
        for file in "$SRC"/volumes/*.tar.gz; do
            [[ -e "$file" ]] || continue
            printf '  %-66s %8s\n' "$(basename "$file" .tar.gz)" "$(du -h "$file" | cut -f1)"
        done
    fi
    exit 0
fi

command -v docker >/dev/null || die "docker introuvable"
docker info >/dev/null 2>&1 || die "Impossible de contacter le démon Docker (droits ? service démarré ?)"

# --- Sommes de contrôle -----------------------------------------------------
if ((CHECK_SUMS)); then
    if [[ -f "$SRC/SHA256SUMS" ]]; then
        log "Vérification des sommes de contrôle..."
        (cd "$SRC" && sha256sum --quiet -c SHA256SUMS) \
            || die "Sauvegarde corrompue (utilisez -n pour ignorer la vérification)"
    else
        warn "Pas de fichier SHA256SUMS : vérification impossible"
    fi
fi

ERRORS=0
RESTORED=0
SKIPPED=0

# --- Images -----------------------------------------------------------------
restore_images() {
    [[ -d "$SRC/images" ]] || { log "Aucune image dans la sauvegarde"; return; }
    log "Restauration des images..."

    local file name refs
    for file in "$SRC"/images/*.tar.gz; do
        [[ -e "$file" ]] || continue
        name="$(basename "$file" .tar.gz)"
        refs="$(image_refs "$(basename "$file")")"
        # shellcheck disable=SC2086  # découpage voulu de la liste des références
        wanted "$name" $refs || continue

        log "  ${refs:-$name}"
        if gunzip -c "$file" | docker load -q >/dev/null; then
            RESTORED=$((RESTORED + 1))
        else
            warn "Échec du chargement de $name"
            ERRORS=$((ERRORS + 1))
        fi
    done
}

# --- Volumes ----------------------------------------------------------------

# Crée le volume en reprenant pilote, options et labels enregistrés (labels
# utiles à Docker Compose pour reconnaître ses volumes)
create_volume() {
    local vol="$1" json="$SRC/volumes/$1.json"
    local args=()

    if [[ -f "$json" ]] && command -v jq >/dev/null; then
        local driver line
        driver="$(jq -r '.[0].Driver // "local"' "$json")"
        args+=(--driver "$driver")
        while IFS= read -r line; do
            [[ -n "$line" ]] && args+=(--label "$line")
        done < <(jq -r '.[0].Labels // {} | to_entries[] | "\(.key)=\(.value)"' "$json")
        while IFS= read -r line; do
            [[ -n "$line" ]] && args+=(--opt "$line")
        done < <(jq -r '.[0].Options // {} | to_entries[] | "\(.key)=\(.value)"' "$json")
    elif [[ -f "$json" ]]; then
        warn "jq absent : le volume $vol est créé sans ses labels ni options"
    fi

    docker volume create "${args[@]}" "$vol" >/dev/null
}

volume_is_empty() {
    docker run --rm -v "$1":/data:ro "$HELPER_IMAGE" sh -c '[ -z "$(ls -A /data)" ]'
}

restore_volumes() {
    [[ -d "$SRC/volumes" ]] || { log "Aucun volume dans la sauvegarde"; return; }

    if ! docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1; then
        log "Téléchargement de l'image utilitaire $HELPER_IMAGE"
        docker pull -q "$HELPER_IMAGE" >/dev/null || die "Impossible de récupérer $HELPER_IMAGE"
    fi

    log "Restauration des volumes..."
    local file vol users
    for file in "$SRC"/volumes/*.tar.gz; do
        [[ -e "$file" ]] || continue
        vol="$(basename "$file" .tar.gz)"
        wanted "$vol" || continue
        log "  $vol"

        if docker volume inspect "$vol" >/dev/null 2>&1; then
            if ! volume_is_empty "$vol"; then
                if ! ((FORCE)); then
                    warn "Le volume $vol existe et n'est pas vide : ignoré (utilisez -f pour l'écraser)"
                    SKIPPED=$((SKIPPED + 1))
                    continue
                fi
                mapfile -t users < <(docker ps -q --filter "volume=$vol")
                if ((${#users[@]})); then
                    if ! ((STOP_CONTAINERS)); then
                        warn "Le volume $vol est utilisé par un conteneur en cours d'exécution : ignoré (utilisez -s)"
                        ERRORS=$((ERRORS + 1))
                        continue
                    fi
                    log "    arrêt de ${#users[@]} conteneur(s)"
                    docker stop "${users[@]}" >/dev/null
                    STOPPED=("${users[@]}")
                fi
            fi
        else
            create_volume "$vol"
        fi

        # Vide le volume puis extrait l'archive (les propriétaires sont conservés)
        if docker run --rm \
                -v "$vol":/data \
                -v "$SRC/volumes":/backup:ro \
                "$HELPER_IMAGE" \
                sh -c 'find /data -mindepth 1 -delete && tar xzf "/backup/$1.tar.gz" -C /data' sh "$vol"; then
            RESTORED=$((RESTORED + 1))
        else
            warn "Échec de la restauration du volume $vol"
            ERRORS=$((ERRORS + 1))
        fi

        restart_stopped
    done
}

((DO_IMAGES))  && restore_images
((DO_VOLUMES)) && restore_volumes

log "Terminé : $RESTORED élément(s) restauré(s), $SKIPPED ignoré(s)"
if ((${#FILTER[@]})) && ((RESTORED + SKIPPED + ERRORS == 0)); then
    warn "Aucun élément de la sauvegarde ne correspond à : ${FILTER[*]}"
fi
if ((ERRORS)); then
    warn "$ERRORS élément(s) en échec"
    exit 1
fi
