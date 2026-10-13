#!/usr/bin/env bash
#
# Transparent build/staging helper for the embedded Linux driver course.
# It automates Buildroot paths and image assembly, while keeping Kconfig,
# Kbuild, module loading, runtime observation, and diagnosis student-visible.

set -Eeuo pipefail
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=uclinux_common.sh
source "$SCRIPT_DIR/uclinux_common.sh"

readonly DRIVER_HELPERS_API=1

COMMAND=""
PROFILE=""
PROJECT_DIR="${UCLINUX_DRIVERS_PROJECT:-$SCRIPT_DIR/../linux-drivers-labs}"
MODE=""
TARGET_OVERRIDE=""
DRY_RUN=0
VERIFY_FLASH=0

TARGET=""
OUT=""
SYMBOL=""
MODULE_NAME=""
PROJECT_FRAGMENT=""
PROJECT_DTS=""
DEFAULT_MODE=""
LINUX_DIR=""
MANAGED_DIR=""
ACTIVE_KERNEL_FRAGMENT=""
ACTIVE_BUSYBOX_FRAGMENT=""
ACTIVE_DTS=""
ACTIVE_POST_BUILD=""
APPLIED_CONFIG_STATE=""

usage() {
    cat <<'USAGE'
Prépare, construit et inspecte les drivers du cours sans masquer les étapes
Kconfig, Kbuild, chargement, observation ou diagnostic.

Utilisation :
  ./driver.sh prepare PROFIL [options]
  ./driver.sh build PROFIL [options]
  ./driver.sh paths PROFIL [options]
  ./driver.sh show-config PROFIL [options]
  ./driver.sh show-dtb PROFIL [options]
  ./driver.sh flash PROFIL [options]
  ./driver.sh console [--device CHEMIN]

Profils :
  kmod-hello   Driver minimal pour QEMU ou STM32
  evtbuf       Character driver événementiel pour QEMU ou STM32
  stm32gpio    Platform driver GPIO synchrone sur STM32
  stm32evt     Platform driver GPIO/IRQ sur STM32
  fb0          Image STM32 de référence, sans source étudiante

Options :
  --project CHEMIN   Dépôt linux-drivers-labs
  --root CHEMIN      Racine uClinux, défaut : $UCLINUX_ROOT ou $HOME/uclinux
  --target CIBLE     qemu ou stm32 ; obligatoire pour toute commande de profil
  --mode MODE        module ou builtin ; obligatoire pour prepare et build
  --jobs N           Compilations parallèles
  --dry-run          Montrer le plan exact sans modifier ni construire
  --verify           Vérifier les images après flash
  --quiet            Réduire la sortie des commandes longues
  --debug            Tracer les fonctions des helpers
  -h, --help         Afficher cette aide

Le wrapper ne charge pas les modules et ne lance pas les tests à la place de
l'étudiant. Après le build, utiliser explicitement modinfo, insmod/modprobe,
dmesg, sysfs, /proc/interrupts, strace et les programmes de test du dépôt.
USAGE
}

shell_join() {
    local rendered
    printf -v rendered '%q ' "$@"
    printf '%s\n' "${rendered% }"
}

show_command() {
    printf '  '
    shell_join "$@"
}

require_no_spaces() {
    [[ "$1" != *" "* ]] || die "les chemins contenant des espaces ne sont pas supportés par les listes de fragments Buildroot : $1"
}

resolve_profile() {
    case "$PROFILE" in
        kmod-hello)
            SYMBOL=KMOD_HELLO
            MODULE_NAME=kmod_hello
            PROJECT_FRAGMENT=config/kmod_hello.fragment
            DEFAULT_MODE=module
            ;;
        evtbuf)
            SYMBOL=EVTBUF
            MODULE_NAME=evtbuf
            PROJECT_FRAGMENT=config/evtbuf.fragment
            DEFAULT_MODE=module
            ;;
        stm32gpio)
            SYMBOL=STM32GPIO
            MODULE_NAME=stm32gpio
            PROJECT_FRAGMENT=config/stm32gpio.fragment
            PROJECT_DTS=dts/stm32gpio.dtsi
            DEFAULT_MODE=builtin
            ;;
        stm32evt)
            SYMBOL=STM32EVT
            MODULE_NAME=stm32evt
            PROJECT_FRAGMENT=config/stm32evt.fragment
            PROJECT_DTS=dts/stm32evt.dtsi
            DEFAULT_MODE=builtin
            ;;
        fb0)
            SYMBOL=FB_STM32F429_DISCO_SIMPLE
            MODULE_NAME=""
            PROJECT_FRAGMENT=config/fb0.fragment
            DEFAULT_MODE=builtin
            ;;
        *)
            die "profil inconnu : ${PROFILE:-<absent>}"
            ;;
    esac

    [[ -n "$TARGET_OVERRIDE" ]] \
        || die "--target qemu|stm32 est obligatoire ; la cible ne doit pas être implicite"
    TARGET=$TARGET_OVERRIDE
    case "$TARGET" in
        qemu|stm32) ;;
        *) die "--target attend qemu ou stm32" ;;
    esac
    case "$PROFILE:$TARGET" in
        kmod-hello:qemu|kmod-hello:stm32|evtbuf:qemu|evtbuf:stm32|stm32gpio:stm32|stm32evt:stm32|fb0:stm32)
            ;;
        *)
            die "le profil $PROFILE ne prend pas en charge la cible $TARGET"
            ;;
    esac

    if [[ "$COMMAND" == prepare || "$COMMAND" == build ]]; then
        [[ -n "$MODE" ]] \
            || die "--mode module|builtin est obligatoire pour $COMMAND ; le type de liaison ne doit pas être implicite"
    fi
    MODE=${MODE:-$DEFAULT_MODE}
    case "$MODE" in
        module|builtin) ;;
        *) die "--mode attend module ou builtin" ;;
    esac
    if [[ "$PROFILE" == fb0 && "$MODE" != builtin ]]; then
        die "fb0 est une capacité intégrée de la plateforme ; utilisez --mode builtin"
    fi

    if [[ "$TARGET" == qemu ]]; then
        OUT="$QEMU_OUT"
    else
        OUT="$STM32_OUT"
    fi

    MANAGED_DIR="$STATE_DIR/driver-lab/$TARGET"
    ACTIVE_KERNEL_FRAGMENT="$MANAGED_DIR/linux-$PROFILE.fragment"
    ACTIVE_BUSYBOX_FRAGMENT="$MANAGED_DIR/busybox-modules.fragment"
    ACTIVE_DTS="$MANAGED_DIR/stm32f429-disco-$PROFILE.dts"
    ACTIVE_POST_BUILD="$MANAGED_DIR/stm32-$PROFILE-post-build.sh"
    APPLIED_CONFIG_STATE="$MANAGED_DIR/applied-linux-config.sha256"
}

validate_project() {
    local api

    [[ "$PROFILE" == fb0 ]] && return 0
    [[ -d "$PROJECT_DIR/.git" ]] || die "dépôt étudiant absent : $PROJECT_DIR"
    check_file_nonempty "$PROJECT_DIR/course.lock"
    api="$(sed -n 's/^UCLINUX_HELPERS_API=//p' "$PROJECT_DIR/course.lock" | head -n1)"
    [[ "$api" == "$DRIVER_HELPERS_API" ]] \
        || die "API helpers incompatible : dépôt=$api, attendu=$DRIVER_HELPERS_API"

    check_file_nonempty "$PROJECT_DIR/kernel/Kconfig"
    check_file_nonempty "$PROJECT_DIR/kernel/Makefile"
    check_file_nonempty "$PROJECT_DIR/kernel/$MODULE_NAME.c"
    check_file_nonempty "$PROJECT_DIR/$PROJECT_FRAGMENT"
    if [[ -n "$PROJECT_DTS" ]]; then
        check_file_nonempty "$PROJECT_DIR/$PROJECT_DTS"
    fi
    if [[ "$MODE" == module ]]; then
        check_file_nonempty "$PROJECT_DIR/config/busybox-modules.fragment"
    fi
}

managed_words_without_previous() {
    local words=$1
    local word
    local result=""

    for word in $words; do
        case "$word" in
            "$STATE_DIR"/driver-lab/*) ;;
            *) result+="${result:+ }$word" ;;
        esac
    done
    printf '%s\n' "$result"
}

append_word() {
    local words=$1
    local word=$2

    if [[ -z "$words" ]]; then
        printf '%s\n' "$word"
    else
        printf '%s %s\n' "$words" "$word"
    fi
}

ensure_base_config() {
    uclinux_require_buildroot
    mkdir -p "$OUT" "$MANAGED_DIR"
    if [[ -s "$OUT/.config" ]]; then
        ok "configuration Buildroot existante : $OUT/.config"
        return 0
    fi

    if [[ "$TARGET" == qemu ]]; then
        uclinux_generate_qemu_config
    else
        uclinux_generate_stm32_config
    fi
}

write_active_kernel_fragment() {
    local source_fragment="$PROJECT_DIR/$PROJECT_FRAGMENT"

    mkdir -p "$MANAGED_DIR"
    if [[ "$PROFILE" == fb0 ]]; then
        printf 'CONFIG_FB_STM32F429_DISCO_SIMPLE=y\n' >"$ACTIVE_KERNEL_FRAGMENT"
        return 0
    fi

    sed -E "/^(# )?CONFIG_${SYMBOL}(=| is not set)/d" "$source_fragment" >"$ACTIVE_KERNEL_FRAGMENT"
    if [[ "$MODE" == module ]]; then
        {
            printf 'CONFIG_MODULES=y\n'
            printf 'CONFIG_MODULE_UNLOAD=y\n'
            printf 'CONFIG_%s=m\n' "$SYMBOL"
        } >>"$ACTIVE_KERNEL_FRAGMENT"
    else
        printf 'CONFIG_%s=y\n' "$SYMBOL" >>"$ACTIVE_KERNEL_FRAGMENT"
    fi
}

write_active_busybox_fragment() {
    if [[ "$MODE" != module ]]; then
        return 0
    fi
    cp -- "$PROJECT_DIR/config/busybox-modules.fragment" "$ACTIVE_BUSYBOX_FRAGMENT"
}

write_active_dts() {
    if [[ "$TARGET" != stm32 ]]; then
        return 0
    fi
    if [[ -z "$PROJECT_DTS" ]]; then
        ACTIVE_DTS="$SCRIPT_DIR/stm32_romfs/stm32f429-disco-romfs.dts"
        return 0
    fi

    {
        sed -n '1,$p' "$SCRIPT_DIR/stm32_romfs/stm32f429-disco-romfs.dts"
        printf '\n/* Student driver fragment: %s */\n' "$PROFILE"
        sed -n '1,$p' "$PROJECT_DIR/$PROJECT_DTS"
    } >"$ACTIVE_DTS"
}

write_active_post_build() {
    [[ "$TARGET" == stm32 ]] || return 0

    {
        printf '%s\n' '#!/bin/sh' '# Generated by uclinux-helpers/driver.sh; inspectable course infrastructure.' '' 'set -eu' ''
        printf '%s\n' 'target_dir=$1' 'rm -rf -- "$target_dir/boot" "$target_dir/lib/modules"'
        if [[ "$MODE" == module ]]; then
            printf '\nmodule_name=%s\n' "$MODULE_NAME"
            printf '%s\n' \
                'module_path=' \
                'for candidate in "$BUILD_DIR"/linux-*/drivers/misc/uclinux_course/"$module_name.ko" "$BUILD_DIR"/linux-custom/drivers/misc/uclinux_course/"$module_name.ko"; do' \
                '    test -f "$candidate" || continue' \
                '    module_path=$candidate' \
                '    break' \
                'done' \
                'test -n "$module_path" || { echo "course module not found: $module_name.ko" >&2; exit 1; }' \
                'linux_dir=$(CDPATH= cd -- "$(dirname -- "$module_path")/../../.." && pwd)' \
                'kernel_release=$(cat "$linux_dir/include/config/kernel.release")' \
                'module_dir="$target_dir/lib/modules/$kernel_release/extra"' \
                'mkdir -p -- "$module_dir"' \
                'cp -- "$module_path" "$module_dir/"' \
                '"$HOST_DIR/sbin/depmod" -a -b "$target_dir" "$kernel_release"'
        fi
    } >"$ACTIVE_POST_BUILD"
    chmod 0755 "$ACTIVE_POST_BUILD"
}

configure_buildroot() {
    local config="$OUT/.config"
    local config_tool="$BUILDROOT_DIR/utils/config"
    local kernel_fragments
    local busybox_fragments
    local post_build_scripts
    local -a config_args=()

    write_active_kernel_fragment
    write_active_busybox_fragment
    write_active_dts
    write_active_post_build

    kernel_fragments="$(managed_words_without_previous "$(br_config_value "$config" BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES)")"
    kernel_fragments="$(append_word "$kernel_fragments" "$ACTIVE_KERNEL_FRAGMENT")"
    busybox_fragments="$(managed_words_without_previous "$(br_config_value "$config" BR2_PACKAGE_BUSYBOX_CONFIG_FRAGMENT_FILES)")"
    if [[ "$MODE" == module ]]; then
        busybox_fragments="$(append_word "$busybox_fragments" "$ACTIVE_BUSYBOX_FRAGMENT")"
    fi
    post_build_scripts="$(managed_words_without_previous "$(br_config_value "$config" BR2_ROOTFS_POST_BUILD_SCRIPT)")"
    if [[ "$TARGET" == stm32 ]]; then
        post_build_scripts="$(append_word "$post_build_scripts" "$ACTIVE_POST_BUILD")"
    fi

    config_args=(
        --file "$config"
        --set-str BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES "$kernel_fragments"
        --set-str BR2_PACKAGE_BUSYBOX_CONFIG_FRAGMENT_FILES "$busybox_fragments"
        --set-str BR2_ROOTFS_POST_BUILD_SCRIPT "$post_build_scripts"
    )
    if [[ "$TARGET" == qemu && "$MODE" == module ]]; then
        config_args+=(--enable BR2_LINUX_KERNEL_INSTALL_TARGET)
    else
        config_args+=(--disable BR2_LINUX_KERNEL_INSTALL_TARGET)
    fi
    if [[ "$TARGET" == stm32 ]]; then
        config_args+=(
            --set-str BR2_LINUX_KERNEL_CUSTOM_DTS_PATH "$ACTIVE_DTS"
            --set-str BR2_LINUX_KERNEL_INTREE_DTS_NAME ""
        )
    fi

    run_with_log "$LOG_DIR/driver-$PROFILE-buildroot-config-$TIMESTAMP.log" \
        "$config_tool" "${config_args[@]}"
    run_with_log "$LOG_DIR/driver-$PROFILE-olddefconfig-$TIMESTAMP.log" \
        make_br "$OUT" olddefconfig
}

find_linux_dir() {
    local version
    local candidate

    version="$(br_config_value "$OUT/.config" BR2_LINUX_KERNEL_VERSION)"
    [[ -n "$version" ]] || version="$(br_config_value "$OUT/.config" BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE)"
    for candidate in "$OUT/build/linux-custom" "$OUT/build/linux-$version"; do
        if [[ -d "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

stage_student_kernel() {
    local course_dir
    local destination
    local misc_kconfig
    local misc_makefile
    local staged_file
    local copied=0
    local unchanged=0

    [[ "$PROFILE" == fb0 ]] && return 0
    LINUX_DIR="$(find_linux_dir)" || die "arbre Linux extrait introuvable dans $OUT/build"
    course_dir="$LINUX_DIR/drivers/misc/uclinux_course"
    misc_kconfig="$LINUX_DIR/drivers/misc/Kconfig"
    misc_makefile="$LINUX_DIR/drivers/misc/Makefile"

    check_file_nonempty "$misc_kconfig"
    check_file_nonempty "$misc_makefile"
    if ! grep -Fqx 'source "drivers/misc/uclinux_course/Kconfig"' "$misc_kconfig"; then
        sed -i '/^endmenu$/i source "drivers/misc/uclinux_course/Kconfig"' "$misc_kconfig"
    fi
    if ! grep -Fqx 'obj-y += uclinux_course/' "$misc_makefile"; then
        printf '\n# Educational drivers staged by uclinux-helpers/driver.sh\nobj-y += uclinux_course/\n' >>"$misc_makefile"
    fi

    mkdir -p "$course_dir"
    while IFS= read -r -d '' staged_file; do
        destination="$course_dir/${staged_file##*/}"
        if [[ -f "$destination" ]] && cmp -s -- "$staged_file" "$destination"; then
            ((unchanged += 1))
            continue
        fi
        cp -- "$staged_file" "$destination"
        ((copied += 1))
    done < <(find "$PROJECT_DIR/kernel" -maxdepth 1 -type f -print0)

    ok "sources étudiantes staged : $copied modifiée(s), $unchanged inchangée(s)"
    info "Répertoire Kbuild préservé : $course_dir"
    info "Hook central : drivers/misc/Kconfig → drivers/misc/uclinux_course/Kconfig"
    info "Hook central : drivers/misc/Makefile → obj-y += uclinux_course/"
}

configuration_fingerprint() {
    local fragment
    local fragments

    fragments="$(br_config_value "$OUT/.config" BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES)"
    {
        printf 'target=%s\nprofile=%s\nmode=%s\nsymbol=%s\n' \
            "$TARGET" "$PROFILE" "$MODE" "$SYMBOL"
        for fragment in $fragments; do
            printf 'fragment=%s\n' "$fragment"
            if [[ -f "$fragment" ]]; then
                sha256sum -- "$fragment"
            else
                printf 'missing\n'
            fi
        done
        if [[ "$PROFILE" != fb0 ]]; then
            sha256sum -- "$PROJECT_DIR/kernel/Kconfig"
        fi
    } | sha256sum | awk '{print $1}'
}

linux_configuration_is_current() {
    local expected
    local fingerprint
    local kernel_config

    LINUX_DIR="$(find_linux_dir || true)"
    [[ -n "$LINUX_DIR" ]] || return 1
    kernel_config="$LINUX_DIR/.config"
    [[ -s "$kernel_config" && -s "$APPLIED_CONFIG_STATE" ]] || return 1

    if [[ "$MODE" == module ]]; then
        expected=m
    else
        expected=y
    fi
    grep -qx "CONFIG_${SYMBOL}=$expected" "$kernel_config" || return 1
    if [[ "$MODE" == module ]]; then
        grep -qx 'CONFIG_MODULES=y' "$kernel_config" || return 1
    fi

    fingerprint="$(configuration_fingerprint)"
    [[ "$(<"$APPLIED_CONFIG_STATE")" == "$fingerprint" ]]
}

record_linux_configuration() {
    configuration_fingerprint >"$APPLIED_CONFIG_STATE"
}

print_plan() {
    local config_value

    if [[ "$MODE" == module ]]; then
        config_value=m
    else
        config_value=y
    fi
    printf 'Profil       : %s\n' "$PROFILE"
    printf 'Cible        : %s\n' "$TARGET"
    printf 'Projet       : %s\n' "$PROJECT_DIR"
    printf 'Sortie       : %s\n' "$OUT"
    printf 'Configuration: CONFIG_%s=%s\n' "$SYMBOL" "$config_value"
    [[ -z "$MODULE_NAME" ]] || printf 'Source       : %s/kernel/%s.c\n' "$PROJECT_DIR" "$MODULE_NAME"
    printf 'Fragment     : %s\n' "$PROJECT_DIR/$PROJECT_FRAGMENT"
    [[ -z "$PROJECT_DTS" ]] || printf 'DTS fragment : %s/%s\n' "$PROJECT_DIR" "$PROJECT_DTS"
    printf '\nCommandes de construction prévues :\n'
    show_command make -C "$BUILDROOT_DIR" O="$OUT" BR2_DL_DIR="$DOWNLOAD_DIR" linux-patch
    if [[ "$COMMAND" == prepare ]]; then
        show_command make -C "$BUILDROOT_DIR" O="$OUT" BR2_DL_DIR="$DOWNLOAD_DIR" linux-reconfigure
    else
        printf '  linux-reconfigure si la configuration a changé ; sinon linux-rebuild incrémental\n'
    fi
    show_command make -C "$BUILDROOT_DIR" O="$OUT" BR2_DL_DIR="$DOWNLOAD_DIR" -j"$JOBS"
    if [[ "$MODE" == module ]]; then
        printf '\nAprès build, l’étudiant exécutera lui-même modinfo, insmod/modprobe et rmmod.\n'
    fi
    if [[ "$TARGET" == stm32 ]]; then
        printf 'Assemblage STM32 : %s\n' "$ACTIVE_POST_BUILD"
        if [[ "$MODE" == module ]]; then
            printf 'Le ROMFS reçoit uniquement %s.ko, pas tous les modules ni une copie du noyau.\n' "$MODULE_NAME"
        fi
    fi
}

prepare_profile() {
    ensure_base_config
    configure_buildroot
    run_with_log "$LOG_DIR/driver-$PROFILE-linux-patch-$TIMESTAMP.log" \
        make_br "$OUT" linux-patch
    stage_student_kernel
    info "Décision : prepare demande explicitement une reconfiguration Linux"
    run_with_log "$LOG_DIR/driver-$PROFILE-linux-reconfigure-$TIMESTAMP.log" \
        make_br "$OUT" linux-reconfigure
    record_linux_configuration
    ok "profil préparé : $PROFILE"
}

validate_build_result() {
    local kernel_config
    local module_path=""

    LINUX_DIR="$(find_linux_dir)" || die "arbre Linux construit introuvable"
    kernel_config="$LINUX_DIR/.config"
    check_file_nonempty "$kernel_config"
    if [[ "$MODE" == module ]]; then
        grep -qx "CONFIG_${SYMBOL}=m" "$kernel_config" \
            || die "CONFIG_${SYMBOL}=m absent de $kernel_config"
        module_path="$(find "$LINUX_DIR/drivers/misc/uclinux_course" -maxdepth 1 -type f -name "$MODULE_NAME.ko" -print -quit)"
        [[ -n "$module_path" ]] || die "module construit introuvable : $MODULE_NAME.ko"
        file "$module_path"
        ok "module produit : $module_path"
        if find "$OUT/target/lib/modules" -type f -name "$MODULE_NAME.ko" -print -quit 2>/dev/null | grep -q .; then
            ok "module installé dans le rootfs cible"
        else
            warn "module absent du rootfs cible ; inspectez BR2_LINUX_KERNEL_INSTALL_TARGET et le journal"
        fi
    else
        grep -qx "CONFIG_${SYMBOL}=y" "$kernel_config" \
            || die "CONFIG_${SYMBOL}=y absent de $kernel_config"
        ok "driver intégré : CONFIG_${SYMBOL}=y"
    fi
}

build_profile() {
    ensure_base_config
    configure_buildroot
    run_with_log "$LOG_DIR/driver-$PROFILE-linux-patch-$TIMESTAMP.log" \
        make_br "$OUT" linux-patch
    stage_student_kernel
    if linux_configuration_is_current; then
        info "Décision : configuration Linux inchangée → linux-rebuild incrémental"
        run_with_log "$LOG_DIR/driver-$PROFILE-linux-rebuild-$TIMESTAMP.log" \
            make_br "$OUT" linux-rebuild
    else
        info "Décision : configuration Linux nouvelle ou modifiée → linux-reconfigure"
        run_with_log "$LOG_DIR/driver-$PROFILE-linux-reconfigure-$TIMESTAMP.log" \
            make_br "$OUT" linux-reconfigure
        record_linux_configuration
    fi
    run_with_log "$LOG_DIR/driver-$PROFILE-build-$TIMESTAMP.log" \
        make_br "$OUT" -j"$JOBS"
    validate_build_result
    ok "build terminé : $PROFILE"
}

show_paths() {
    printf 'profile=%s\n' "$PROFILE"
    printf 'target=%s\n' "$TARGET"
    printf 'helpers=%s\n' "$SCRIPT_DIR"
    printf 'project=%s\n' "$PROJECT_DIR"
    printf 'work_root=%s\n' "$WORK_ROOT"
    printf 'buildroot=%s\n' "$BUILDROOT_DIR"
    printf 'output=%s\n' "$OUT"
    printf 'logs=%s\n' "$LOG_DIR"
    printf 'managed=%s\n' "$MANAGED_DIR"
    if [[ "$TARGET" == stm32 ]]; then
        printf 'post_build=%s\n' "$ACTIVE_POST_BUILD"
    fi
    if [[ -s "$OUT/.config" ]]; then
        LINUX_DIR="$(find_linux_dir || true)"
        printf 'linux=%s\n' "${LINUX_DIR:-<non extrait>}"
        if [[ -n "$LINUX_DIR" && -n "$MODULE_NAME" ]]; then
            printf 'staged_source=%s/drivers/misc/uclinux_course/%s.c\n' "$LINUX_DIR" "$MODULE_NAME"
            printf 'module=%s/drivers/misc/uclinux_course/%s.ko\n' "$LINUX_DIR" "$MODULE_NAME"
        fi
    fi
}

show_config() {
    local kernel_config

    [[ -s "$OUT/.config" ]] || die "configuration Buildroot absente : $OUT/.config"
    printf 'Buildroot fragments :\n'
    printf '  %s\n' "$(br_config_value "$OUT/.config" BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES)"
    printf 'Buildroot DTS :\n'
    printf '  %s\n' "$(br_config_value "$OUT/.config" BR2_LINUX_KERNEL_CUSTOM_DTS_PATH)"
    LINUX_DIR="$(find_linux_dir || true)"
    [[ -n "$LINUX_DIR" ]] || return 0
    kernel_config="$LINUX_DIR/.config"
    [[ -s "$kernel_config" ]] || return 0
    printf 'Configuration noyau effective :\n'
    grep -E "^(CONFIG_${SYMBOL}=|# CONFIG_${SYMBOL} is not set|CONFIG_MODULES=|# CONFIG_MODULES is not set)" "$kernel_config" || true
}

show_dtb() {
    local dtb_name
    local dtb

    [[ "$TARGET" == stm32 ]] || die "le profil $PROFILE n'utilise pas le DT STM32"
    if [[ -s "$OUT/.config" ]]; then
        dtb_name="$(uclinux_stm32_dtb_name "$OUT/.config" || true)"
        dtb="$OUT/images/${dtb_name##*/}.dtb"
        if [[ -n "$dtb_name" && -s "$dtb" ]]; then
            command -v dtc >/dev/null 2>&1 || die "dtc absent"
            exec dtc -I dtb -O dts "$dtb"
        fi
    fi
    if [[ -s "$ACTIVE_DTS" ]]; then
        exec sed -n '1,$p' "$ACTIVE_DTS"
    fi
    die "aucun DTB construit ni DTS généré pour $PROFILE"
}

flash_profile() {
    local -a args=(flash --root "$WORK_ROOT" --output "$STM32_OUT")

    [[ "$TARGET" == stm32 ]] || die "flash est réservé aux profils STM32"
    ((VERIFY_FLASH)) && args+=(--verify)
    exec "$SCRIPT_DIR/run_openocd_stm32.sh" "${args[@]}"
}

COMMAND=${1:-}
case "$COMMAND" in
    prepare|build|paths|show-config|show-dtb|flash)
        [[ $# -ge 2 ]] || { usage >&2; exit 2; }
        PROFILE=$2
        shift 2
        ;;
    console)
        shift
        ;;
    -h|--help|"")
        usage
        exit 0
        ;;
    *)
        echo "ERREUR : commande inconnue : $COMMAND" >&2
        usage >&2
        exit 2
        ;;
esac

CONSOLE_ARGS=()
while (($#)); do
    case "$1" in
        --project)
            [[ $# -ge 2 ]] || die "--project attend un chemin"
            PROJECT_DIR=$2
            shift 2
            ;;
        --root)
            [[ $# -ge 2 ]] || die "--root attend un chemin"
            WORK_ROOT=$2
            shift 2
            ;;
        --mode)
            [[ $# -ge 2 ]] || die "--mode attend module ou builtin"
            MODE=$2
            shift 2
            ;;
        --target)
            [[ $# -ge 2 ]] || die "--target attend qemu ou stm32"
            TARGET_OVERRIDE=$2
            shift 2
            ;;
        --jobs)
            [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || die "--jobs attend un entier strictement positif"
            JOBS=$2
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --verify)
            VERIFY_FLASH=1
            shift
            ;;
        --quiet)
            QUIET=1
            shift
            ;;
        --debug)
            DEBUG_TRACE=1
            shift
            ;;
        --device)
            [[ "$COMMAND" == console && $# -ge 2 ]] || die "--device s'utilise avec console et attend un chemin"
            CONSOLE_ARGS+=(--device "$2")
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "option inconnue : $1" ;;
    esac
done

if [[ "$COMMAND" == console ]]; then
    exec "$SCRIPT_DIR/connect_stm32_console.sh" "${CONSOLE_ARGS[@]}"
fi

WORK_ROOT="$(uclinux_realpath "$WORK_ROOT")"
PROJECT_DIR="$(uclinux_realpath "$PROJECT_DIR")"
require_no_spaces "$SCRIPT_DIR"
require_no_spaces "$WORK_ROOT"
require_no_spaces "$PROJECT_DIR"
uclinux_resolve_paths
resolve_profile

case "$COMMAND" in
    paths)
        show_paths
        ;;
    show-config)
        show_config
        ;;
    show-dtb)
        show_dtb
        ;;
    flash)
        flash_profile
        ;;
    prepare|build)
        if ((DRY_RUN)); then
            print_plan
            exit 0
        fi
        uclinux_begin_logging "driver-$PROFILE-$COMMAND"
        resolve_profile
        validate_project
        print_plan
        if [[ "$COMMAND" == prepare ]]; then
            prepare_profile
        else
            build_profile
        fi
        ;;
esac
