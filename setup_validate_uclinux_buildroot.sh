#!/usr/bin/env bash
#
# Orchestrateur du scénario uClinux/Buildroot complet.

set -Eeuo pipefail
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=uclinux_common.sh
source "$SCRIPT_DIR/uclinux_common.sh"

: "${SKIP_APT:=0}"
: "${QUICK:=0}"
: "${ALLOW_OTHER_RELEASE:=0}"

usage() {
    cat <<'USAGE'
Préparation et construction de l’environnement uClinux/Buildroot.

Ce script exécute successivement :
  ./1_setup_validation.sh
  ./2_buildroot_download_and_configure.sh
  ./3_uclinux_qemu_dl_and_build.sh
  ./4_uclinux_stm32_dl_and_build.sh

Utilisation :
  ./setup_validate_uclinux_buildroot.sh [options]

Options :
  --root CHEMIN              Racine de travail, défaut : $UCLINUX_ROOT ou $HOME/uclinux
  --skip-apt                 Ne pas installer les paquets Ubuntu
  --quick                    S'arrêter après les configurations Buildroot
  --allow-other-release      Accepter une version Ubuntu autre que 24.04
  --quiet                    Masquer la sortie verbeuse des commandes longues
  --debug                    Tracer l'entrée et la sortie des fonctions
  -h, --help                 Afficher cette aide

Le script est réexécutable ; Buildroot réutilise ses sorties incrémentales.
Chaque étape peut aussi être lancée directement.
USAGE
}

while (($#)); do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || { echo "ERREUR : --root attend un chemin." >&2; exit 2; }
            WORK_ROOT=$2
            shift 2
            ;;
        --skip-apt) SKIP_APT=1; shift ;;
        --quick) QUICK=1; shift ;;
        --allow-other-release) ALLOW_OTHER_RELEASE=1; shift ;;
        --quiet) QUIET=1; shift ;;
        --debug) DEBUG_TRACE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERREUR : option inconnue : $1" >&2; usage; exit 2 ;;
    esac
done

uclinux_begin_logging validation

COMMON_ARGS=(--root "$WORK_ROOT")
((QUIET)) && COMMON_ARGS+=(--quiet)
((DEBUG_TRACE)) && COMMON_ARGS+=(--debug)

SETUP_ARGS=("${COMMON_ARGS[@]}")
((SKIP_APT)) && SETUP_ARGS+=(--skip-apt)
((ALLOW_OTHER_RELEASE)) && SETUP_ARGS+=(--allow-other-release)

BUILD_ARGS=("${COMMON_ARGS[@]}")

section "Exécution de l'étape 1/4"
"$SCRIPT_DIR/1_setup_validation.sh" "${SETUP_ARGS[@]}"

section "Exécution de l'étape 2/4"
"$SCRIPT_DIR/2_buildroot_download_and_configure.sh" "${COMMON_ARGS[@]}"

if ((QUICK)); then
    section "Préparation rapide terminée"
    ok "configurations Buildroot générées ; builds non exécutés (--quick)"
    exit 0
fi

section "Exécution de l'étape 3/4"
"$SCRIPT_DIR/3_uclinux_qemu_dl_and_build.sh" "${BUILD_ARGS[@]}"

section "Exécution de l'étape 4/4"
"$SCRIPT_DIR/4_uclinux_stm32_dl_and_build.sh" "${BUILD_ARGS[@]}"

REPORT="$LOG_DIR/report-$TIMESTAMP.txt"
cat >"$REPORT" <<EOFREPORT
PRÉPARATION ET CONSTRUCTION RÉUSSIES
Date                  : $(date --iso-8601=seconds)
Buildroot             : $BUILDROOT_REF
Linux STM32           : $EXPECTED_LINUX_VERSION
Racine de travail     : $WORK_ROOT
Cache téléchargements : $DOWNLOAD_DIR
Sortie STM32          : $STM32_OUT
Sortie QEMU           : $QEMU_OUT
Commande QEMU         : $SCRIPT_DIR/run_qemu_image.sh --root $WORK_ROOT
Commande test OpenOCD : $SCRIPT_DIR/run_openocd_stm32.sh probe --root $WORK_ROOT
Commande flash STM32  : $SCRIPT_DIR/run_openocd_stm32.sh flash --root $WORK_ROOT
Profil minicom        : $HOME/.minirc.acm0 (minicom acm0, /dev/ttyACM0 115200 8N1)
Journal principal     : $MAIN_LOG
Rapport               : $REPORT
EOFREPORT

section "Rapport final"
cat "$REPORT"
printf '\n%sPRÉPARATION ET CONSTRUCTION TERMINÉES AVEC SUCCÈS%s\n' "$C_GREEN" "$C_RESET"
