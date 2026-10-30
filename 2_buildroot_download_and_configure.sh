#!/usr/bin/env bash
#
# Étape 2 : acquisition de Buildroot et génération des configurations.

set -Eeuo pipefail
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=uclinux_common.sh
source "$SCRIPT_DIR/uclinux_common.sh"

uclinux_check_buildroot_checkout() {
    uclinux_ensure_workspace_dirs

    if [[ ! -d "$BUILDROOT_DIR/.git" ]]; then
        run_with_log "$LOG_DIR/buildroot-clone-$TIMESTAMP.log" git clone --branch "$BUILDROOT_REF" --depth 1 https://gitlab.com/buildroot.org/buildroot.git "$BUILDROOT_DIR"
    else
        info "dépôt Buildroot déjà présent : $BUILDROOT_DIR"
    fi

    CURRENT_REF="$(git -C "$BUILDROOT_DIR" describe --tags --exact-match 2>/dev/null || true)"
    if [[ "$CURRENT_REF" != "$BUILDROOT_REF" ]]; then
        CURRENT_COMMIT="$(git -C "$BUILDROOT_DIR" rev-parse --short HEAD)"
        die "le dépôt existant n'est pas exactement sur $BUILDROOT_REF (référence détectée : ${CURRENT_REF:-$CURRENT_COMMIT})."
    fi
    ok "Buildroot $BUILDROOT_REF"

    [[ -z "$(git -C "$BUILDROOT_DIR" status --porcelain)" ]] \
        && ok "arbre Buildroot propre" \
        || warn "l'arbre Buildroot contient des modifications locales."
}

uclinux_check_buildroot_defconfigs() {
    STM32_DEFCONFIG="$BUILDROOT_DIR/configs/stm32f429_disco_xip_defconfig"
    QEMU_DEFCONFIG="$BUILDROOT_DIR/configs/qemu_arm_vexpress_defconfig"

    check_file_nonempty "$STM32_DEFCONFIG"
    check_file_nonempty "$QEMU_DEFCONFIG"

    grep -q 'BR2_cortex_m4=y' "$STM32_DEFCONFIG" || die "le defconfig STM32 ne sélectionne pas Cortex-M4."
    grep -q "BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE=\"$EXPECTED_LINUX_VERSION\"" "$STM32_DEFCONFIG" \
        || die "le defconfig STM32 ne sélectionne pas Linux $EXPECTED_LINUX_VERSION."
    grep -q 'BR2_LINUX_KERNEL_IMAGE_TARGET_NAME="xipImage"' "$STM32_DEFCONFIG" || die "xipImage non sélectionnée."
    grep -q 'BR2_TARGET_ROOTFS_INITRAMFS=y' "$STM32_DEFCONFIG" || die "initramfs absent du defconfig STM32 de référence."
    grep -q 'BR2_TARGET_AFBOOT_STM32=y' "$STM32_DEFCONFIG" || die "afboot-stm32 non sélectionné."
    grep -q 'BR2_PACKAGE_HOST_OPENOCD=y' "$STM32_DEFCONFIG" || die "OpenOCD hôte non sélectionné."
    ok "defconfig STM32 de référence reconnu ; la configuration active utilisera U-Boot et ROMFS"
}

uclinux_step_buildroot_download_and_configure() {
    section "5. Acquisition et contrôle de Buildroot"
    uclinux_check_buildroot_checkout
    uclinux_check_buildroot_defconfigs

    section "6. Préparation des configurations actives"
    uclinux_prepare_buildroot stm32
    uclinux_prepare_buildroot qemu
}

usage() {
    cat <<'USAGE'
Étape 2 : acquisition de Buildroot et génération des configurations.

Utilisation :
  ./2_buildroot_download_and_configure.sh [options]

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

uclinux_begin_logging buildroot-download-configure
uclinux_step_buildroot_download_and_configure
section "Étape 2 terminée"
ok "Buildroot est prêt"
