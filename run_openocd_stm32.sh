#!/usr/bin/env bash
#
# Run OpenOCD against the STM32F429I-DISC1 Buildroot image.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=uclinux_common.sh
source "$SCRIPT_DIR/uclinux_common.sh"

check_dir() {
    local path=$1
    [[ -d "$path" ]] || die "répertoire absent : $path"
}

stlink_permission_help() {
    local rules=$1
    local current_user=${USER:-${LOGNAME:-utilisateur}}

    warn "OpenOCD voit le ST-LINK mais libusb n'a pas le droit de l'ouvrir."
    if [[ -f "$rules" ]]; then
        warn "Installez les règles udev OpenOCD standard puis débranchez/rebranchez le ST-LINK :"
        printf '  sudo install -m 0644 %q /etc/udev/rules.d/60-openocd.rules\n' "$rules" >&2
        printf '  sudo udevadm control --reload-rules\n' >&2
        printf '  sudo udevadm trigger --subsystem-match=usb\n' >&2
        printf '  sudo usermod -aG plugdev %q   # puis nouvelle session si nécessaire\n' "$current_user" >&2
    else
        warn "règles udev OpenOCD introuvables : $rules"
        warn "Installez les règles udev OpenOCD du paquet/distribution, puis reconnectez le ST-LINK."
    fi
}

WORK_ROOT="$(uclinux_default_root)"
STM32_OUT=""
BOARD_NAME="stm32f429disc1"
LOG_FILE=""
VERIFY=0
MODE=""

config_value() {
    local config=$1
    local key=$2
    local value

    value="$(sed -n "s/^${key}=//p" "$config" | head -n1)"
    value="${value%\"}"
    value="${value#\"}"
    printf '%s\n' "$value"
}

require_config_value() {
    local config=$1
    local key=$2
    local value

    value="$(config_value "$config" "$key")"
    [[ -n "$value" ]] || die "valeur $key introuvable dans $config"
    printf '%s\n' "$value"
}

normalize_address() {
    local value=$1

    if [[ "$value" =~ ^0[xX][0-9a-fA-F]+$ ]]; then
        printf '0x%08X\n' "$((value))"
    elif [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '0x%08X\n' "$((10#$value))"
    else
        die "adresse invalide : $value"
    fi
}

check_image_before() {
    local description=$1
    local image=$2
    local address=$3
    local next_description=$4
    local next_address=$5
    local size
    local end

    size="$(stat -c %s "$image")"
    end=$((address + size))
    ((end <= next_address)) || die \
        "$description déborde sur $next_description : $(printf '0x%08X-0x%08X' "$((address))" "$end"), limite $(printf '0x%08X' "$((next_address))")"
}

find_unique_glob() {
    local pattern=$1
    local description=$2
    local matches=()
    local match

    while IFS= read -r match; do
        matches+=("$match")
    done < <(compgen -G "$pattern" | sort)

    case "${#matches[@]}" in
        1) printf '%s\n' "${matches[0]}" ;;
        0) die "$description introuvable ($pattern)" ;;
        *) die "$description ambigu : ${matches[*]}" ;;
    esac
}

find_linux_config() {
    local br_config=$1
    local version
    local candidates=()
    local candidate

    version="$(config_value "$br_config" BR2_LINUX_KERNEL_VERSION)"
    [[ -n "$version" ]] || version="$(config_value "$br_config" BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE)"

    candidates+=("$STM32_OUT/build/linux-custom/.config")
    [[ -z "$version" ]] || candidates+=("$STM32_OUT/build/linux-$version/.config")

    for candidate in "${candidates[@]}"; do
        if [[ -s "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    die "configuration Linux construite introuvable dans $STM32_OUT/build"
}

afboot_linker_script() {
    local makefile=$1
    local target=$2
    local linker_script

    linker_script="$(awk -v target="$target" '
        index($0, target ":") == 1 { in_target = 1; next }
        in_target && $0 ~ /^[^[:space:]].*:/ { exit }
        in_target && /[$][(]LD[)]/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "-T" && (i + 1) <= NF) {
                    print $(i + 1)
                    exit
                }
                if ($i ~ /^-T./) {
                    sub(/^-T/, "", $i)
                    print $i
                    exit
                }
            }
        }
    ' "$makefile")"

    [[ -n "$linker_script" ]] || die "script de lien introuvable pour $target dans $makefile"
    printf '%s/%s\n' "$(dirname "$makefile")" "$linker_script"
}

linker_flash_origin() {
    local linker_script=$1
    local origin

    origin="$(sed -n -E 's/.*FLASH[[:space:]]*\([^)]*\)[[:space:]]*:[[:space:]]*ORIGIN[[:space:]]*=[[:space:]]*([^,[:space:]]+).*/\1/p' "$linker_script" | head -n1)"
    [[ -n "$origin" ]] || die "origine FLASH introuvable dans $linker_script"
    normalize_address "$origin"
}

usage() {
    cat <<'USAGE'
Exécute OpenOCD pour la carte STM32F429I-DISC1.

Utilisation :
  ./run_openocd_stm32.sh probe [options]
  ./run_openocd_stm32.sh flash [options]

Modes :
  probe   Tester la connexion OpenOCD sans écrire la Flash.
  flash   Écrire les images Buildroot puis redémarrer la carte.

Options :
  --root CHEMIN       Racine de travail, défaut : $UCLINUX_ROOT ou $HOME/uclinux
  --output CHEMIN     Répertoire de sortie Buildroot STM32
  --board NOM         Configuration OpenOCD, défaut : stm32f429disc1
                      Autre valeur courante : stm32f429discovery
  --log CHEMIN        Journal OpenOCD
  --verify            Vérifier les images après écriture, mode flash seulement
  -h, --help          Afficher cette aide

Console série Linux sur USART1 à 115200 bauds :
  carte PA9  -> RX USB-TTL
  carte PA10 -> TX USB-TTL
  carte GND  -> GND USB-TTL
USAGE
}

if (($#)); then
    case "$1" in
        probe|flash)
            MODE=$1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
    esac
fi

if [[ -z "$MODE" ]]; then
    usage >&2
    die "mode requis : probe ou flash"
fi

while (($#)); do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || die "--root attend un chemin"
            WORK_ROOT=$2
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || die "--output attend un chemin"
            STM32_OUT=$2
            shift 2
            ;;
        --board)
            [[ $# -ge 2 ]] || die "--board attend un nom de carte"
            BOARD_NAME=$2
            shift 2
            ;;
        --log)
            [[ $# -ge 2 ]] || die "--log attend un chemin"
            LOG_FILE=$2
            shift 2
            ;;
        --verify)
            VERIFY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "option inconnue : $1"
            ;;
    esac
done

if ((VERIFY)) && [[ "$MODE" != "flash" ]]; then
    die "--verify s'utilise uniquement avec le mode flash"
fi

WORK_ROOT="$(uclinux_realpath "$WORK_ROOT")"
STM32_OUT="${STM32_OUT:-$(uclinux_stm32_output_dir "$WORK_ROOT")}"
STM32_OUT="$(uclinux_realpath "$STM32_OUT")"
IMAGES_DIR="$STM32_OUT/images"

OPENOCD="$STM32_OUT/host/bin/openocd"
OPENOCD_SCRIPTS="$STM32_OUT/host/share/openocd/scripts"
UDEV_RULES="$STM32_OUT/host/share/openocd/contrib/60-openocd.rules"

BR_CONFIG="$STM32_OUT/.config"
BOOTLOADER=""
BOOTLOADER_ADDR=""
AFBOOT_BUILD_DIR=""
AFBOOT_LINKER_SCRIPT=""
DTB=""
DTB_ADDR=""
XIP_IMAGE=""
XIP_IMAGE_ADDR=""
ROMFS_IMAGE=""
ROMFS_IMAGE_ADDR=""

check_file_nonempty "$OPENOCD"
check_dir "$OPENOCD_SCRIPTS"
if [[ "$MODE" == "flash" ]]; then
    check_file_nonempty "$BR_CONFIG"

    BOOTLOADER="$(find_unique_glob "$IMAGES_DIR/stm32f429i-disco.bin" "image afboot STM32")"
    DTB_NAME="$(uclinux_stm32_dtb_name "$BR_CONFIG")" \
        || die "nom du DTB STM32 introuvable dans la configuration Buildroot"
    [[ "$DTB_NAME" != *" "* ]] || die "plusieurs DTB configurés ; utilisez --output avec une configuration STM32 dédiée"
    DTB="$IMAGES_DIR/${DTB_NAME##*/}.dtb"
    XIP_IMAGE_NAME="$(config_value "$BR_CONFIG" BR2_LINUX_KERNEL_IMAGE_NAME)"
    [[ -n "$XIP_IMAGE_NAME" ]] || XIP_IMAGE_NAME="$(require_config_value "$BR_CONFIG" BR2_LINUX_KERNEL_IMAGE_TARGET_NAME)"
    XIP_IMAGE="$IMAGES_DIR/$XIP_IMAGE_NAME"
    ROMFS_IMAGE="$IMAGES_DIR/rootfs.romfs"

    check_file_nonempty "$BOOTLOADER"
    check_file_nonempty "$DTB"
    check_file_nonempty "$XIP_IMAGE"
    check_file_nonempty "$ROMFS_IMAGE"
    [[ "$(dd if="$ROMFS_IMAGE" bs=8 count=1 2>/dev/null)" == '-rom1fs-' ]] \
        || die "signature ROMFS invalide : $ROMFS_IMAGE"

    BOOTLOADER_BASE="${BOOTLOADER##*/}"
    BOOTLOADER_BASE="${BOOTLOADER_BASE%.bin}"
    AFBOOT_BUILD_DIR="$(find_unique_glob "$STM32_OUT/build/afboot-stm32-*" "répertoire de build afboot")"
    AFBOOT_LINKER_SCRIPT="$(afboot_linker_script "$AFBOOT_BUILD_DIR/Makefile" "$BOOTLOADER_BASE")"
    LINUX_CONFIG="$(find_linux_config "$BR_CONFIG")"
    BOOTLOADER_ADDR="$(linker_flash_origin "$AFBOOT_LINKER_SCRIPT")"
    DTB_ADDR="$(normalize_address "$(require_config_value "$BR_CONFIG" BR2_TARGET_AFBOOT_STM32_DTB_ADDR)")"
    XIP_IMAGE_ADDR="$(normalize_address "$(require_config_value "$LINUX_CONFIG" CONFIG_XIP_PHYS_ADDR)")"
    ROMFS_IMAGE_ADDR="$(normalize_address "$STM32_ROMFS_ADDR")"
    AFBOOT_KERNEL_ADDR="$(config_value "$BR_CONFIG" BR2_TARGET_AFBOOT_STM32_KERNEL_ADDR)"
    if [[ -n "$AFBOOT_KERNEL_ADDR" && "$(normalize_address "$AFBOOT_KERNEL_ADDR")" != "$XIP_IMAGE_ADDR" ]]; then
        die "adresse noyau incohérente : CONFIG_XIP_PHYS_ADDR=$XIP_IMAGE_ADDR mais BR2_TARGET_AFBOOT_STM32_KERNEL_ADDR=$(normalize_address "$AFBOOT_KERNEL_ADDR")"
    fi

    check_image_before afboot "$BOOTLOADER" "$BOOTLOADER_ADDR" DTB "$DTB_ADDR"
    check_image_before DTB "$DTB" "$DTB_ADDR" xipImage "$XIP_IMAGE_ADDR"
    check_image_before xipImage "$XIP_IMAGE" "$XIP_IMAGE_ADDR" ROMFS "$ROMFS_IMAGE_ADDR"
    check_image_before ROMFS "$ROMFS_IMAGE" "$ROMFS_IMAGE_ADDR" "fin de la Flash" "$STM32_FLASH_END"
fi

if [[ -z "$LOG_FILE" ]]; then
    if [[ "$MODE" == "probe" ]]; then
        LOG_FILE="$(uclinux_default_log_file "$WORK_ROOT" openocd-probe)"
    else
        LOG_FILE="$(uclinux_default_log_file "$WORK_ROOT" openocd-flash-run)"
    fi
fi

OPENOCD_CMD=(
    "$OPENOCD"
    -s "$OPENOCD_SCRIPTS"
    -f "board/$BOARD_NAME.cfg"
    -c "init"
)

if [[ "$MODE" == "probe" ]]; then
    OPENOCD_CMD+=(
        -c "reset halt"
        -c "flash probe 0"
        -c "flash info 0"
        -c "shutdown"
    )
else
    OPENOCD_CMD+=(
        -c "reset init"
        -c "flash probe 0"
        -c "flash info 0"
        -c "flash write_image erase $BOOTLOADER $BOOTLOADER_ADDR"
        -c "flash write_image erase $DTB $DTB_ADDR"
        -c "flash write_image erase $XIP_IMAGE $XIP_IMAGE_ADDR"
        -c "flash write_image erase $ROMFS_IMAGE $ROMFS_IMAGE_ADDR"
    )

    if ((VERIFY)); then
        OPENOCD_CMD+=(
            -c "verify_image $BOOTLOADER $BOOTLOADER_ADDR"
            -c "verify_image $DTB $DTB_ADDR"
            -c "verify_image $XIP_IMAGE $XIP_IMAGE_ADDR"
            -c "verify_image $ROMFS_IMAGE $ROMFS_IMAGE_ADDR"
        )
    fi

    OPENOCD_CMD+=(
        -c "reset run"
        -c "shutdown"
    )
fi

if [[ "$MODE" == "probe" ]]; then
    info "Test OpenOCD de la carte STM32 depuis $STM32_OUT ; aucune écriture Flash."
else
    info "Flashage de l'image STM32 depuis $STM32_OUT"
    info "Plan Flash : afboot=$BOOTLOADER_ADDR, dtb=$DTB_ADDR, noyau=$XIP_IMAGE_ADDR, ROMFS=$ROMFS_IMAGE_ADDR"
fi
info "Configuration OpenOCD : board/$BOARD_NAME.cfg"
info "Journal OpenOCD : $LOG_FILE"

if run_logged "$LOG_FILE" "${OPENOCD_CMD[@]}"; then
    rc=0
else
    rc=$?
    if grep -q 'LIBUSB_ERROR_ACCESS' "$LOG_FILE"; then
        stlink_permission_help "$UDEV_RULES"
    fi
    die "OpenOCD a échoué (code $rc)"
fi

if [[ "$MODE" == "probe" ]]; then
    info "Test OpenOCD terminé ; aucune écriture Flash effectuée."
else
    info "Flash terminé ; cible réinitialisée et lancée."
fi
