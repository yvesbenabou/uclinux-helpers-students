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
RESET_ENV=0
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
  --reset-env         Effacer volontairement l'environnement U-Boot persistant
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
        --reset-env)
            RESET_ENV=1
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
if ((RESET_ENV)) && [[ "$MODE" != "flash" ]]; then
    die "--reset-env s'utilise uniquement avec le mode flash"
fi

WORK_ROOT="$(uclinux_realpath "$WORK_ROOT")"
STM32_OUT="${STM32_OUT:-$(uclinux_stm32_output_dir "$WORK_ROOT")}"
STM32_OUT="$(uclinux_realpath "$STM32_OUT")"
IMAGES_DIR="$STM32_OUT/images"

OPENOCD="$STM32_OUT/host/bin/openocd"
OPENOCD_SCRIPTS="$STM32_OUT/host/share/openocd/scripts"
UDEV_RULES="$STM32_OUT/host/share/openocd/contrib/60-openocd.rules"

BR_CONFIG="$STM32_OUT/.config"
UBOOT_IMAGE=""
UBOOT_BUILD_DIR=""
UBOOT_CONFIG=""
DTB=""
DTB_ADDR=""
UIMAGE=""

check_file_nonempty "$OPENOCD"
check_dir "$OPENOCD_SCRIPTS"
if [[ "$MODE" == "flash" ]]; then
    check_file_nonempty "$BR_CONFIG"

    uclinux_stm32_uboot_configured "$BR_CONFIG" \
        || die "la configuration active ne sélectionne pas le U-Boot Buildroot attendu."
    UBOOT_IMAGE="$IMAGES_DIR/u-boot.bin"
    UIMAGE="$IMAGES_DIR/uImage"
    DTB_NAME="$(uclinux_stm32_dtb_name "$BR_CONFIG")" \
        || die "nom du DTB STM32 introuvable dans la configuration Buildroot"
    [[ "$DTB_NAME" != *" "* ]] || die "plusieurs DTB configurés ; utilisez --output avec une configuration STM32 dédiée"
    DTB="$IMAGES_DIR/${DTB_NAME##*/}.dtb"

    check_file_nonempty "$UBOOT_IMAGE"
    check_file_nonempty "$DTB"
    check_file_nonempty "$UIMAGE"

    UBOOT_BUILD_DIR="$(find_unique_glob "$STM32_OUT/build/uboot-*" "répertoire de build U-Boot")"
    UBOOT_CONFIG="$UBOOT_BUILD_DIR/.config"
    check_file_nonempty "$UBOOT_CONFIG"
    [[ "$(config_value "$UBOOT_CONFIG" CONFIG_ENV_ADDR)" == "$STM32_UBOOT_ENV_ADDR" ]] \
        || die "adresse de l'environnement U-Boot incohérente."
    [[ "$(config_value "$UBOOT_CONFIG" CONFIG_ENV_SECT_SIZE)" == 0x20000 ]] \
        || die "taille du secteur d'environnement U-Boot incohérente."

    LINUX_CONFIG="$(find_linux_config "$BR_CONFIG")"
    [[ "$(normalize_address "$(require_config_value "$LINUX_CONFIG" CONFIG_XIP_PHYS_ADDR)")" == "$STM32_XIP_ADDR" ]] \
        || die "adresse XIP Linux incohérente."
    DTB_ADDR="$(normalize_address "$STM32_DTB_ADDR")"

    check_image_before U-Boot "$UBOOT_IMAGE" "$STM32_UBOOT_ADDR" environnement "$STM32_UBOOT_ENV_ADDR"
    check_image_before uImage "$UIMAGE" "$STM32_UIMAGE_ADDR" DTB "$DTB_ADDR"
    check_image_before DTB "$DTB" "$DTB_ADDR" "fin de la Flash" "$STM32_FLASH_END"
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
        -c "flash erase_sector 0 0 4"
    )

    if ((RESET_ENV)); then
        OPENOCD_CMD+=( -c "flash erase_sector 0 5 5" )
    fi

    # Erase the image area once, then write all images without per-file erase.
    # This remains correct when two images share a physical erase sector.
    OPENOCD_CMD+=(
        -c "flash erase_sector 0 6 23"
        -c "flash write_image $UBOOT_IMAGE $STM32_UBOOT_ADDR bin"
        -c "flash write_image $UIMAGE $STM32_UIMAGE_ADDR bin"
        -c "flash write_image $DTB $DTB_ADDR bin"
    )

    if ((VERIFY)); then
        OPENOCD_CMD+=(
            -c "verify_image $UBOOT_IMAGE $STM32_UBOOT_ADDR bin"
            -c "verify_image $UIMAGE $STM32_UIMAGE_ADDR bin"
            -c "verify_image $DTB $DTB_ADDR bin"
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
    info "Plan Flash : U-Boot=$STM32_UBOOT_ADDR, env=$STM32_UBOOT_ENV_ADDR (préservé=$((1 - RESET_ENV))), uImage=$STM32_UIMAGE_ADDR, DTB=$DTB_ADDR"
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
