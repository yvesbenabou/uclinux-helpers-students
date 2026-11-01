#!/usr/bin/env bash
#
# Shared primitives for the uClinux/Buildroot course scripts.

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
    printf '%s/outputs/stm32\n' "$work_root"
}

uclinux_qemu_output_dir() {
    local work_root=$1
    printf '%s/outputs/qemu\n' "$work_root"
}

uclinux_default_log_file() {
    local work_root=$1
    local prefix=$2
    local log_dir="$work_root/logs"

    mkdir -p "$log_dir"
    printf '%s/%s-%s.log\n' "$log_dir" "$prefix" "$(uclinux_timestamp)"
}

run_logged() {
    local logfile=$1
    local rc
    shift

    set +e
    "$@" 2>&1 | tee "$logfile"
    rc=${PIPESTATUS[0]}
    set -e
    return "$rc"
}
: "${BUILDROOT_REF:=2025.08}"
: "${EXPECTED_LINUX_VERSION:=6.1.133}"
: "${WORK_ROOT:=$(uclinux_default_root)}"
: "${QUIET:=0}"
: "${DEBUG_TRACE:=0}"
: "${C_BOLD:=}"
: "${C_GREEN:=}"
: "${C_YELLOW:=}"
: "${C_RED:=}"
: "${C_RESET:=}"

uclinux_resolve_paths() {
    WORK_ROOT="$(uclinux_realpath "$WORK_ROOT")"
    BUILDROOT_DIR="$WORK_ROOT/buildroot"
    DOWNLOAD_DIR="$WORK_ROOT/downloads"
    STM32_OUT="$(uclinux_stm32_output_dir "$WORK_ROOT")"
    QEMU_OUT="$(uclinux_qemu_output_dir "$WORK_ROOT")"
    LABS_DIR="$WORK_ROOT/labs"
    DOCS_DIR="$WORK_ROOT/documents"
    LOG_DIR="$WORK_ROOT/logs"
}

uclinux_begin_logging() {
    local prefix=${1:-validation}

    uclinux_resolve_paths
    TIMESTAMP="${TIMESTAMP:-$(uclinux_timestamp)}"
    MAIN_LOG="${MAIN_LOG:-$LOG_DIR/$prefix-$TIMESTAMP.log}"
    REPORT="${REPORT:-$LOG_DIR/report-$TIMESTAMP.txt}"

    mkdir -p "$LOG_DIR"

    if [[ "${UCLINUX_LOGGING_STARTED:-0}" -eq 0 ]]; then
        exec 3>&1
        exec > >(tee -a "$MAIN_LOG" >&3) 2>&1
        UCLINUX_LOGGING_STARTED=1
    fi

    if [[ -t 3 ]]; then
        C_BOLD=$'\033[1m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_RED=$'\033[31m'
        C_RESET=$'\033[0m'
    else
        C_BOLD=""
        C_GREEN=""
        C_YELLOW=""
        C_RED=""
        C_RESET=""
    fi

    trap on_error ERR
}

debug_trace() {
    ((DEBUG_TRACE)) || return 0
    case "$1" in
        enter) printf '[DEBUG] entrée dans %s()...\n' "$2" >&2 ;;
        exit)  printf '[DEBUG] sortie de %s() (code %s)\n' "$2" "$3" >&2 ;;
    esac
}

debug_enter() {
    debug_trace enter "$1"
}

debug_exit() {
    debug_trace exit "$1" "$2"
}

log_msg() {
    local color=$1
    local label=$2
    local stream=$3
    shift 3

    printf '%s[%s]%s %s\n' "$color" "$label" "$C_RESET" "$*" >&"$stream"
}

log_helper() {
    local __fn=$1
    local rc=$2
    local color=$3
    local label=$4
    local stream=$5
    shift 5

    debug_enter "$__fn"
    log_msg "$color" "$label" "$stream" "$@"
    debug_exit "$__fn" "$rc"
    return 0
}

info() { log_helper "${FUNCNAME[0]}" 0 "$C_BOLD" INFO 1 "$@"; }
ok()   { log_helper "${FUNCNAME[0]}" 0 "$C_GREEN" " OK " 1 "$@"; }
warn() { log_helper "${FUNCNAME[0]}" 0 "$C_YELLOW" WARN 2 "$@"; }

die() {
    log_helper "${FUNCNAME[0]}" 1 "$C_RED" FAIL 2 "$@"
    exit 1
}

on_error() {
    local rc=$?
    local __fn="${FUNCNAME[0]}"

    debug_enter "$__fn"
    log_msg "$C_RED" FAIL 2 "erreur ligne ${BASH_LINENO[0]:-?}, commande : ${BASH_COMMAND:-?} (code $rc)"
    printf 'Journal : %s\n' "$MAIN_LOG" >&2
    debug_exit "$__fn" "$rc"
    exit "$rc"
}

check_file_nonempty() {
    local __fn="${FUNCNAME[0]}"
    local path=$1

    debug_enter "$__fn"
    [[ -s "$path" ]] || die "fichier attendu absent ou vide : $path"
    ok "présent : $path"
    debug_exit "$__fn" 0
}

run_with_log() {
    local __fn="${FUNCNAME[0]}"
    local logfile=$1
    local rc

    debug_enter "$__fn"
    shift
    info "Exécution : $*"

    if ((QUIET)); then
        if "$@" >"$logfile" 2>&1; then
            rc=0
        else
            rc=$?
        fi
    else
        if run_logged "$logfile" "$@"; then
            rc=0
        else
            rc=$?
        fi
    fi

    if ((rc != 0)); then
        debug_exit "$__fn" "$rc"
        die "commande en échec (code $rc), voir $logfile"
    fi

    ((QUIET)) && ok "journal : $logfile"
    debug_exit "$__fn" 0
}

make_br() {
    local __fn="${FUNCNAME[0]}"
    local out=$1
    local rc
    local -a external_args=()

    debug_enter "$__fn"
    shift
    if [[ "${UCLINUX_BR2_EXTERNAL_SET:-0}" == 1 ]]; then
        external_args+=("BR2_EXTERNAL=${BR2_EXTERNAL-}")
    fi
    make -C "$BUILDROOT_DIR" O="$out" BR2_DL_DIR="$DOWNLOAD_DIR" \
        "${external_args[@]}" "$@"
    rc=$?
    debug_exit "$__fn" "$rc"
    return "$rc"
}

br_config_value() {
    local __fn="${FUNCNAME[0]}"
    local config=$1
    local key=$2
    local value

    debug_enter "$__fn"
    value="$(sed -n "s/^${key}=//p" "$config" | head -n1)"
    value="${value%\"}"
    value="${value#\"}"
    printf '%s\n' "$value"
    debug_exit "$__fn" 0
}

section() {
    local __fn="${FUNCNAME[0]}"

    debug_enter "$__fn"
    printf '\n%s================================================================%s\n' "$C_BOLD" "$C_RESET"
    printf '%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"
    printf '%s================================================================%s\n' "$C_BOLD" "$C_RESET"
    debug_exit "$__fn" 0
}

uclinux_ensure_workspace_dirs() {
    mkdir -p "$DOWNLOAD_DIR" "$STM32_OUT" "$QEMU_OUT" "$LABS_DIR" "$DOCS_DIR"
}

uclinux_require_buildroot() {
    local current_ref
    local current_commit

    [[ -d "$BUILDROOT_DIR/.git" ]] \
        || die "Buildroot est absent : exécutez d'abord $SCRIPT_DIR/2_buildroot_download_and_configure.sh"

    current_ref="$(git -C "$BUILDROOT_DIR" describe --tags --exact-match 2>/dev/null || true)"
    if [[ "$current_ref" != "$BUILDROOT_REF" ]]; then
        current_commit="$(git -C "$BUILDROOT_DIR" rev-parse --short HEAD)"
        die "le dépôt Buildroot n'est pas exactement sur $BUILDROOT_REF (référence détectée : ${current_ref:-$current_commit})."
    fi
}

# Each target output belongs to the last helpers branch prepared here.
# A branch change discards generated target files, not the toolchain/cache.
uclinux_prepare_buildroot() {
    local target=$1
    local out branch marker
    local -a clean_packages=(linux-dirclean busybox-dirclean)

    case "$target" in
        stm32) out="$STM32_OUT" ;;
        qemu) out="$QEMU_OUT" ;;
        *) die "cible inconnue : $target" ;;
    esac
    uclinux_require_buildroot
    branch="$(git -C "$SCRIPT_DIR" symbolic-ref --quiet --short HEAD \
        || git -C "$SCRIPT_DIR" rev-parse HEAD)"
    marker="$out/.helpers-branch"
    if [[ -s "$out/.config" && -s "$marker" && "$(<"$marker")" == "$branch" ]]; then
        ok "configuration $target conservée pour la branche $branch"
        return 0
    fi

    # Never reset generated directories through a user-supplied symlink.
    [[ ! -L "$out" && ! -L "$out/build" && ! -L "$out/target" \
        && ! -L "$out/images" && ! -L "$out/build/buildroot-fs" \
        && ! -L "$marker" ]] || die "sortie $target : lien symbolique incompatible avec le reset"
    info "préparation $target pour $branch : reset Linux, BusyBox, target/ et images/"
    mkdir -p "$out"
    rm -f -- "$marker"
    # Do not inherit an external tree belonging to the previous branch.
    BR2_EXTERNAL="${BR2_EXTERNAL-}" "uclinux_generate_${target}_config"
    if grep -Fqx 'BR2_TARGET_UBOOT=y' "$out/.config"; then
        clean_packages+=(uboot-dirclean)
    fi
    run_with_log "$LOG_DIR/reset-$target-$TIMESTAMP.log" \
        make_br "$out" "${clean_packages[@]}"

    # Removing target/ alone leaves Buildroot believing packages are installed.
    # Reconfigure target packages to refresh their file-accounting snapshots,
    # then reinstall. Keep host-package stamps and all other package sources.
    find "$out/build" -mindepth 2 -maxdepth 2 -type f \
        ! -path "$out/build/host-*/*" \
        \( -name .stamp_configured -o -name .stamp_target_installed \
            -o -name .stamp_images_installed \) -delete
    rm -rf -- "$out/target" "$out/images" "$out/build/buildroot-fs"

    # Preparation is complete. A failed compilation can now resume incrementally.
    printf '%s\n' "$branch" >"$marker"
}

uclinux_enable_host_environment_setup() {
    local out=$1
    local config="$out/.config"
    local config_tool="$BUILDROOT_DIR/utils/config"
    local target

    target="$(basename "$out")"
    check_file_nonempty "$config"

    if grep -qx 'BR2_PACKAGE_HOST_ENVIRONMENT_SETUP=y' "$config"; then
        ok "environment-setup hôte activé pour $target"
        return 0
    fi

    check_file_nonempty "$config_tool"
    info "Activation de l'environnement de cross-compilation pour $target"
    run_with_log "$LOG_DIR/environment-setup-$target-$TIMESTAMP.log" \
        "$config_tool" --file "$config" --enable BR2_PACKAGE_HOST_ENVIRONMENT_SETUP
    run_with_log "$LOG_DIR/olddefconfig-$target-$TIMESTAMP.log" \
        make_br "$out" olddefconfig
    grep -qx 'BR2_PACKAGE_HOST_ENVIRONMENT_SETUP=y' "$config" \
        || die "impossible d'activer BR2_PACKAGE_HOST_ENVIRONMENT_SETUP pour $target"
    ok "environment-setup hôte activé pour $target"
}

uclinux_generate_stm32_config() {
    run_with_log "$LOG_DIR/defconfig-stm32-$TIMESTAMP.log" make_br "$STM32_OUT" stm32f429_disco_xip_defconfig
    check_file_nonempty "$STM32_OUT/.config"
    grep -Fqx 'BR2_cortex_m4=y' "$STM32_OUT/.config"
    grep -Fqx "BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE=\"$EXPECTED_LINUX_VERSION\"" "$STM32_OUT/.config"
    uclinux_enable_host_environment_setup "$STM32_OUT"
    ok "configuration active STM32 générée dans $STM32_OUT/.config"
}

uclinux_generate_qemu_config() {
    # Génère la configuration .config depuis qemu_arm_vexpress_defconfig + additions par dépendances de Kconfig
    # la toolchain à venir est préconfigurée par BR2_arm=y BR2_cortex_a9=y BR2_ARM_ENABLE_NEON=y BR2_ARM_ENABLE_VFP=y, 
    # complétée par Kconfig en  BR2_ARCH="arm" BR2_ARM_CPU_ARMV7A=y BR2_cortex_a9=y BR2_ARM_EABIHF=y BR2_TOOLCHAIN_BUILDROOT=y BR2_TOOLCHAIN_BUILDROOT_GLIBC=y BR2_GCC_VERSION="14.3.0" BR2_BINUTILS_VERSION="2.43.1"

    run_with_log "$LOG_DIR/defconfig-qemu-$TIMESTAMP.log" make_br "$QEMU_OUT" qemu_arm_vexpress_defconfig
    check_file_nonempty "$QEMU_OUT/.config"
    grep -Fqx 'BR2_cortex_a9=y' "$QEMU_OUT/.config"
    uclinux_enable_host_environment_setup "$QEMU_OUT"
    ok "configuration active QEMU générée dans $QEMU_OUT/.config"
}
