#!/usr/bin/env bash
#
# Run the Buildroot QEMU ARM VExpress image produced by the course setup.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=uclinux_common.sh
source "$SCRIPT_DIR/uclinux_common.sh"

WORK_ROOT="$(uclinux_default_root)"
QEMU_OUT=""
LOG_FILE=""
NO_LOG=0
TIMEOUT_SECONDS=0

usage() {
    cat <<'USAGE'
Lance l'image Buildroot QEMU ARM VExpress.

Utilisation :
  ./run_qemu_image.sh [options]

Options :
  --root CHEMIN      Racine de travail, défaut : $UCLINUX_ROOT ou $HOME/uclinux
  --output CHEMIN    Répertoire de sortie Buildroot QEMU
  --log CHEMIN       Journal de la console série
  --no-log           Ne pas enregistrer de journal
  --timeout SECONDES Arrêter QEMU après ce délai, défaut : aucun timeout
  -h, --help         Afficher cette aide

Quitter QEMU avec Ctrl-a puis x.
USAGE
}

while (($#)); do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || uclinux_die "--root attend un chemin"
            WORK_ROOT=$2
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || uclinux_die "--output attend un chemin"
            QEMU_OUT=$2
            shift 2
            ;;
        --log)
            [[ $# -ge 2 ]] || uclinux_die "--log attend un chemin"
            LOG_FILE=$2
            shift 2
            ;;
        --no-log)
            NO_LOG=1
            shift
            ;;
        --timeout)
            [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || uclinux_die "--timeout attend un entier strictement positif"
            TIMEOUT_SECONDS=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            uclinux_die "option inconnue : $1"
            ;;
    esac
done

WORK_ROOT="$(uclinux_realpath "$WORK_ROOT")"
QEMU_OUT="${QEMU_OUT:-$(uclinux_qemu_output_dir "$WORK_ROOT")}"
QEMU_OUT="$(uclinux_realpath "$QEMU_OUT")"
IMAGES_DIR="$QEMU_OUT/images"

KERNEL="$IMAGES_DIR/zImage"
DTB="$IMAGES_DIR/vexpress-v2p-ca9.dtb"
ROOTFS="$IMAGES_DIR/rootfs.ext2"
START_QEMU="$IMAGES_DIR/start-qemu.sh"

uclinux_check_file_nonempty "$KERNEL"
uclinux_check_file_nonempty "$DTB"
uclinux_check_file_nonempty "$ROOTFS"
uclinux_check_file_nonempty "$START_QEMU"

QEMU_BIN="$QEMU_OUT/host/bin/qemu-system-arm"
uclinux_check_file_nonempty "$QEMU_BIN"

QEMU_CMD=("$START_QEMU" --serial-only)

if ((TIMEOUT_SECONDS > 0)); then
    QEMU_CMD=(timeout --signal=TERM --kill-after=5s "$TIMEOUT_SECONDS" "${QEMU_CMD[@]}")
fi

uclinux_info "Démarrage de QEMU depuis $START_QEMU"
uclinux_info "Quitter QEMU avec Ctrl-a puis x."

if ((NO_LOG)); then
    exec "${QEMU_CMD[@]}"
fi

LOG_FILE="${LOG_FILE:-$(uclinux_default_log_file "$WORK_ROOT" qemu-run)}"
uclinux_info "Journal de la console série : $LOG_FILE"

if uclinux_run_logged_pty_if_available "$LOG_FILE" "${QEMU_CMD[@]}"; then
    rc=0
else
    rc=$?
fi

exit "$rc"
