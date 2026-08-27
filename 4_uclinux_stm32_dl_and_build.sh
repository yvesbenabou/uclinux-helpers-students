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

uclinux_ensure_stm32_config() {
    if [[ -s "$STM32_OUT/.config" ]] \
        && grep -q 'BR2_cortex_m4=y' "$STM32_OUT/.config" \
        && grep -q "BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE=\"$EXPECTED_LINUX_VERSION\"" "$STM32_OUT/.config" \
        && uclinux_stm32_romfs_configured "$STM32_OUT/.config" \
        && uclinux_stm32_uboot_configured "$STM32_OUT/.config"; then
        ok "configuration active STM32 déjà présente : $STM32_OUT/.config"
    else
        uclinux_generate_stm32_config
    fi
}

ramfs_payload_bytes() {
    local target_dir=$1
    local regular_bytes
    local symlink_count

    regular_bytes="$(find "$target_dir" -xdev -type f -printf '%D:%i:%s\n' | awk -F: '
        !seen[$1 ":" $2]++ { total += int(($3 + 4095) / 4096) * 4096 }
        END { print total + 0 }
    ')"
    symlink_count="$(find "$target_dir" -xdev -type l -printf '.\n' | wc -l)"
    printf '%s\n' "$((regular_bytes + symlink_count * 4096))"
}

uclinux_repair_relocated_host_fakeroot() {
    local out=$1
    local fakeroot="$out/host/bin/fakeroot"
    local expected_prefix="FAKEROOT_PREFIX=$out/host"
    local target

    [[ -f "$fakeroot" ]] || return 0
    grep -Fqx "$expected_prefix" "$fakeroot" && return 0

    target="$(basename "$out")"
    warn "fakeroot hôte contient un ancien chemin Buildroot ; reconstruction pour $target"
    run_with_log "$LOG_DIR/rebuild-host-fakeroot-$target-$TIMESTAMP.log" \
        make_br "$out" host-fakeroot-dirclean host-fakeroot
    grep -Fqx "$expected_prefix" "$fakeroot" \
        || die "fakeroot hôte utilise encore un préfixe incorrect : $fakeroot"
    ok "fakeroot hôte réparé pour $target"
}

uclinux_step_build_stm32() {
    local romfs_asset_dir="$SCRIPT_DIR/stm32_romfs"
    local uboot_asset_dir="$SCRIPT_DIR/stm32_uboot"

    section "Préparation des sources Linux STM32"
    uclinux_require_buildroot
    uclinux_ensure_stm32_config
    uclinux_enable_host_environment_setup "$STM32_OUT"
    uclinux_repair_relocated_host_fakeroot "$STM32_OUT"
    prepare_linux_override "$STM32_OUT"

    section "Construction complète STM32F429I-DISC1"
    STM32_BUILD_FINGERPRINT="$(step_fingerprint "$STM32_OUT" \
        "$SCRIPT_DIR/4_uclinux_stm32_dl_and_build.sh" \
        "$SCRIPT_DIR/uclinux_common.sh" \
        "$romfs_asset_dir/linux.fragment" \
        "$romfs_asset_dir/stm32f429-disco-romfs.dts" \
        "$romfs_asset_dir/post_build.sh" \
        "$romfs_asset_dir/post_fakeroot.sh" \
        "$uboot_asset_dir/linux.fragment" \
        "$uboot_asset_dir/uboot.fragment" \
        "$uboot_asset_dir/post_image.sh")"
    if step_completed "build-stm32" "$STM32_BUILD_FINGERPRINT"; then
        ok "étape déjà validée, make STM32 ignoré (--force pour la relancer)"
    else
        # Buildroot does not automatically rerun a package's Kconfig merge when
        # only top-level rootfs choices change. Force the Linux fixups to be
        # recomputed so a previous initramfs build cannot remain stale.
        run_with_log "$LOG_DIR/reconfigure-linux-stm32-$TIMESTAMP.log" make_br "$STM32_OUT" linux-reconfigure
        run_with_log "$LOG_DIR/reconfigure-uboot-stm32-$TIMESTAMP.log" make_br "$STM32_OUT" uboot-reconfigure
        run_with_log "$LOG_DIR/build-stm32-$TIMESTAMP.log" make_br "$STM32_OUT" -j"$JOBS"
    fi

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

    # A previous initramfs build can leave an obsolete image behind even after
    # CPIO generation is disabled. Do not present or accidentally flash it.
    STALE_CPIO_IMAGES=(
        rootfs.cpio rootfs.cpio.gz rootfs.cpio.bz2 rootfs.cpio.lz4
        rootfs.cpio.lzma rootfs.cpio.lzo rootfs.cpio.xz rootfs.cpio.zst
        rootfs.cpio.uboot
    )
    for stale_image in "${STALE_CPIO_IMAGES[@]}"; do
        if [[ -e "$STM32_OUT/images/$stale_image" ]]; then
            rm -f -- "$STM32_OUT/images/$stale_image"
            warn "ancienne image CPIO supprimée : $STM32_OUT/images/$stale_image"
        fi
    done
    if [[ -e "$STM32_OUT/images/stm32f429-disco.dtb" ]]; then
        rm -f -- "$STM32_OUT/images/stm32f429-disco.dtb"
        warn "ancien DTB initramfs supprimé : $STM32_OUT/images/stm32f429-disco.dtb"
    fi

    DTB_NAME="$(uclinux_stm32_dtb_name "$STM32_OUT/.config")"
    [[ -n "$DTB_NAME" && "$DTB_NAME" != *" "* ]] || die "nom de DTB STM32 invalide : $DTB_NAME"
    DTB_IMAGE="$STM32_OUT/images/${DTB_NAME##*/}.dtb"
    UBOOT_IMAGE="$STM32_OUT/images/u-boot.bin"
    ROMFS_IMAGE="$STM32_OUT/images/rootfs.romfs"
    XIP_IMAGE="$STM32_OUT/images/xipImage"
    UIMAGE="$STM32_OUT/images/uImage"
    STM32_IMAGES=(
        "$UBOOT_IMAGE"
        "$DTB_IMAGE"
        "$XIP_IMAGE"
        "$UIMAGE"
        "$ROMFS_IMAGE"
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
    [[ "$(br_config_value "$KERNEL_CONFIG" CONFIG_XIP_PHYS_ADDR)" == "$STM32_XIP_ADDR" ]] \
        || die "le noyau XIP n'est pas lié à $STM32_XIP_ADDR."
    grep -qx '# CONFIG_BLK_DEV_INITRD is not set' "$KERNEL_CONFIG" || die "CONFIG_BLK_DEV_INITRD est encore actif."
    [[ -z "$(br_config_value "$KERNEL_CONFIG" CONFIG_INITRAMFS_SOURCE)" ]] || die "une source initramfs est encore configurée dans le noyau."
    grep -qx 'CONFIG_MTD=y' "$KERNEL_CONFIG" || die "CONFIG_MTD n'est pas actif."
    grep -qx 'CONFIG_MTD_ROM=y' "$KERNEL_CONFIG" || die "CONFIG_MTD_ROM n'est pas actif."
    grep -qx 'CONFIG_MTD_PHYSMAP=y' "$KERNEL_CONFIG" || die "CONFIG_MTD_PHYSMAP n'est pas actif."
    grep -qx 'CONFIG_MTD_PHYSMAP_OF=y' "$KERNEL_CONFIG" || die "CONFIG_MTD_PHYSMAP_OF n'est pas actif."
    grep -qx 'CONFIG_MTD_OF_PARTS=y' "$KERNEL_CONFIG" || die "le parseur de partitions MTD du DT n'est pas actif."
    grep -qx 'CONFIG_ROMFS_FS=y' "$KERNEL_CONFIG" || die "CONFIG_ROMFS_FS n'est pas actif."
    grep -qx 'CONFIG_ROMFS_BACKED_BY_MTD=y' "$KERNEL_CONFIG" || die "ROMFS n'utilise pas directement MTD."
    ok "noyau Linux $EXPECTED_LINUX_VERSION : ARM, no-MMU, XIP à $STM32_XIP_ADDR, ROMFS sur MTD"

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

    ROMFS_MAGIC="$(dd if="$ROMFS_IMAGE" bs=8 count=1 2>/dev/null)"
    [[ "$ROMFS_MAGIC" == '-rom1fs-' ]] || die "signature ROMFS invalide : $ROMFS_IMAGE"
    UBOOT_SIZE="$(stat -c %s "$UBOOT_IMAGE")"
    UIMAGE_SIZE="$(stat -c %s "$UIMAGE")"
    ROMFS_SIZE="$(stat -c %s "$ROMFS_IMAGE")"
    DTB_SIZE="$(stat -c %s "$DTB_IMAGE")"
    UBOOT_END=$((STM32_UBOOT_ADDR + UBOOT_SIZE))
    UIMAGE_END=$((STM32_UIMAGE_ADDR + UIMAGE_SIZE))
    ROMFS_END=$((STM32_ROMFS_ADDR + ROMFS_SIZE))
    DTB_END=$((STM32_DTB_ADDR + DTB_SIZE))
    KERNEL_HEADROOM=$((STM32_ROMFS_ADDR - UIMAGE_END))
    STUDENT_HEADROOM=$((STM32_DTB_ADDR - ROMFS_END))
    ((STM32_ROMFS_ADDR + STM32_ROMFS_PARTITION_SIZE == STM32_DTB_ADDR)) \
        || die "la partition ROMFS ne se termine pas au début du DTB."
    ((UBOOT_END <= STM32_UBOOT_ENV_ADDR)) \
        || die "U-Boot déborde dans son secteur d'environnement."
    ((UIMAGE_END <= STM32_ROMFS_ADDR)) \
        || die "uImage déborde dans ROMFS."
    ((ROMFS_END <= STM32_DTB_ADDR)) \
        || die "ROMFS déborde dans le DTB."
    ((DTB_END <= STM32_FLASH_END)) \
        || die "DTB dépasse la Flash interne."
    ok "U-Boot $EXPECTED_UBOOT_VERSION construit par Buildroot, environnement persistant en secteur dédié"
    ok "marge noyau avant ROMFS : $KERNEL_HEADROOM octets ($((KERNEL_HEADROOM / 1024)) Kio)"
    if ((STUDENT_HEADROOM >= STM32_STUDENT_HEADROOM)); then
        ok "marge ROMFS étudiante : $STUDENT_HEADROOM octets ($((STUDENT_HEADROOM / 1024)) Kio)"
    else
        warn "marge ROMFS restante : $STUDENT_HEADROOM octets, sous la cible initiale de $STM32_STUDENT_HEADROOM"
    fi

    check_file_nonempty "$STM32_OUT/target/bin/busybox"
    ok "BusyBox installé dans le rootfs préparé"
    RAMFS_BYTES="$(ramfs_payload_bytes "$STM32_OUT/target")"
    printf 'Pages de données ramfs évitées : %d octets (%d Kio, %.2f Mio), hors métadonnées inode/dentry.\n' \
        "$RAMFS_BYTES" "$((RAMFS_BYTES / 1024))" "$(awk -v bytes="$RAMFS_BYTES" 'BEGIN { printf "%.2f", bytes / 1048576 }')"

    TARGET_GCC="$(find "$STM32_OUT/host/bin" -maxdepth 1 \( -type f -o -type l \) -name '*-gcc' | sort | head -n1)"
    [[ -n "$TARGET_GCC" ]] || die "compilateur croisé introuvable dans $STM32_OUT/host/bin."
    file "$TARGET_GCC"
    printf 'Triplet cible : %s\n' "$("$TARGET_GCC" -dumpmachine)"
    ok "chaîne de compilation croisée opérationnelle"

    check_file_nonempty "$STM32_OUT/host/bin/openocd"
    file "$STM32_OUT/host/bin/openocd"
    "$STM32_OUT/host/bin/openocd" --version 2>&1 | head -n1
    ok "OpenOCD hôte construit par Buildroot"

    DT_DUMP="$LOG_DIR/${DTB_NAME##*/}-$TIMESTAMP.dts"
    dtc -I dtb -O dts "$DTB_IMAGE" > "$DT_DUMP"
    grep -q '/dts-v1/' "$DT_DUMP" || die "le DTB n'a pas pu être décompilé correctement."
    grep -q 'bootargs = "root=mtd0 rootfstype=romfs ro";' "$DT_DUMP" || die "bootargs ROMFS absents du DTB."
    grep -q 'compatible = "mtd-rom";' "$DT_DUMP" || die "nœud mtd-rom absent du DTB."
    grep -q 'flash@8000000' "$DT_DUMP" || die "mapping de la Flash interne absent du DTB."
    grep -q 'compatible = "fixed-partitions";' "$DT_DUMP" || die "partitions MTD fixes absentes du DTB."
    grep -q 'partition@180000' "$DT_DUMP" || die "partition rootfs absente du DTB."
    ok "DTB valide : Flash complète et partition rootfs exacte, sans arrondi physmap"
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
