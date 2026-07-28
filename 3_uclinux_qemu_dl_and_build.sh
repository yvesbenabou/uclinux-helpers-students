#!/usr/bin/env bash
#
# Étape 3 : téléchargement des sources Linux et build QEMU.

set -Eeuo pipefail
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=uclinux_common.sh
source "$SCRIPT_DIR/uclinux_common.sh"

: "${QEMU_TEST:=0}"
: "${QEMU_TEST_TIMEOUT:=10}"

uclinux_ensure_qemu_config() {
    if [[ -s "$QEMU_OUT/.config" ]] && grep -q 'BR2_cortex_a9=y' "$QEMU_OUT/.config"; then
        ok "configuration active QEMU déjà présente : $QEMU_OUT/.config"
    else
        uclinux_generate_qemu_config
    fi
}


uclinux_step_build_qemu() {
    section "Préparation des sources Linux QEMU"
    uclinux_require_buildroot
    uclinux_ensure_qemu_config
    prepare_linux_override "$QEMU_OUT"

    section "Construction complète QEMU ARM VExpress"
    QEMU_BUILD_FINGERPRINT="$(step_fingerprint "$QEMU_OUT")"
    if step_completed "build-qemu" "$QEMU_BUILD_FINGERPRINT"; then
        ok "étape déjà validée, make QEMU ignoré (--force pour la relancer)"
    else
        run_with_log "$LOG_DIR/build-qemu-$TIMESTAMP.log" make_br "$QEMU_OUT" -j"$JOBS"
    fi

    QEMU_IMAGES=(
        "$QEMU_OUT/images/zImage"
        "$QEMU_OUT/images/vexpress-v2p-ca9.dtb"
        "$QEMU_OUT/images/rootfs.ext2"
    )
    for image in "${QEMU_IMAGES[@]}"; do check_file_nonempty "$image"; done
    check_file_nonempty "$QEMU_OUT/host/bin/qemu-system-arm"
    file "$QEMU_OUT/host/bin/qemu-system-arm"
    ok "cible QEMU et émulateur hôte construits"
    mark_step_completed "build-qemu" "$QEMU_BUILD_FINGERPRINT"

    printf '\nImages QEMU générées :\n'
    find "$QEMU_OUT/images" -maxdepth 1 -type f -printf '  %-38f %10s octets\n' | sort

    RUN_QEMU_IMAGE="$SCRIPT_DIR/run_qemu_image.sh"
    check_file_nonempty "$RUN_QEMU_IMAGE"
    info "Pour démarrer QEMU : $RUN_QEMU_IMAGE --root $WORK_ROOT"
    info "Pour tester QEMU pendant 10 secondes : $RUN_QEMU_IMAGE --root $WORK_ROOT --timeout 10"

    if ((QEMU_TEST)); then
        run_with_log "$LOG_DIR/qemu-test-$TIMESTAMP.log" "$RUN_QEMU_IMAGE" --root "$WORK_ROOT" --timeout "$QEMU_TEST_TIMEOUT"
    fi
}

usage() {
    cat <<'USAGE'
Étape 3 : téléchargement des sources Linux et build QEMU.

Utilisation :
  ./3_uclinux_qemu_dl_and_build.sh [options]

Options :
  --root CHEMIN       Racine de travail, défaut : $UCLINUX_ROOT ou $HOME/uclinux
  --jobs N            Nombre de compilations parallèles
  --force             Réexécuter le build QEMU même s'il est marqué réussi
  --no-resume         Ignorer les étapes déjà marquées comme réussies
  --test              Lancer un test QEMU court après le build
  --test-timeout N    Durée du test QEMU, défaut : 10 secondes
  --quiet             Masquer la sortie verbeuse des commandes longues
  --debug             Tracer l'entrée et la sortie des fonctions
  -h, --help          Afficher cette aide
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
        --force)
            FORCE_STEPS+=("build-qemu")
            shift
            ;;
        --force-step)
            [[ $# -ge 2 && "$2" == "build-qemu" ]] || { echo "ERREUR : --force-step attend build-qemu." >&2; exit 2; }
            FORCE_STEPS+=("build-qemu")
            shift 2
            ;;
        --no-resume) RESUME=0; shift ;;
        --test) QEMU_TEST=1; shift ;;
        --test-timeout)
            [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || {
                echo "ERREUR : --test-timeout attend un entier strictement positif." >&2
                exit 2
            }
            QEMU_TEST_TIMEOUT=$2
            shift 2
            ;;
        --quiet) QUIET=1; shift ;;
        --debug) DEBUG_TRACE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERREUR : option inconnue : $1" >&2; usage; exit 2 ;;
    esac
done

uclinux_begin_logging uclinux-qemu-build
uclinux_step_build_qemu
section "Étape 3 terminée"
ok "build QEMU terminé"
