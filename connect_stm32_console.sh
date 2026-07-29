#!/usr/bin/env bash
#
# Open the STM32 serial console with the Minicom profile prepared by step 1.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=uclinux_common.sh
source "$SCRIPT_DIR/uclinux_common.sh"

DEVICE="/dev/ttyACM0"
BAUD_RATE=115200
PROFILE_NAME="acm0"

usage() {
    cat <<'USAGE'
Ouvre la console série de la carte STM32 avec Minicom.

Utilisation :
  ./connect_stm32_console.sh [options]

Options :
  --device CHEMIN   Port série, défaut : /dev/ttyACM0
  -h, --help        Afficher cette aide

Configuration : 115200 bauds, 8 bits, sans parité, 1 bit d'arrêt.
Quitter Minicom avec Ctrl-A puis X.
USAGE
}

while (($#)); do
    case "$1" in
        --device)
            [[ $# -ge 2 ]] || die "--device attend un chemin"
            DEVICE=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "option inconnue : $1"
            ;;
    esac
done

command -v minicom >/dev/null 2>&1 \
    || die "Minicom est absent : exécutez d'abord $SCRIPT_DIR/1_setup_validation.sh"

PROFILE_FILE="$HOME/.minirc.$PROFILE_NAME"
check_file_nonempty "$PROFILE_FILE"

[[ -t 0 && -t 1 ]] || die "un terminal interactif est requis pour lancer Minicom."
[[ -c "$DEVICE" ]] \
    || die "port série absent : $DEVICE. Branchez la carte puis vérifiez les périphériques /dev/ttyACM*."

if [[ ! -r "$DEVICE" || ! -w "$DEVICE" ]]; then
    DEVICE_GROUP="$(stat -c '%G' "$DEVICE" 2>/dev/null || printf 'inconnu')"
    warn "accès refusé au port $DEVICE (groupe : $DEVICE_GROUP)."
    warn "Vérifiez votre appartenance à dialout avec : groups"
    die "fermez puis rouvrez la session après l'ajout au groupe dialout."
fi

info "Connexion à $DEVICE : $BAUD_RATE bauds, 8N1, sans contrôle de flux."
info "Quitter Minicom avec Ctrl-A puis X."

exec minicom -b "$BAUD_RATE" -D "$DEVICE" "$PROFILE_NAME"
