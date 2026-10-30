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

uboot_build_dir() {
    local out=$1
    local matches=()
    local match

    while IFS= read -r match; do
        matches+=("$match")
    done < <(compgen -G "$out/build/uboot-*" | sort)

    [[ "${#matches[@]}" -eq 1 && -d "${matches[0]}" ]] \
        || die "répertoire de build U-Boot unique introuvable dans $out/build"
    printf '%s\n' "${matches[0]}"
}


uclinux_step_build_stm32() {
    local asset_dir="$SCRIPT_DIR/stm32_uboot"

    section "Préparation des sources Linux STM32"
    uclinux_prepare_buildroot stm32

    section "Construction incrémentale STM32F429I-DISC1"
    run_with_log "$LOG_DIR/build-stm32-$TIMESTAMP.log" make_br "$STM32_OUT"

    STALE_AFBOOT_IMAGES=(
        stm32f429i-disco.bin stm32429i-eval.bin stm32746g-eval.bin
        stm32f469i-disco.bin stm32h743i-eval.bin
    )
    for stale_image in "${STALE_AFBOOT_IMAGES[@]}"; do
        if [[ -e "$STM32_OUT/images/$stale_image" ]]; then
            rm -f -- "$STM32_OUT/images/$stale_image"
            warn "ancienne image afboot supprimée : $STM32_OUT/images/$stale_image"
        fi
    done
    STALE_ROMFS_IMAGES=(rootfs.romfs rootfs.tar stm32f429-disco-romfs.dtb)
    for stale_image in "${STALE_ROMFS_IMAGES[@]}"; do
        if [[ -e "$STM32_OUT/images/$stale_image" ]]; then
            rm -f -- "$STM32_OUT/images/$stale_image"
            warn "ancienne image ROMFS supprimée : $STM32_OUT/images/$stale_image"
        fi
    done

    DTB_NAME="$(uclinux_stm32_dtb_name "$STM32_OUT/.config")"
    [[ -n "$DTB_NAME" && "$DTB_NAME" != *" "* ]] || die "nom de DTB STM32 invalide : $DTB_NAME"
    DTB_IMAGE="$STM32_OUT/images/${DTB_NAME##*/}.dtb"
    UBOOT_IMAGE="$STM32_OUT/images/u-boot.bin"
    XIP_IMAGE="$STM32_OUT/images/xipImage"
    UIMAGE="$STM32_OUT/images/uImage"
    STM32_IMAGES=(
        "$UBOOT_IMAGE"
        "$DTB_IMAGE"
        "$XIP_IMAGE"
        "$UIMAGE"
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
    [[ "$(br_config_value "$KERNEL_CONFIG" CONFIG_XIP_PHYS_ADDR)" == "$STM32_XIP_ADDR" ]] \
        || die "le noyau XIP n'est pas lié à $STM32_XIP_ADDR."
    ok "noyau Linux $EXPECTED_LINUX_VERSION : ARM, no-MMU, XIP à $STM32_XIP_ADDR, initramfs"

    UBOOT_BUILD_DIR="$(uboot_build_dir "$STM32_OUT")"
    UBOOT_CONFIG="$UBOOT_BUILD_DIR/.config"
    MKIMAGE="$UBOOT_BUILD_DIR/tools/mkimage"
    check_file_nonempty "$UBOOT_CONFIG"
    check_file_nonempty "$MKIMAGE"
    grep -qx 'CONFIG_ENV_IS_IN_FLASH=y' "$UBOOT_CONFIG" || die "environnement U-Boot Flash inactif."
    grep -qx 'CONFIG_ENV_ADDR=0x08020000' "$UBOOT_CONFIG" || die "adresse d'environnement U-Boot inattendue."
    grep -qx 'CONFIG_ENV_SIZE=0x2000' "$UBOOT_CONFIG" || die "taille d'environnement U-Boot inattendue."
    grep -qx 'CONFIG_ENV_SECT_SIZE=0x20000' "$UBOOT_CONFIG" || die "secteur d'environnement U-Boot inattendu."
    grep -qx '# CONFIG_USE_BOOTARGS is not set' "$UBOOT_CONFIG" || die "U-Boot ne doit pas remplacer /chosen/bootargs."
    grep -Fqx 'CONFIG_BOOTCOMMAND="bootm 0x08040000 - 0x081fb000"' "$UBOOT_CONFIG" \
        || die "commande de démarrage U-Boot inattendue."

    UIMAGE_MAGIC="$(od -An -tx1 -N4 "$UIMAGE" | tr -d '[:space:]')"
    [[ "$UIMAGE_MAGIC" == 27051956 ]] || die "en-tête uImage invalide : $UIMAGE"
    UIMAGE_INFO="$("$MKIMAGE" -l "$UIMAGE")"
    grep -q 'Load Address: 08040040' <<<"$UIMAGE_INFO" || die "adresse de chargement uImage incorrecte."
    grep -q 'Entry Point:  08040040' <<<"$UIMAGE_INFO" || die "point d'entrée uImage incorrect."

    UBOOT_SIZE="$(stat -c %s "$UBOOT_IMAGE")"
    UIMAGE_SIZE="$(stat -c %s "$UIMAGE")"
    DTB_SIZE="$(stat -c %s "$DTB_IMAGE")"
    UBOOT_END=$((STM32_UBOOT_ADDR + UBOOT_SIZE))
    UIMAGE_END=$((STM32_UIMAGE_ADDR + UIMAGE_SIZE))
    DTB_END=$((STM32_DTB_ADDR + DTB_SIZE))
    STUDENT_HEADROOM=$((STM32_DTB_ADDR - UIMAGE_END))
    ((UBOOT_END <= STM32_UBOOT_ENV_ADDR)) \
        || die "U-Boot déborde dans son secteur d'environnement."
    ((UIMAGE_END <= STM32_DTB_ADDR)) \
        || die "uImage déborde dans le DTB."
    ((DTB_END <= STM32_FLASH_END)) \
        || die "DTB dépasse la Flash interne."
    ok "U-Boot $EXPECTED_UBOOT_VERSION construit par Buildroot, environnement persistant en secteur dédié"
    if ((STUDENT_HEADROOM >= STM32_STUDENT_HEADROOM)); then
        ok "marge initramfs étudiante : $STUDENT_HEADROOM octets ($((STUDENT_HEADROOM / 1024)) Kio)"
    else
        warn "marge initramfs restante : $STUDENT_HEADROOM octets, sous la cible initiale de $STM32_STUDENT_HEADROOM"
    fi

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

    DT_DUMP="$LOG_DIR/${DTB_NAME##*/}-$TIMESTAMP.dts"
    dtc -I dtb -O dts "$DTB_IMAGE" > "$DT_DUMP"
    grep -q '/dts-v1/' "$DT_DUMP" || die "le DTB n'a pas pu être décompilé correctement."
    grep -q 'bootargs = "root=/dev/ram";' "$DT_DUMP" || die "bootargs initramfs absents du DTB."
    ok "DTB valide à $STM32_DTB_ADDR ; décompilation enregistrée dans $DT_DUMP"

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
