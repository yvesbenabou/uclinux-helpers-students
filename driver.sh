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

TARGET=""
OUT=""
SYMBOL=""
MODULE_NAME=""
PROJECT_FRAGMENT=""
PROJECT_DTS=""
LINUX_DIR=""
MANAGED_DIR=""
ACTIVE_KERNEL_FRAGMENT=""
ACTIVE_BUSYBOX_FRAGMENT=""
ACTIVE_DTS=""
ACTIVE_POST_BUILD=""
APPLIED_CONFIG_STATE=""
ACTIVE_SELECTION_STATE=""
readonly -a COURSE_MODULES=(kmod_hello evtbuf stm32gpio stm32evt)

usage() {
    cat <<'USAGE'
Construit et inspecte les drivers du cours sans masquer les étapes
Kconfig, Kbuild, chargement, observation ou diagnostic.

Utilisation :
  ./driver.sh build PROFIL [options]
  ./driver.sh paths PROFIL [options]
  ./driver.sh show-config PROFIL [options]
  ./driver.sh show-dtb PROFIL [options]

Profils :
  kmod-hello   Driver minimal pour QEMU ou STM32
  evtbuf       Character driver événementiel pour QEMU ou STM32
  stm32gpio    Platform driver GPIO synchrone sur STM32
  stm32evt     Platform driver GPIO/IRQ sur STM32

Options :
  --project CHEMIN   Dépôt linux-drivers-labs
  --root CHEMIN      Racine uClinux, défaut : $UCLINUX_ROOT ou $HOME/uclinux
  --target CIBLE     qemu ou stm32 ; obligatoire pour toute commande de profil
  --mode MODE        module ou builtin ; obligatoire pour build
  --dry-run          Montrer le plan exact sans modifier ni construire
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
            ;;
        evtbuf)
            SYMBOL=EVTBUF
            MODULE_NAME=evtbuf
            PROJECT_FRAGMENT=config/evtbuf.fragment
            ;;
        stm32gpio)
            SYMBOL=STM32GPIO
            MODULE_NAME=stm32gpio
            PROJECT_FRAGMENT=config/stm32gpio.fragment
            PROJECT_DTS=dts/stm32gpio.dtsi
            ;;
        stm32evt)
            SYMBOL=STM32EVT
            MODULE_NAME=stm32evt
            PROJECT_FRAGMENT=config/stm32evt.fragment
            PROJECT_DTS=dts/stm32evt.dtsi
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
        kmod-hello:qemu|kmod-hello:stm32|evtbuf:qemu|evtbuf:stm32|stm32gpio:stm32|stm32evt:stm32)
            ;;
        *)
            die "le profil $PROFILE ne prend pas en charge la cible $TARGET"
            ;;
    esac

    if [[ "$COMMAND" == build ]]; then
        [[ -n "$MODE" ]] \
            || die "--mode module|builtin est obligatoire pour build ; le type de liaison ne doit pas être implicite"
    elif [[ -n "$MODE" ]]; then
        die "--mode s'applique uniquement à build"
    fi
    if [[ -n "$MODE" ]]; then
        case "$MODE" in
            module|builtin) ;;
            *) die "--mode attend module ou builtin" ;;
        esac
    fi

    if [[ "$TARGET" == qemu ]]; then
        OUT="$QEMU_OUT"
    else
        OUT="$STM32_OUT"
    fi

    MANAGED_DIR="$STATE_DIR/driver-lab/$TARGET"
    ACTIVE_KERNEL_FRAGMENT="$MANAGED_DIR/linux-current.fragment"
    ACTIVE_BUSYBOX_FRAGMENT="$MANAGED_DIR/busybox-modules.fragment"
    ACTIVE_DTS="$MANAGED_DIR/stm32f429-disco-current.dts"
    ACTIVE_POST_BUILD="$MANAGED_DIR/stm32-current-post-build.sh"
    APPLIED_CONFIG_STATE="$MANAGED_DIR/applied-linux-config.sha256"
    ACTIVE_SELECTION_STATE="$MANAGED_DIR/current-selection"
}

validate_project() {
    local api

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
    uclinux_prepare_buildroot "$TARGET"
    mkdir -p "$MANAGED_DIR"
}

write_active_kernel_fragment() {
    local source_fragment="$PROJECT_DIR/$PROJECT_FRAGMENT"

    mkdir -p "$MANAGED_DIR"
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
        printf '%s\n' \
            'target_dir=$1' \
            'rm -rf -- "$target_dir/boot"' \
            'if test -d "$target_dir/lib/modules"; then'
        printf '    for course_module in %s; do\n' "${COURSE_MODULES[*]}"
        printf '%s\n' \
            '        find "$target_dir/lib/modules" -type f -name "$course_module.ko" -delete' \
            '    done' \
            'fi'
        if [[ "$MODE" == module ]]; then
            printf '\nmodule_name=%s\n' "$MODULE_NAME"
            printf '%s\n' \
                'module_path=' \
                'for candidate in "$BUILD_DIR"/linux-*/drivers/misc/uclinux_course/"$module_name.ko"; do' \
                '    test -f "$candidate" || continue' \
                '    module_path=$candidate' \
                '    break' \
                'done' \
                'test -n "$module_path" || { echo "course module not found: $module_name.ko" >&2; exit 1; }' \
                'linux_dir=$(CDPATH= cd -- "$(dirname -- "$module_path")/../../.." && pwd)' \
                'kernel_release=$(cat "$linux_dir/include/config/kernel.release")' \
                'module_dir="$target_dir/lib/modules/$kernel_release/extra"' \
                'mkdir -p -- "$module_dir"' \
                'cp -- "$module_path" "$module_dir/"'
        fi
        printf '%s\n' \
            'for release_dir in "$target_dir"/lib/modules/*; do' \
            '    test -d "$release_dir" || continue' \
            '    "$HOST_DIR/sbin/depmod" -a -b "$target_dir" "${release_dir##*/}"' \
            'done'
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
    printf 'target=%s\nprofile=%s\nmode=%s\n' "$TARGET" "$PROFILE" "$MODE" >"$ACTIVE_SELECTION_STATE"
}

find_linux_dir() {
    local version
    local candidate

    version="$(br_config_value "$OUT/.config" BR2_LINUX_KERNEL_VERSION)"
    [[ -n "$version" ]] || version="$(br_config_value "$OUT/.config" BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE)"
    candidate="$OUT/build/linux-$version"
    [[ -d "$candidate" ]] || return 1
    printf '%s\n' "$candidate"
}

stage_student_kernel() {
    local course_dir
    local misc_kconfig
    local misc_makefile
    local staged_file
    local copied=0

    LINUX_DIR="$(find_linux_dir)" || die "arbre Linux extrait introuvable dans $OUT/build"
    course_dir="$LINUX_DIR/drivers/misc/uclinux_course"
    misc_kconfig="$LINUX_DIR/drivers/misc/Kconfig"
    misc_makefile="$LINUX_DIR/drivers/misc/Makefile"

    case "$LINUX_DIR" in
        "$OUT"/build/linux-*) ;;
        *) die "arbre Linux hors de la sortie Buildroot attendue : $LINUX_DIR" ;;
    esac

    check_file_nonempty "$misc_kconfig"
    check_file_nonempty "$misc_makefile"
    if ! grep -Fqx 'source "drivers/misc/uclinux_course/Kconfig"' "$misc_kconfig"; then
        sed -i '/^endmenu$/i source "drivers/misc/uclinux_course/Kconfig"' "$misc_kconfig"
    fi
    if ! grep -Fqx 'obj-y += uclinux_course/' "$misc_makefile"; then
        printf '\n# Educational drivers staged by uclinux-helpers/driver.sh\nobj-y += uclinux_course/\n' >>"$misc_makefile"
    fi

    [[ ! -L "$course_dir" ]] || die "le répertoire de cours ne doit pas être un lien symbolique : $course_dir"
    rm -rf -- "$course_dir"
    mkdir -p "$course_dir"
    while IFS= read -r -d '' staged_file; do
        cp -- "$staged_file" "$course_dir/"
        ((copied += 1))
    done < <(find "$PROJECT_DIR/kernel" -maxdepth 1 -type f -print0)

    ok "sources étudiantes remplacées : $copied fichier(s) dans $course_dir"
    info "Hook central : drivers/misc/Kconfig → drivers/misc/uclinux_course/Kconfig"
    info "Hook central : drivers/misc/Makefile → obj-y += uclinux_course/"
}

reset_target_modules() {
    local release_file="$LINUX_DIR/include/config/kernel.release"
    local kernel_release
    local modules_root="$OUT/target/lib/modules"
    local release_dir

    # A fresh output has no installed modules to clean.
    [[ -e "$modules_root" || -L "$modules_root" ]] || return 0

    check_file_nonempty "$release_file"
    kernel_release="$(<"$release_file")"
    [[ "$kernel_release" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] \
        || die "version Linux impropre à un chemin : $kernel_release"

    release_dir="$modules_root/$kernel_release"
    case "$release_dir" in
        "$OUT"/target/lib/modules/"$kernel_release") ;;
        *) die "répertoire de modules hors de la sortie Buildroot : $release_dir" ;;
    esac
    [[ ! -L "$OUT/target" && ! -L "$OUT/target/lib" \
        && ! -L "$modules_root" && ! -L "$release_dir" ]] \
        || die "refus de supprimer un répertoire de modules à travers un lien symbolique"

    if [[ -e "$release_dir" ]]; then
        rm -rf -- "$release_dir"
        info "modules du rootfs supprimés avant reconstruction : $release_dir"
    fi
}

refresh_target_module_dependencies() {
    local release_dir
    local modules_dir="$OUT/target/lib/modules"

    [[ -x "$OUT/host/sbin/depmod" && -d "$modules_dir" ]] || return 0
    for release_dir in "$modules_dir"/*; do
        [[ -d "$release_dir" ]] || continue
        "$OUT/host/sbin/depmod" -a -b "$OUT/target" "${release_dir##*/}"
    done
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
        sha256sum -- "$PROJECT_DIR/kernel/Kconfig"
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
    printf 'Préparation : reset si branche helpers modifiée ou .config absente\n'
    printf '\nCommandes de construction prévues :\n'
    show_command make -C "$BUILDROOT_DIR" O="$OUT" BR2_DL_DIR="$DOWNLOAD_DIR" linux-patch
    printf '  supprimer target/lib/modules/<version> avant de le reconstruire\n'
    printf '  linux-reconfigure si la configuration a changé ; sinon linux-rebuild incrémental\n'
    show_command make -C "$BUILDROOT_DIR" O="$OUT" BR2_DL_DIR="$DOWNLOAD_DIR"
    if [[ "$MODE" == module ]]; then
        printf '\nAprès build, l’étudiant exécutera lui-même modinfo, insmod/modprobe et rmmod.\n'
    fi
    if [[ "$TARGET" == stm32 ]]; then
        printf 'Assemblage STM32 : %s\n' "$ACTIVE_POST_BUILD"
        if [[ "$MODE" == module ]]; then
            printf 'Module du cours installé dans le ROMFS : %s.ko ; les autres .ko éventuels viennent de la configuration Linux effective.\n' "$MODULE_NAME"
        fi
    fi
}

validate_build_result() {
    local kernel_config
    local module_path=""
    local course_module

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
    for course_module in "${COURSE_MODULES[@]}"; do
        if [[ "$MODE" == module && "$course_module" == "$MODULE_NAME" ]]; then
            continue
        fi
        if find "$OUT/target/lib/modules" -type f -name "$course_module.ko" -print -quit 2>/dev/null | grep -q .; then
            die "ancien module du cours encore présent dans le rootfs : $course_module.ko"
        fi
    done
}

build_profile() {
    ensure_base_config
    configure_buildroot
    run_with_log "$LOG_DIR/driver-$PROFILE-linux-patch-$TIMESTAMP.log" \
        make_br "$OUT" linux-patch
    stage_student_kernel
    reset_target_modules
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
        make_br "$OUT"
    if [[ "$TARGET" == qemu ]]; then
        refresh_target_module_dependencies
    fi
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
    printf 'branch_marker=%s/.helpers-branch\n' "$OUT"
    printf 'logs=%s\n' "$LOG_DIR"
    printf 'managed=%s\n' "$MANAGED_DIR"
    printf 'selection=%s\n' "$ACTIVE_SELECTION_STATE"
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
    local symbol
    local effective
    local buildroot_fragments
    local configured_profile=""

    [[ -s "$OUT/.config" ]] || die "configuration Buildroot absente : $OUT/.config"
    if [[ -s "$ACTIVE_SELECTION_STATE" ]]; then
        configured_profile="$(sed -n 's/^profile=//p' "$ACTIVE_SELECTION_STATE")"
        [[ "$configured_profile" == "$PROFILE" ]] ||
            die "profil actif pour $TARGET : $configured_profile ; utilisez show-config $configured_profile --target $TARGET"
    fi

    printf 'Sélection courante : '
    printf '%s\n' "$ACTIVE_SELECTION_STATE"
    if [[ -s "$ACTIVE_SELECTION_STATE" ]]; then
        sed 's/^/  /' "$ACTIVE_SELECTION_STATE"
    else
        printf '  <absente ; le prochain build créera cette sélection>\n'
    fi
    printf '\n'

    printf 'Fragment étudiant (prérequis uniquement) : '
    printf '%s/%s\n' "$PROJECT_DIR" "$PROJECT_FRAGMENT"
    sed -n -E '/^(#|CONFIG_)/p' "$PROJECT_DIR/$PROJECT_FRAGMENT"
    printf '\n'

    buildroot_fragments="$(br_config_value "$OUT/.config" BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES)"
    printf 'Configuration demandée par driver.sh et appliquée par Buildroot : '
    printf '%s\n' "$ACTIVE_KERNEL_FRAGMENT"
    case " $buildroot_fragments " in
        *" $ACTIVE_KERNEL_FRAGMENT "*)
            printf '  état : appliquée par BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES\n'
            ;;
        *)
            printf '  état : pas encore appliquée ; exécuter build\n'
            printf '  fragments actuellement appliqués : %s\n' "$buildroot_fragments"
            ;;
    esac
    if [[ -s "$ACTIVE_KERNEL_FRAGMENT" ]]; then
        sed -n -E '/^(# )?CONFIG_[A-Za-z0-9_]+(=| is not set)/p' "$ACTIVE_KERNEL_FRAGMENT"
    else
        printf '  <non générée>\n'
    fi

    LINUX_DIR="$(find_linux_dir || true)"
    [[ -n "$LINUX_DIR" ]] || {
        printf 'Configuration noyau effective : <arbre Linux non extrait>\n'
        return 0
    }
    printf '\n'

    kernel_config="$LINUX_DIR/.config"
    printf 'Configuration noyau effective après résolution Kconfig : '
    printf '%s\n' "$kernel_config"
    [[ -s "$kernel_config" ]] || {
        printf '  <.config absente>\n'
        return 0
    }
    [[ -s "$ACTIVE_KERNEL_FRAGMENT" ]] || return 0

    while IFS= read -r symbol; do
        effective="$(grep -E "^$symbol=|^# $symbol is not set$" "$kernel_config" | head -n1 || true)"
        if [[ -n "$effective" ]]; then
            printf '%s\n' "$effective"
        else
            printf '%s=<absent de .config>\n' "$symbol"
        fi
    done < <(sed -n -E 's/^(# )?(CONFIG_[A-Za-z0-9_]+)(=.*| is not set)$/\2/p' "$ACTIVE_KERNEL_FRAGMENT" | sort -u)
}

show_dtb() {
    local configured_profile=""
    local dtb_name
    local dtb

    if [[ -s "$ACTIVE_SELECTION_STATE" ]]; then
        configured_profile="$(sed -n 's/^profile=//p' "$ACTIVE_SELECTION_STATE")"
        [[ "$configured_profile" == "$PROFILE" ]] ||
            die "profil actif pour $TARGET : $configured_profile ; utilisez show-dtb $configured_profile --target $TARGET"
    fi

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

COMMAND=${1:-}
case "$COMMAND" in
    build|paths|show-config|show-dtb)
        [[ $# -ge 2 ]] || { usage >&2; exit 2; }
        PROFILE=$2
        shift 2
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
        --dry-run)
            DRY_RUN=1
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
        -h|--help)
            usage
            exit 0
            ;;
        *) die "option inconnue : $1" ;;
    esac
done

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
    build)
        if ((DRY_RUN)); then
            print_plan
            exit 0
        fi
        uclinux_begin_logging "driver-$PROFILE-$COMMAND"
        validate_project
        print_plan
        build_profile
        ;;
esac
