#!/usr/bin/env bash
#
# Étape 4 : téléchargement des sources Linux et build STM32F429I-DISC1.

set -Eeuo pipefail
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=uclinux_common.sh
source "$SCRIPT_DIR/uclinux_common.sh"

linux_build_dir() {
    local __fn="${FUNCNAME[0]}"
    local out=$1
    local version=$2
    local dir="$out/build/linux-$version"

    debug_enter "$__fn"
    [[ -d "$dir" ]] || die "répertoire de build Linux introuvable : $dir"
    printf '%s\n' "$dir"
    debug_exit "$__fn" 0
}

uclinux_reconcile_stm32_images() {
    local stale_image

    # Ces fichiers sont produits par les variantes STM32 U-Boot ou ROMFS,
    # jamais par cette variante AFBOOT avec initramfs.
    for stale_image in u-boot.bin uImage rootfs.romfs rootfs.tar stm32f429-disco-romfs.dtb; do
        if [[ -e "$STM32_OUT/images/$stale_image" ]]; then
            rm -f -- "$STM32_OUT/images/$stale_image"
            warn "image d'une autre variante supprimée : $stale_image"
        fi
    done
}

uclinux_step_build_stm32() {
    section "Préparation des sources Linux STM32"
    uclinux_prepare_buildroot stm32

    section "Construction incrémentale STM32F429I-DISC1"
    run_with_log "$LOG_DIR/build-stm32-$TIMESTAMP.log" make_br "$STM32_OUT"

    # U-Boot variants remove AFBOOT's binary.  Restore the package output
    # when returning to this layout without rebuilding the whole tree.
    if [[ ! -s "$STM32_OUT/images/stm32f429i-disco.bin" ]]; then
        run_with_log "$LOG_DIR/reinstall-afboot-stm32-$TIMESTAMP.log" \
            make_br "$STM32_OUT" afboot-stm32-reinstall
    fi
    uclinux_reconcile_stm32_images

    STM32_IMAGES=(
        "$STM32_OUT/images/stm32f429i-disco.bin"
        "$STM32_OUT/images/stm32f429-disco.dtb"
        "$STM32_OUT/images/xipImage"
    )
    for image in "${STM32_IMAGES[@]}"; do check_file_nonempty "$image"; done

    LINUX_BUILD_DIR="$(linux_build_dir "$STM32_OUT" "$EXPECTED_LINUX_VERSION")"
    VMLINUX="$LINUX_BUILD_DIR/vmlinux"
    KERNEL_CONFIG="$LINUX_BUILD_DIR/.config"
    check_file_nonempty "$VMLINUX"
    check_file_nonempty "$KERNEL_CONFIG"

    file "$VMLINUX"
    readelf -h "$VMLINUX" | grep -E 'Class:|Data:|Machine:|Entry point address:'
    grep -qx '# CONFIG_MMU is not set' "$KERNEL_CONFIG" || die "le noyau STM32 semble avoir CONFIG_MMU actif."
    grep -qx 'CONFIG_XIP_KERNEL=y' "$KERNEL_CONFIG" || die "CONFIG_XIP_KERNEL n'est pas actif."
    grep -q '^CONFIG_INITRAMFS_SOURCE=' "$KERNEL_CONFIG" || die "aucune source initramfs dans la configuration noyau."
    ok "noyau Linux $EXPECTED_LINUX_VERSION : ARM, no-MMU, XIP, initramfs"

    check_file_nonempty "$STM32_OUT/target/bin/busybox"
    ok "BusyBox installé dans le rootfs préparé"

    TARGET_GCC="$(find "$STM32_OUT/host/bin" -maxdepth 1 \( -type f -o -type l \) -name '*-gcc' | sort | head -n1)"
    [[ -n "$TARGET_GCC" ]] || die "compilateur croisé introuvable dans $STM32_OUT/host/bin."
    file "$TARGET_GCC"
    printf 'Triplet cible : %s\n' "$("$TARGET_GCC" -dumpmachine)"
    ok "chaîne de compilation croisée opérationnelle"

    check_file_nonempty "$STM32_OUT/host/bin/openocd"
    file "$STM32_OUT/host/bin/openocd"
    "$STM32_OUT/host/bin/openocd" --version 2>&1 | sed -n '1p'
    ok "OpenOCD hôte construit par Buildroot"

    DT_DUMP="$LOG_DIR/stm32f429-disco-$TIMESTAMP.dts"
    dtc -I dtb -O dts "$STM32_OUT/images/stm32f429-disco.dtb" > "$DT_DUMP"
    grep -q '/dts-v1/' "$DT_DUMP" || die "le DTB n'a pas pu être décompilé correctement."
    ok "DTB valide ; décompilation enregistrée dans $DT_DUMP"

    printf '\nImages utiles pour la STM32F429I-DISC1 :\n'
    for image in "${STM32_IMAGES[@]}"; do
        printf '  %-38s %10s octets\n' "$(basename "$image")" "$(stat -c %s "$image")"
    done
    printf '\nInventaire complet Buildroot (diagnostic) :\n'
    find "$STM32_OUT/images" -maxdepth 1 -type f -printf '  %-38f %10s octets\n' | sort

    OPENOCD_STM32_RUNNER="$SCRIPT_DIR/run_openocd_stm32.sh"
    check_file_nonempty "$OPENOCD_STM32_RUNNER"
    info "Pour tester OpenOCD sans flasher : $OPENOCD_STM32_RUNNER probe --root $WORK_ROOT"
    info "Pour flasher la carte : $OPENOCD_STM32_RUNNER flash --root $WORK_ROOT"
}

usage() {
    cat <<'USAGE'
Étape 4 : téléchargement des sources Linux et build STM32F429I-DISC1.

Utilisation :
  ./4_uclinux_stm32_dl_and_build.sh [options]

Options :
  --root CHEMIN   Racine de travail, défaut : $UCLINUX_ROOT ou $HOME/uclinux
  --quiet         Masquer la sortie verbeuse des commandes longues
  --debug         Tracer l'entrée et la sortie des fonctions
  -h, --help      Afficher cette aide
USAGE
}

while (($#)); do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || { echo "ERREUR : --root attend un chemin." >&2; exit 2; }
            WORK_ROOT=$2
            shift 2
            ;;
        --quiet) QUIET=1; shift ;;
        --debug) DEBUG_TRACE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERREUR : option inconnue : $1" >&2; usage; exit 2 ;;
    esac
done

uclinux_begin_logging uclinux-stm32-build
uclinux_step_build_stm32
section "Étape 4 terminée"
ok "build STM32 terminé"
