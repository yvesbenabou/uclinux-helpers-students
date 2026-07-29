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
Préparation et validation complète de l’environnement uClinux/Buildroot.

Ce script exécute successivement :
  ./1_setup_validation.sh
  ./2_buildroot_download_and_configure.sh
  ./3_uclinux_qemu_dl_and_build.sh
  ./4_uclinux_stm32_dl_and_build.sh

Utilisation :
  ./setup_validate_uclinux_buildroot.sh [options]

Options :
  --root CHEMIN              Racine de travail, défaut : $UCLINUX_ROOT ou $HOME/uclinux
  --jobs N                   Nombre de compilations parallèles
  --skip-apt                 Ne pas installer les paquets Ubuntu
  --quick                    S'arrêter après les configurations Buildroot
  --allow-other-release      Accepter une version Ubuntu autre que 24.04
  --quiet                    Masquer la sortie verbeuse des commandes longues
  --debug                    Tracer l'entrée et la sortie des fonctions
  --no-resume                Ignorer les builds déjà marqués comme réussis
  --force-step NOM           Réexécuter un build réussi (build-qemu, build-stm32)
  -h, --help                 Afficher cette aide

Le script est réexécutable. Il ne supprime ni les sources, ni les sorties.
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
        --jobs)
            [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || {
                echo "ERREUR : --jobs attend un entier strictement positif." >&2
                exit 2
            }
            JOBS=$2
            shift 2
            ;;
        --skip-apt) SKIP_APT=1; shift ;;
        --quick) QUICK=1; shift ;;
        --allow-other-release) ALLOW_OTHER_RELEASE=1; shift ;;
        --quiet) QUIET=1; shift ;;
        --debug) DEBUG_TRACE=1; shift ;;
        --no-resume) RESUME=0; shift ;;
        --force-step)
            [[ $# -ge 2 ]] || { echo "ERREUR : --force-step attend un nom d'étape." >&2; exit 2; }
            case "$2" in
                build-qemu|build-stm32) ;;
                *) echo "ERREUR : étape inconnue pour --force-step : $2" >&2; exit 2 ;;
            esac
            FORCE_STEPS+=("$2")
            shift 2
            ;;
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

BUILD_ARGS=("${COMMON_ARGS[@]}" --jobs "$JOBS")
((RESUME)) || BUILD_ARGS+=(--no-resume)

section "Exécution de l'étape 1/4"
"$SCRIPT_DIR/1_setup_validation.sh" "${SETUP_ARGS[@]}"

section "Exécution de l'étape 2/4"
"$SCRIPT_DIR/2_buildroot_download_and_configure.sh" "${COMMON_ARGS[@]}"

if ((QUICK)); then
    section "Validation rapide terminée"
    ok "configurations Buildroot générées ; builds non exécutés (--quick)"
    exit 0
fi

QEMU_ARGS=("${BUILD_ARGS[@]}")
STM32_ARGS=("${BUILD_ARGS[@]}")
force_step_requested build-qemu && QEMU_ARGS+=(--force)
force_step_requested build-stm32 && STM32_ARGS+=(--force)

section "Exécution de l'étape 3/4"
"$SCRIPT_DIR/3_uclinux_qemu_dl_and_build.sh" "${QEMU_ARGS[@]}"

section "Exécution de l'étape 4/4"
"$SCRIPT_DIR/4_uclinux_stm32_dl_and_build.sh" "${STM32_ARGS[@]}"

REPORT="$LOG_DIR/report-$TIMESTAMP.txt"
cat >"$REPORT" <<EOFREPORT
VALIDATION COMPLÈTE RÉUSSIE
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
printf '\n%sVALIDATION TERMINÉE AVEC SUCCÈS%s\n' "$C_GREEN" "$C_RESET"
