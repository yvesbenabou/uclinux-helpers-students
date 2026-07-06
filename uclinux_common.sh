#!/usr/bin/env bash
#
# Shared helpers for the uClinux/Buildroot course scripts.

uclinux_default_root() {
    printf '%s\n' "${UCLINUX_ROOT:-$HOME/uclinux}"
}

uclinux_realpath() {
    readlink -m "$1"
}

uclinux_timestamp() {
    date +%Y%m%d-%H%M%S
}

uclinux_stm32_output_dir() {
    local work_root=$1
    printf '%s/outputs/stm32f429\n' "$work_root"
}

uclinux_qemu_output_dir() {
    local work_root=$1
    printf '%s/outputs/qemu-vexpress\n' "$work_root"
}

uclinux_openocd_scripts_dir() {
    local stm32_out=$1
    printf '%s/host/share/openocd/scripts\n' "$stm32_out"
}

uclinux_openocd_udev_rules() {
    local stm32_out=$1
    printf '%s/host/share/openocd/contrib/60-openocd.rules\n' "$stm32_out"
}

uclinux_info() {
    printf '[INFO] %s\n' "$*"
}

uclinux_warn() {
    printf '[WARN] %s\n' "$*" >&2
}

uclinux_die() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

uclinux_check_file_nonempty() {
    local path=$1
    [[ -s "$path" ]] || uclinux_die "fichier absent ou vide : $path"
}

uclinux_check_dir() {
    local path=$1
    [[ -d "$path" ]] || uclinux_die "répertoire absent : $path"
}

uclinux_default_log_file() {
    local work_root=$1
    local prefix=$2
    local log_dir="$work_root/logs"

    mkdir -p "$log_dir"
    printf '%s/%s-%s.log\n' "$log_dir" "$prefix" "$(uclinux_timestamp)"
}

uclinux_quote_command() {
    local quoted
    printf -v quoted '%q ' "$@"
    printf '%s' "$quoted"
}

uclinux_run_logged() {
    local logfile=$1
    local rc
    shift

    set +e
    "$@" 2>&1 | tee "$logfile"
    rc=${PIPESTATUS[0]}
    set -e
    return "$rc"
}

uclinux_run_logged_pty_if_available() {
    local logfile=$1
    local rc
    local script_cmd
    shift

    set +e
    if command -v script >/dev/null 2>&1; then
        script_cmd="$(uclinux_quote_command "$@")"
        script -qefc "$script_cmd" /dev/null 2>&1 | tee "$logfile"
        rc=${PIPESTATUS[0]}
    else
        "$@" 2>&1 | tee "$logfile"
        rc=${PIPESTATUS[0]}
    fi
    set -e
    return "$rc"
}

uclinux_create_minicom_acm0_profile() {
    local profile=${1:-"$HOME/.minirc.acm0"}

    cat > "$profile" <<'MINICOMEOF'
# Généré par les scripts du cours uClinux.
# Utilisation : minicom acm0
pu port             /dev/ttyACM0
pu baudrate         115200
pu bits             8
pu parity           N
pu stopbits         1
pu rtscts           No
pu xonxoff          No
MINICOMEOF
    chmod 0644 "$profile"
    printf '%s\n' "$profile"
}

uclinux_stlink_permission_help() {
    local rules=$1
    local user=${2:-${USER:-${LOGNAME:-utilisateur}}}

    uclinux_warn "OpenOCD voit le ST-LINK mais libusb n'a pas le droit de l'ouvrir."
    if [[ -f "$rules" ]]; then
        uclinux_warn "Installez les règles udev OpenOCD standard puis débranchez/rebranchez le ST-LINK :"
        printf '  sudo install -m 0644 %q /etc/udev/rules.d/60-openocd.rules\n' "$rules" >&2
        printf '  sudo udevadm control --reload-rules\n' >&2
        printf '  sudo udevadm trigger --subsystem-match=usb\n' >&2
        printf '  sudo usermod -aG plugdev %q   # puis nouvelle session si nécessaire\n' "$user" >&2
    else
        uclinux_warn "règles udev OpenOCD introuvables : $rules"
        uclinux_warn "Installez les règles udev OpenOCD du paquet/distribution, puis reconnectez le ST-LINK."
    fi
}
