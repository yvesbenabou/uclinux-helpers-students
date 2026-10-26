#!/usr/bin/env bash
#
# Étape 4 : téléchargement des sources Linux et build STM32F429I-DISC1.

set -Eeuo pipefail
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=uclinux_common.sh
source "$SCRIPT_DIR/uclinux_common.sh"

# BR2_EXTERNAL is persisted by Buildroot in the output directory. Override it
# only when the caller supplies the environment variable or command-line option;
# otherwise let Buildroot reuse its remembered external tree.
UCLINUX_BR2_EXTERNAL_SET=0
if [[ ${BR2_EXTERNAL+x} ]]; then
    UCLINUX_BR2_EXTERNAL_SET=1
fi
REBUILD_PACKAGES=()

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

stm32_linux_inputs_fingerprint() {
    local asset_dir=$1

    {
        printf 'buildroot=%s\nlinux=%s\n' "$BUILDROOT_REF" "$EXPECTED_LINUX_VERSION"
        sha256sum \
            "$asset_dir/linux.fragment" \
            "$asset_dir/patches/linux/0001-if-stm32-nommu-define-have-arch-fb-unmapped-area.patch" \
            "$asset_dir/patches/linux/0002-fbdev-add-stm32f429-disco-simplefb-init.patch" \
            "$asset_dir/stm32f429-disco-romfs.dts"
    } | sha256sum | awk '{print $1}'
}

uclinux_ensure_stm32_config() {
    if [[ -s "$STM32_OUT/.config" ]] \
        && grep -Fqx 'BR2_cortex_m4=y' "$STM32_OUT/.config" \
        && grep -Fqx "BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE=\"$EXPECTED_LINUX_VERSION\"" "$STM32_OUT/.config" \
        && uclinux_stm32_romfs_configured "$STM32_OUT/.config"; then
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

uclinux_reconcile_stm32_images() {
    local stale_image

    # The U-Boot branches deliberately remove the afboot image. Buildroot may
    # still consider the package installed when returning to this branch.
    if [[ ! -s "$STM32_OUT/images/stm32f429i-disco.bin" ]]; then
        run_with_log "$LOG_DIR/reinstall-afboot-stm32-$TIMESTAMP.log" \
            make_br "$STM32_OUT" afboot-stm32-reinstall
    fi

    # A previous initramfs branch can leave obsolete images behind after CPIO
    # generation is disabled. Never present or accidentally flash those files.
    for stale_image in \
        rootfs.cpio rootfs.cpio.gz rootfs.cpio.bz2 rootfs.cpio.lz4 \
        rootfs.cpio.lzma rootfs.cpio.lzo rootfs.cpio.xz rootfs.cpio.zst \
        rootfs.cpio.uboot; do
        if [[ -e "$STM32_OUT/images/$stale_image" ]]; then
            rm -f -- "$STM32_OUT/images/$stale_image"
            warn "ancienne image CPIO supprimée : $STM32_OUT/images/$stale_image"
        fi
    done
}

uclinux_step_build_stm32() {
    local asset_dir="$SCRIPT_DIR/stm32_romfs"
    local linux_inputs_state="$STATE_DIR/linux-stm32-inputs.sha256"
    local linux_config="$STM32_OUT/build/linux-$EXPECTED_LINUX_VERSION/.config"
    local previous_linux_inputs=""
    local package

    section "Préparation des sources Linux STM32"
    uclinux_require_buildroot
    uclinux_ensure_stm32_config
    uclinux_enable_host_environment_setup "$STM32_OUT"

    section "Construction incrémentale STM32F429I-DISC1"
    if [[ "$UCLINUX_BR2_EXTERNAL_SET" == 1 && -z "${BR2_EXTERNAL-}" ]]; then
        warn "BR2_EXTERNAL détaché explicitement ; les fichiers de paquets déjà installés peuvent rester dans target/ jusqu'à un build propre"
    fi
    STM32_LINUX_INPUTS_FINGERPRINT="$(stm32_linux_inputs_fingerprint "$asset_dir")"
    if [[ -s "$linux_inputs_state" ]]; then
        previous_linux_inputs="$(<"$linux_inputs_state")"
    fi
    # linux-reconfigure preserves patched sources and existing objects. When a
    # kernel patch or other Linux input changes, re-extract only Linux.
    if [[ -n "$previous_linux_inputs" \
        && "$previous_linux_inputs" != "$STM32_LINUX_INPUTS_FINGERPRINT" ]]; then
        run_with_log "$LOG_DIR/dirclean-linux-stm32-$TIMESTAMP.log" \
            make_br "$STM32_OUT" linux-dirclean
    elif [[ ! -s "$linux_config" ]] \
        || ! grep -qx 'CONFIG_SPI_STM32=y' "$linux_config" \
        || ! grep -qx 'CONFIG_FB_STM32=y' "$linux_config"; then
        run_with_log "$LOG_DIR/reconfigure-linux-stm32-$TIMESTAMP.log" \
            make_br "$STM32_OUT" linux-reconfigure
    fi

    for package in "${REBUILD_PACKAGES[@]}"; do
        run_with_log "$LOG_DIR/rebuild-$package-stm32-$TIMESTAMP.log" \
            make_br "$STM32_OUT" "${package}-rebuild"
    done
    run_with_log "$LOG_DIR/build-stm32-$TIMESTAMP.log" make_br "$STM32_OUT"
    uclinux_reconcile_stm32_images

    # These belong to the U-Boot or initramfs layouts, not this AFBOOT ROMFS
    # layout.  Keeping them would make the images directory misleading.
    STALE_OTHER_LAYOUT_IMAGES=(u-boot.bin uImage stm32f429-disco.dtb)
    for stale_image in "${STALE_OTHER_LAYOUT_IMAGES[@]}"; do
        if [[ -e "$STM32_OUT/images/$stale_image" ]]; then
            rm -f -- "$STM32_OUT/images/$stale_image"
            warn "image d'une autre variante supprimée : $stale_image"
        fi
    done

    DTB_NAME="$(uclinux_stm32_dtb_name "$STM32_OUT/.config")"
    [[ -n "$DTB_NAME" && "$DTB_NAME" != *" "* ]] || die "nom de DTB STM32 invalide : $DTB_NAME"
    DTB_IMAGE="$STM32_OUT/images/${DTB_NAME##*/}.dtb"
    ROMFS_IMAGE="$STM32_OUT/images/rootfs.romfs"
    XIP_IMAGE="$STM32_OUT/images/xipImage"
    STM32_IMAGES=(
        "$STM32_OUT/images/stm32f429i-disco.bin"
        "$DTB_IMAGE"
        "$XIP_IMAGE"
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
    grep -qx '# CONFIG_BLK_DEV_INITRD is not set' "$KERNEL_CONFIG" || die "CONFIG_BLK_DEV_INITRD est encore actif."
    [[ -z "$(br_config_value "$KERNEL_CONFIG" CONFIG_INITRAMFS_SOURCE)" ]] || die "une source initramfs est encore configurée dans le noyau."
    grep -qx 'CONFIG_MTD=y' "$KERNEL_CONFIG" || die "CONFIG_MTD n'est pas actif."
    grep -qx 'CONFIG_MTD_ROM=y' "$KERNEL_CONFIG" || die "CONFIG_MTD_ROM n'est pas actif."
    grep -qx 'CONFIG_MTD_PHYSMAP=y' "$KERNEL_CONFIG" || die "CONFIG_MTD_PHYSMAP n'est pas actif."
    grep -qx 'CONFIG_MTD_PHYSMAP_OF=y' "$KERNEL_CONFIG" || die "CONFIG_MTD_PHYSMAP_OF n'est pas actif."
    grep -qx 'CONFIG_MTD_OF_PARTS=y' "$KERNEL_CONFIG" || die "le parseur de partitions MTD du DT n'est pas actif."
    grep -qx 'CONFIG_ROMFS_FS=y' "$KERNEL_CONFIG" || die "CONFIG_ROMFS_FS n'est pas actif."
    grep -qx 'CONFIG_ROMFS_BACKED_BY_MTD=y' "$KERNEL_CONFIG" || die "ROMFS n'utilise pas directement MTD."
    grep -qx 'CONFIG_SPI_STM32=y' "$KERNEL_CONFIG" || die "le contrôleur SPI STM32 n'est pas actif."
    grep -qx 'CONFIG_FB_SIMPLE=y' "$KERNEL_CONFIG" || die "CONFIG_FB_SIMPLE n'est pas actif."
    grep -qx 'CONFIG_FB_STM32F429_DISCO_SIMPLE=y' "$KERNEL_CONFIG" || die "l'initialiseur LTDC/ILI9341 compact n'est pas actif."
    grep -qx '# CONFIG_DRM is not set' "$KERNEL_CONFIG" || die "DRM est encore actif."
    ok "noyau Linux $EXPECTED_LINUX_VERSION : ARM, no-MMU, XIP, ROMFS sur MTD, LTDC/ILI9341 simplefb avec /dev/fb0"

    ROMFS_MAGIC="$(dd if="$ROMFS_IMAGE" bs=8 count=1 2>/dev/null)"
    [[ "$ROMFS_MAGIC" == '-rom1fs-' ]] || die "signature ROMFS invalide : $ROMFS_IMAGE"
    XIP_ADDR="$(br_config_value "$KERNEL_CONFIG" CONFIG_XIP_PHYS_ADDR)"
    [[ "$XIP_ADDR" =~ ^0[xX][0-9a-fA-F]+$ ]] || die "CONFIG_XIP_PHYS_ADDR invalide : $XIP_ADDR"
    XIP_SIZE="$(stat -c %s "$XIP_IMAGE")"
    ROMFS_SIZE="$(stat -c %s "$ROMFS_IMAGE")"
    XIP_END=$((XIP_ADDR + XIP_SIZE))
    ROMFS_END=$((STM32_ROMFS_ADDR + ROMFS_SIZE))
    ROMFS_PARTITION_END=$((STM32_ROMFS_ADDR + STM32_ROMFS_PARTITION_SIZE))
    STUDENT_HEADROOM=$((ROMFS_PARTITION_END - ROMFS_END))
    ((ROMFS_PARTITION_END == STM32_FLASH_END)) \
        || die "la partition ROMFS ne couvre pas exactement la fin de la Flash."
    ((XIP_END <= STM32_ROMFS_ADDR)) \
        || die "xipImage déborde dans ROMFS : fin=0x$(printf '%08X' "$XIP_END"), ROMFS=$STM32_ROMFS_ADDR"
    ((ROMFS_END <= ROMFS_PARTITION_END)) \
        || die "ROMFS dépasse sa partition : fin=0x$(printf '%08X' "$ROMFS_END"), limite=0x$(printf '%08X' "$ROMFS_PARTITION_END")"
    ok "plan Flash sans recouvrement : noyau $(printf '0x%08X-0x%08X' "$((XIP_ADDR))" "$XIP_END"), ROMFS $(printf '0x%08X-0x%08X' "$((STM32_ROMFS_ADDR))" "$ROMFS_END")"
    if ((STUDENT_HEADROOM >= STM32_STUDENT_HEADROOM)); then
        ok "marge ROMFS étudiante : $STUDENT_HEADROOM octets ($((STUDENT_HEADROOM / 1024)) Kio)"
    else
        warn "marge ROMFS restante : $STUDENT_HEADROOM octets, sous la cible de $STM32_STUDENT_HEADROOM"
    fi

    check_file_nonempty "$STM32_OUT/target/bin/busybox"
    for removed_applet in \
        cksum crc32 sha1sum sha256sum sha512sum sha3sum \
        mke2fs mkdosfs getfattr lsscsi partprobe setfattr \
        nl ascii factor fallocate hostid svc svok w uudecode uuencode \
        linux32 linux64 mim adduser fsfreeze seedrng bc setserial \
        zcat bzcat lzcat xzcat unlzop lzopcat \
        i2ctransfer start-stop-daemon run-init resume nuke freeramdisk \
        hexedit od shred install setpriv nologin passwd; do
        [[ ! -e "$STM32_OUT/target/bin/$removed_applet" \
            && ! -e "$STM32_OUT/target/sbin/$removed_applet" \
            && ! -e "$STM32_OUT/target/usr/bin/$removed_applet" \
            && ! -e "$STM32_OUT/target/usr/sbin/$removed_applet" ]] \
            || die "applet BusyBox inutile encore présent : $removed_applet"
    done
    for removed_file in etc/services etc/protocols THIS_IS_NOT_YOUR_ROOT_FILESYSTEM; do
        [[ ! -e "$STM32_OUT/target/$removed_file" ]] \
            || die "fichier ROMFS inutile encore présent : $removed_file"
    done
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
    grep -q 'flash@8000000' "$DT_DUMP" || die "mapping de la Flash interne complète absent du DTB."
    grep -q 'reg = <0x8000000 0x200000>;' "$DT_DUMP" || die "taille du mapping Flash incorrecte dans le DTB."
    grep -q 'compatible = "fixed-partitions";' "$DT_DUMP" || die "partitions MTD fixes absentes du DTB."
    grep -q 'partition@180000' "$DT_DUMP" || die "partition rootfs à $STM32_ROMFS_ADDR absente du DTB."
    grep -q 'reg = <0x180000 0x80000>;' "$DT_DUMP" || die "taille de la partition rootfs incorrecte dans le DTB."
    grep -q 'compatible = "simple-framebuffer";' "$DT_DUMP" || die "nœud simple-framebuffer absent du DTB."
    grep -q 'reg = <0x907d8000 0x25800>;' "$DT_DUMP" || die "reg framebuffer incorrect dans le DTB."
    grep -q 'reg = <0x907d8000 0x26000>;' "$DT_DUMP" || die "reg reserved-memory incorrect dans le DTB."
    grep -q 'compatible = "st,stm32f429-disco-simplefb-init";' "$DT_DUMP" || die "initialiseur compact absent du DTB."
    ok "DTB valide : Flash complète et partition rootfs exacte, sans arrondi physmap ; décompilation dans $DT_DUMP"
    printf '%s\n' "$STM32_LINUX_INPUTS_FINGERPRINT" >"$linux_inputs_state"

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
  --root CHEMIN           Racine de travail, défaut : $UCLINUX_ROOT ou $HOME/uclinux
  --br2-external CHEMIN   Arbre(s) BR2_EXTERNAL, prioritaire sur l'environnement
  --redo-package NOM      Reconstruire/réinstaller un paquet, option répétable
  --quiet                 Masquer la sortie verbeuse des commandes longues
  --debug                 Tracer l'entrée et la sortie des fonctions
  -h, --help              Afficher cette aide

La variable d'environnement BR2_EXTERNAL est aussi acceptée. Sans option ni
variable, Buildroot réutilise la valeur mémorisée dans le répertoire de sortie.
Une liste de chemins peut être séparée par des deux-points. Une valeur vide
explicite détache les arbres externes, mais ne désinstalle pas leurs fichiers.
USAGE
}

while (($#)); do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || { echo "ERREUR : --root attend un chemin." >&2; exit 2; }
            WORK_ROOT=$2
            shift 2
            ;;
        --br2-external)
            [[ $# -ge 2 ]] || { echo "ERREUR : --br2-external attend un chemin (ou une chaîne vide)." >&2; exit 2; }
            BR2_EXTERNAL=$2
            UCLINUX_BR2_EXTERNAL_SET=1
            shift 2
            ;;
        --redo-package)
            [[ $# -ge 2 && "$2" =~ ^[a-z0-9][a-z0-9+_.-]*$ ]] || {
                echo "ERREUR : --redo-package attend un nom de paquet Buildroot." >&2
                exit 2
            }
            REBUILD_PACKAGES+=("$2")
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
