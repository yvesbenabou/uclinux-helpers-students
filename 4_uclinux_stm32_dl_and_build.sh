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
    local dir

    debug_enter "$__fn"
    for dir in "$out/build/linux-custom" "$out/build/linux-$version"; do
        if [[ -d "$dir" ]]; then
            printf '%s\n' "$dir"
            debug_exit "$__fn" 0
            return 0
        fi
    done

    debug_exit "$__fn" 1
    die "répertoire de build Linux introuvable (cherché : $out/build/linux-custom, $out/build/linux-$version)"
}

uclinux_ensure_stm32_config() {
    if [[ -s "$STM32_OUT/.config" ]] \
        && grep -q 'BR2_cortex_m4=y' "$STM32_OUT/.config" \
        && grep -q "BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE=\"$EXPECTED_LINUX_VERSION\"" "$STM32_OUT/.config" \
        && uclinux_stm32_fb_configured "$STM32_OUT/.config"; then
        ok "configuration active STM32 déjà présente : $STM32_OUT/.config"
    else
        uclinux_generate_stm32_config
    fi
}


uclinux_step_build_stm32() {
    local asset_dir="$SCRIPT_DIR/stm32_initramfs_fb"
    section "Préparation des sources Linux STM32"
    uclinux_require_buildroot
    uclinux_ensure_stm32_config
    uclinux_enable_host_environment_setup "$STM32_OUT"
    prepare_linux_override "$STM32_OUT"

    section "Construction complète STM32F429I-DISC1"
    STM32_BUILD_FINGERPRINT="$(step_fingerprint "$STM32_OUT" "$SCRIPT_DIR/4_uclinux_stm32_dl_and_build.sh" "$SCRIPT_DIR/uclinux_common.sh" "$asset_dir/linux.fragment" "$asset_dir/busybox.fragment" "$asset_dir/post_build.sh")"
    if step_completed "build-stm32" "$STM32_BUILD_FINGERPRINT"; then
        ok "étape déjà validée, make STM32 ignoré (--force pour la relancer)"
    else
        run_with_log "$LOG_DIR/reconfigure-linux-stm32-$TIMESTAMP.log" make_br "$STM32_OUT" linux-reconfigure
        run_with_log "$LOG_DIR/build-stm32-$TIMESTAMP.log" make_br "$STM32_OUT" -j"$JOBS"
    fi

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

    grep -qx 'CONFIG_PM=y' "$KERNEL_CONFIG" || die "le runtime PM requis par LTDC n'est pas actif."
    grep -qx 'CONFIG_SPI_STM32=y' "$KERNEL_CONFIG" || die "le contrôleur SPI STM32 n'est pas actif."
    grep -qx 'CONFIG_DRM_STM=y' "$KERNEL_CONFIG" || die "le pilote DRM LTDC STM32 n'est pas actif."
    grep -qx 'CONFIG_DRM_PANEL_ILITEK_ILI9341=y' "$KERNEL_CONFIG" || die "le pilote ILI9341 n'est pas actif."
    grep -qx 'CONFIG_DRM_FBDEV_EMULATION=y' "$KERNEL_CONFIG" || die "l'émulation fbdev DRM n'est pas active."
    ok "LTDC, SPI5, ILI9341 et /dev/fb0 activés"

    XIP_IMAGE="$STM32_OUT/images/xipImage"
    XIP_SIZE="$(stat -c %s "$XIP_IMAGE")"
    XIP_LIMIT=$((0x08200000 - 0x0800C000))
    XIP_HEADROOM=$((XIP_LIMIT - XIP_SIZE))
    printf 'xipImage : %d octets ; capacité depuis 0x0800C000 : %d octets ; marge : %d octets\n' \
        "$XIP_SIZE" "$XIP_LIMIT" "$XIP_HEADROOM"
    ((XIP_HEADROOM >= 0)) \
        || die "xipImage dépasse la Flash STM32F429 de $((-XIP_HEADROOM)) octets."
    check_file_nonempty "$STM32_OUT/target/bin/busybox"
    ok "BusyBox installé dans le rootfs préparé"

    TARGET_GCC="$(find "$STM32_OUT/host/bin" -maxdepth 1 \( -type f -o -type l \) -name '*-gcc' | sort | head -n1)"
    [[ -n "$TARGET_GCC" ]] || die "compilateur croisé introuvable dans $STM32_OUT/host/bin."
    file "$TARGET_GCC"
    printf 'Triplet cible : %s\n' "$("$TARGET_GCC" -dumpmachine)"
    ok "chaîne de compilation croisée opérationnelle"

    check_file_nonempty "$STM32_OUT/host/bin/openocd"
    file "$STM32_OUT/host/bin/openocd"
    "$STM32_OUT/host/bin/openocd" --version 2>&1 | head -n1
    ok "OpenOCD hôte construit par Buildroot"

    DT_DUMP="$LOG_DIR/stm32f429-disco-$TIMESTAMP.dts"
    dtc -I dtb -O dts "$STM32_OUT/images/stm32f429-disco.dtb" > "$DT_DUMP"
    grep -q '/dts-v1/' "$DT_DUMP" || die "le DTB n'a pas pu être décompilé correctement."
    ok "DTB valide ; décompilation enregistrée dans $DT_DUMP"
    mark_step_completed "build-stm32" "$STM32_BUILD_FINGERPRINT"

    printf '\nImages STM32 générées :\n'
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
  --jobs N        Nombre de compilations parallèles
  --force         Réexécuter le build STM32 même s'il est marqué réussi
  --no-resume     Ignorer les étapes déjà marquées comme réussies
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
        --jobs)
            [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || {
                echo "ERREUR : --jobs attend un entier strictement positif." >&2
                exit 2
            }
            JOBS=$2
            shift 2
            ;;
        --force)
            FORCE_STEPS+=("build-stm32")
            shift
            ;;
        --force-step)
            [[ $# -ge 2 && "$2" == "build-stm32" ]] || { echo "ERREUR : --force-step attend build-stm32." >&2; exit 2; }
            FORCE_STEPS+=("build-stm32")
            shift 2
            ;;
        --no-resume) RESUME=0; shift ;;
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
