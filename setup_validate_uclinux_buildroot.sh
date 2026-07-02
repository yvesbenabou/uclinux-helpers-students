#!/usr/bin/env bash
#
# Préparation et validation de l'environnement du cours uClinux/Buildroot.
# Cible réelle : STM32F429I-DISC1, Linux 6.1.133, XIP + initramfs + afboot.
# Cible de prototypage : QEMU ARM VExpress.
# Hôte recommandé : Ubuntu Server 24.04 LTS ARM64 dans VirtualBox.
#
# Utilisation :
#   ./setup_validate_uclinux_buildroot.sh
#       Installation + configuration + builds complets STM32/QEMU + test QEMU.
#
#   ./setup_validate_uclinux_buildroot.sh --quick
#       Installation + configuration + contrôles, sans compilation complète.
#
#   ./setup_validate_uclinux_buildroot.sh --probe-stlink
#       Même validation complète, puis détection de la carte par OpenOCD,
#       sans écrire dans la Flash.
#
# Options :
#   --root CHEMIN              Racine de travail (défaut : $HOME/uclinux)
#   --jobs N                   Nombre de compilations parallèles
#   --skip-apt                 Ne pas installer les paquets Ubuntu
#   --quick                    Ne pas lancer les builds complets
#   --skip-qemu-test           Construire QEMU sans lancer le test de démarrage
#   --probe-stlink             Tester ST-LINK/OpenOCD sans flasher
#   --allow-other-release      Accepter une version Ubuntu autre que 24.04
#   --quiet                    Masquer la sortie verbeuse des commandes longues
#   --debug                    Tracer l'entrée et la sortie des fonctions
#   --no-resume                Ignorer les étapes déjà marquées comme réussies
#   --force-step NOM           Réexécuter une étape réussie (build-stm32, build-qemu)
#   -h, --help                 Afficher l'aide
#
# Le script est réexécutable. Il ne supprime ni les sources, ni les sorties.

set -Eeuo pipefail
umask 022

BUILDROOT_REF="2025.08"
EXPECTED_LINUX_VERSION="6.1.133"
LINUX_STABLE_GIT_URL="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
WORK_ROOT="${HOME}/uclinux"
JOBS="$(nproc 2>/dev/null || echo 2)"
SKIP_APT=0
QUICK=0
SKIP_QEMU_TEST=0
PROBE_STLINK=0
ALLOW_OTHER_RELEASE=0
QUIET=0
DEBUG_TRACE=0
RESUME=1
FORCE_STEPS=()

usage() {
    cat <<'USAGE'
Préparation et validation de l’environnement du cours uClinux/Buildroot.

Utilisation :
  ./setup_validate_uclinux_buildroot.sh
      Installation + configuration + builds complets STM32/QEMU + test QEMU.

  ./setup_validate_uclinux_buildroot.sh --quick
      Installation + configuration + contrôles, sans compilation complète.

  ./setup_validate_uclinux_buildroot.sh --probe-stlink
      Même validation complète, puis détection de la carte par OpenOCD,
      sans écrire dans la Flash.

Options :
  --root CHEMIN              Racine de travail (défaut : $HOME/uclinux)
  --jobs N                   Nombre de compilations parallèles
  --skip-apt                 Ne pas installer les paquets Ubuntu
  --quick                    Ne pas lancer les builds complets
  --skip-qemu-test           Construire QEMU sans lancer le test de démarrage
  --probe-stlink             Tester ST-LINK/OpenOCD sans flasher
  --allow-other-release      Accepter une version Ubuntu autre que 24.04
  --quiet                    Masquer la sortie verbeuse des commandes longues
  --debug                    Tracer l'entrée et la sortie des fonctions
  --no-resume                Ignorer les étapes déjà marquées comme réussies
  --force-step NOM           Réexécuter une étape réussie (build-stm32, build-qemu)
  -h, --help                 Afficher l’aide

Le script est réexécutable. Il ne supprime ni les sources, ni les sorties.
USAGE
}

while (($#)); do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || { echo "ERREUR : --root attend un chemin." >&2; exit 2; }
            WORK_ROOT="$2"
            shift 2
            ;;
        --jobs)
            [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]*$ ]] || {
                echo "ERREUR : --jobs attend un entier strictement positif." >&2
                exit 2
            }
            JOBS="$2"
            shift 2
            ;;
        --skip-apt) SKIP_APT=1; shift ;;
        --quick) QUICK=1; shift ;;
        --skip-qemu-test) SKIP_QEMU_TEST=1; shift ;;
        --probe-stlink) PROBE_STLINK=1; shift ;;
        --allow-other-release) ALLOW_OTHER_RELEASE=1; shift ;;
        --quiet) QUIET=1; shift ;;
        --debug) DEBUG_TRACE=1; shift ;;
        --no-resume) RESUME=0; shift ;;
        --force-step)
            [[ $# -ge 2 ]] || { echo "ERREUR : --force-step attend un nom d'étape." >&2; exit 2; }
            case "$2" in
                build-stm32|build-qemu) ;;
                *) echo "ERREUR : étape inconnue pour --force-step : $2" >&2; exit 2 ;;
            esac
            FORCE_STEPS+=("$2")
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERREUR : option inconnue : $1" >&2; usage; exit 2 ;;
    esac
done

WORK_ROOT="$(readlink -m "$WORK_ROOT")"
BUILDROOT_DIR="$WORK_ROOT/buildroot"
DOWNLOAD_DIR="$WORK_ROOT/downloads"
OUTPUT_ROOT="$WORK_ROOT/outputs"
STM32_OUT="$OUTPUT_ROOT/stm32f429"
QEMU_OUT="$OUTPUT_ROOT/qemu-vexpress"
LABS_DIR="$WORK_ROOT/labs"
DOCS_DIR="$WORK_ROOT/documents"
LOG_DIR="$WORK_ROOT/logs"
STATE_DIR="$WORK_ROOT/.setup_validate_state"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
MAIN_LOG="$LOG_DIR/validation-$TIMESTAMP.log"
REPORT="$LOG_DIR/report-$TIMESTAMP.txt"

mkdir -p "$LOG_DIR" "$STATE_DIR"
exec 3>&1
exec > >(tee -a "$MAIN_LOG" >&3) 2>&1

if [[ -t 3 ]]; then
    C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
    C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

debug_trace() {
    ((DEBUG_TRACE)) || return 0
    case "$1" in
        enter) printf '[DEBUG] entering %s()...\n' "$2" ;;
        exit)  printf '[DEBUG] exiting %s() (code %s)\n' "$2" "$3" ;;
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
warn() { log_helper "${FUNCNAME[0]}" 0 "$C_YELLOW" WARN 1 "$@"; }

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
trap on_error ERR

require_cmd() {
    local __fn="${FUNCNAME[0]}"
    debug_enter "$__fn"
    command -v "$1" >/dev/null 2>&1 || die "commande absente : $1"
    debug_exit "$__fn" 0
}

check_file_nonempty() {
    local __fn="${FUNCNAME[0]}"
    debug_enter "$__fn"
    local path=$1
    [[ -s "$path" ]] || die "fichier attendu absent ou vide : $path"
    ok "présent : $path"
    debug_exit "$__fn" 0
}

run_with_log() {
    local __fn="${FUNCNAME[0]}"
    debug_enter "$__fn"
    local logfile=$1
    local rc
    shift
    info "Exécution : $*"
    set +e
    if ((QUIET)); then
        "$@" >"$logfile" 2>&1
        rc=$?
    else
        "$@" 2>&1 | tee "$logfile"
        rc=${PIPESTATUS[0]}
    fi
    set -e
    if ((rc != 0)); then
        debug_exit "$__fn" "$rc"
        die "commande en échec (code $rc), voir $logfile"
    fi
    ((QUIET)) && ok "journal : $logfile"
    debug_exit "$__fn" 0
}

make_br() {
    local __fn="${FUNCNAME[0]}"
    debug_enter "$__fn"
    local out=$1
    shift
    make -C "$BUILDROOT_DIR" O="$out" BR2_DL_DIR="$DOWNLOAD_DIR" "$@"
    local rc=$?
    debug_exit "$__fn" "$rc"
    return "$rc"
}

br_config_value() {
    local __fn="${FUNCNAME[0]}"
    debug_enter "$__fn"
    local config=$1
    local key=$2
    sed -n "s/^${key}=\"\(.*\)\"$/\1/p" "$config" | head -n1
    local rc=${PIPESTATUS[0]}
    debug_exit "$__fn" "$rc"
    return "$rc"
}

prepare_linux_override() {
    local __fn="${FUNCNAME[0]}"
    debug_enter "$__fn"
    local out=$1
    local config="$out/.config"
    local version
    local source_dir
    local local_mk="$out/local.mk"

    version="$(br_config_value "$config" BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE)"
    if [[ -z "$version" ]]; then
        debug_exit "$__fn" 0
        return 0
    fi

    source_dir="$WORK_ROOT/linux-$version"
    if [[ ! -e "$source_dir/.git" ]]; then
        if [[ -e "$source_dir" ]]; then
            die "le chemin existe mais n'est pas un dépôt git : $source_dir"
        fi
        info "Clone superficiel Linux $version : $source_dir"
        run_with_log "$LOG_DIR/linux-$version-clone-$TIMESTAMP.log" git clone --depth 1 --branch "v$version" "$LINUX_STABLE_GIT_URL" "$source_dir"
    else
        info "Source Linux $version déjà présente : $source_dir"
        if ! git -C "$source_dir" rev-parse --verify "v$version^{commit}" >/dev/null 2>&1; then
            run_with_log "$LOG_DIR/linux-$version-fetch-$TIMESTAMP.log" git -C "$source_dir" fetch --depth 1 origin "refs/tags/v$version:refs/tags/v$version"
        fi
    fi

    git -C "$source_dir" rev-parse --verify "v$version^{commit}" >/dev/null \
        || die "tag Linux v$version absent dans $source_dir"
    git -C "$source_dir" checkout -q "v$version"

    mkdir -p "$out"
    if [[ -f "$local_mk" ]]; then
        sed -i '/^LINUX_OVERRIDE_SRCDIR[[:space:]]*=/d' "$local_mk"
    fi
    printf 'LINUX_OVERRIDE_SRCDIR = %s\n' "$source_dir" >> "$local_mk"
    ok "Buildroot utilisera Linux $version depuis $source_dir"
    debug_exit "$__fn" 0
}

linux_build_dir() {
    local __fn="${FUNCNAME[0]}"
    debug_enter "$__fn"
    local out=$1
    local version=$2
    local dir

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

force_step_requested() {
    local __fn="${FUNCNAME[0]}"
    debug_enter "$__fn"
    local step=$1
    local forced
    for forced in "${FORCE_STEPS[@]}"; do
        if [[ "$forced" == "$step" ]]; then
            debug_exit "$__fn" 0
            return 0
        fi
    done
    debug_exit "$__fn" 1
    return 1
}

step_marker() {
    local __fn="${FUNCNAME[0]}"
    debug_enter "$__fn"
    printf '%s/%s.ok\n' "$STATE_DIR" "$1"
    debug_exit "$__fn" 0
}

step_completed() {
    local __fn="${FUNCNAME[0]}"
    debug_enter "$__fn"
    local step=$1
    local fingerprint=${2:-}
    local marker

    if ((RESUME)) && ! force_step_requested "$step"; then
        marker="$(step_marker "$step")"
        if [[ -f "$marker" ]] && grep -qx "buildroot=$BUILDROOT_REF" "$marker"; then
            if [[ -z "$fingerprint" ]] || grep -qx "fingerprint=$fingerprint" "$marker"; then
                debug_exit "$__fn" 0
                return 0
            fi
        fi
    fi

    debug_exit "$__fn" 1
    return 1
}

mark_step_completed() {
    local __fn="${FUNCNAME[0]}"
    debug_enter "$__fn"
    local step=$1
    local fingerprint=${2:-}
    {
        printf 'date=%s\n' "$(date --iso-8601=seconds)"
        printf 'buildroot=%s\n' "$BUILDROOT_REF"
        [[ -z "$fingerprint" ]] || printf 'fingerprint=%s\n' "$fingerprint"
    } >"$(step_marker "$step")"
    debug_exit "$__fn" 0
}

step_fingerprint() {
    local __fn="${FUNCNAME[0]}"
    debug_enter "$__fn"
    local out=$1
    sha256sum "$out/.config" "$out/local.mk" | sha256sum | awk '{print $1}'
    local rc=${PIPESTATUS[0]}
    debug_exit "$__fn" "$rc"
    return "$rc"
}

section() {
    local __fn="${FUNCNAME[0]}"
    debug_enter "$__fn"
    printf '\n%s================================================================%s\n' "$C_BOLD" "$C_RESET"
    printf '%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"
    printf '%s================================================================%s\n' "$C_BOLD" "$C_RESET"
    debug_exit "$__fn" 0
}

section "1. Contrôle du système hôte"

[[ "$(id -u)" -ne 0 ]] || die "n'exécutez pas Buildroot avec le compte root. Lancez le script comme utilisateur normal."

[[ -r /etc/os-release ]] || die "ce script doit être exécuté sous Ubuntu Linux."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "distribution détectée : ${PRETTY_NAME:-inconnue}. Ubuntu est requis pour l'environnement de référence."

if [[ "${VERSION_ID:-}" != "24.04" ]]; then
    if ((ALLOW_OTHER_RELEASE)); then
        warn "Ubuntu ${VERSION_ID:-inconnue} accepté sur demande ; la référence du cours reste Ubuntu 24.04 LTS."
    else
        die "Ubuntu ${VERSION_ID:-inconnue} détecté. Utilisez Ubuntu 24.04 LTS ou ajoutez --allow-other-release."
    fi
fi
ok "système : ${PRETTY_NAME}"

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
    aarch64|arm64) ok "architecture hôte ARM64 native : $HOST_ARCH" ;;
    x86_64|amd64) warn "architecture hôte x86-64 : supportée, mais ce test visait initialement Apple Silicon/ARM64." ;;
    *) die "architecture hôte non validée pour ce cours : $HOST_ARCH" ;;
esac

VIRT="$(systemd-detect-virt 2>/dev/null || true)"
case "$VIRT" in
    oracle) ok "hyperviseur détecté : VirtualBox" ;;
    none|"") warn "aucun hyperviseur détecté ; le script peut fonctionner sur une machine Ubuntu physique." ;;
    *) warn "hyperviseur détecté : $VIRT ; la référence pédagogique est VirtualBox." ;;
esac

MEM_KIB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
MEM_GIB=$((MEM_KIB / 1024 / 1024))
((MEM_GIB >= 6)) && ok "mémoire disponible : environ ${MEM_GIB} Gio" || warn "mémoire limitée : environ ${MEM_GIB} Gio ; 8 Gio sont recommandés."

FREE_KIB="$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
FREE_GIB=$((FREE_KIB / 1024 / 1024))
((FREE_GIB >= 25)) || die "espace libre insuffisant dans $HOME : ${FREE_GIB} Gio ; prévoyez au moins 25 Gio."
ok "espace libre : environ ${FREE_GIB} Gio"

section "2. Installation des outils Ubuntu"

APT_PACKAGES=(
    build-essential binutils git wget curl ca-certificates
    rsync cpio unzip bzip2 gzip xz-utils tar patch perl bc
    file findutils gawk sed diffutils coreutils
    python3 libncurses-dev bison flex libssl-dev libelf-dev
    device-tree-compiler qemu-system-arm openocd usbutils
    openssh-server iproute2 time locales
)

if ((SKIP_APT == 0)); then
    if command -v sudo >/dev/null 2>&1; then
        SUDO=sudo
    else
        die "sudo est absent. Installez-le ou lancez l'installation des paquets manuellement."
    fi
    $SUDO -v
    run_with_log "$LOG_DIR/apt-update-$TIMESTAMP.log" "$SUDO" apt-get update
    run_with_log "$LOG_DIR/apt-install-$TIMESTAMP.log" "$SUDO" env DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PACKAGES[@]}"
else
    warn "installation APT ignorée (--skip-apt)."
fi

for cmd in gcc g++ make git wget rsync cpio file bc python3 bison flex dtc qemu-system-arm openocd ssh sshd lsusb readelf timeout sha256sum script; do
    require_cmd "$cmd"
done
ok "outils fondamentaux présents"

printf 'gcc       : '; gcc --version | head -n1
printf 'make      : '; make --version | head -n1
printf 'git       : '; git --version
printf 'QEMU      : '; qemu-system-arm --version | head -n1
printf 'OpenOCD   : '; openocd --version 2>&1 | head -n1
printf 'DTC       : '; dtc --version

section "3. Accès SSH depuis l'hôte"

if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now ssh
    systemctl is-active --quiet ssh || die "le service SSH n'est pas actif."
    ok "service SSH actif et activé au démarrage"
else
    warn "systemctl absent : activation automatique de SSH non vérifiée."
fi

if ss -ltn 2>/dev/null | grep -Eq ':[[:space:]]*22\b|:22[[:space:]]'; then
    ok "un serveur écoute sur le port TCP 22"
else
    warn "le port TCP 22 n'a pas été détecté ; vérifiez 'systemctl status ssh'."
fi

mkdir -p "$DOCS_DIR"
cat > "$DOCS_DIR/acces-depuis-hote.txt" <<HOSTEOF
Accès recommandé depuis macOS/Windows/Linux
============================================

1. Dans VirtualBox, conservez l'adaptateur réseau en mode NAT.
2. Ajoutez une redirection de port :
     hôte 127.0.0.1:2222  ->  invité :22/TCP

Commande à exécuter sur l'hôte :
     ssh -p 2222 ${USER}@127.0.0.1

Entrée possible dans ~/.ssh/config sur l'hôte :

Host uclinux-vm
    HostName 127.0.0.1
    User ${USER}
    Port 2222

Dans VS Code :
  - installer l'extension « Remote - SSH » ;
  - se connecter à « uclinux-vm » ;
  - ouvrir le dossier ${WORK_ROOT}.

Le projet Buildroot doit rester sur le disque Linux de la VM,
pas dans un dossier partagé VirtualBox.
HOSTEOF
ok "fiche d'accès créée : $DOCS_DIR/acces-depuis-hote.txt"

section "4. Arborescence de travail"

mkdir -p "$DOWNLOAD_DIR" "$STM32_OUT" "$QEMU_OUT" "$LABS_DIR" "$DOCS_DIR"
cat > "$WORK_ROOT/env.sh" <<ENVEOF
# À charger avec : source "$WORK_ROOT/env.sh"
export UCLINUX_ROOT="$WORK_ROOT"
export BUILDROOT_DIR="$BUILDROOT_DIR"
export BR2_DL_DIR="$DOWNLOAD_DIR"
export STM32_OUT="$STM32_OUT"
export QEMU_OUT="$QEMU_OUT"
ENVEOF

cat > "$WORK_ROOT/uclinux.code-workspace" <<WORKSPACEEOF
{
  "folders": [
    { "name": "Buildroot", "path": "buildroot" },
    { "name": "TP", "path": "labs" },
    { "name": "Documents", "path": "documents" }
  ],
  "settings": {
    "files.associations": {
      "Config.in": "makefile",
      "*.mk": "makefile",
      "*.dts": "c",
      "*.dtsi": "c"
    }
  }
}
WORKSPACEEOF

ok "racine de travail : $WORK_ROOT"
printf '%s\n' \
    "  buildroot/   sources Buildroot" \
    "  downloads/   cache des archives téléchargées" \
    "  outputs/     sorties séparées par cible" \
    "  labs/        travaux étudiants" \
    "  documents/   fiches d'utilisation" \
    "  logs/        journaux et rapports"

section "5. Acquisition et contrôle de Buildroot"

if [[ ! -d "$BUILDROOT_DIR/.git" ]]; then
    run_with_log "$LOG_DIR/buildroot-clone-$TIMESTAMP.log" git clone --branch "$BUILDROOT_REF" --depth 1 https://gitlab.com/buildroot.org/buildroot.git "$BUILDROOT_DIR"
else
    info "dépôt Buildroot déjà présent : $BUILDROOT_DIR"
fi

CURRENT_REF="$(git -C "$BUILDROOT_DIR" describe --tags --exact-match 2>/dev/null || true)"
[[ "$CURRENT_REF" == "$BUILDROOT_REF" ]] || {
    CURRENT_COMMIT="$(git -C "$BUILDROOT_DIR" rev-parse --short HEAD)"
    die "le dépôt existant n'est pas exactement sur $BUILDROOT_REF (référence détectée : ${CURRENT_REF:-$CURRENT_COMMIT})."
}
ok "Buildroot $BUILDROOT_REF"

[[ -z "$(git -C "$BUILDROOT_DIR" status --porcelain)" ]] \
    && ok "arbre Buildroot propre" \
    || warn "l'arbre Buildroot contient des modifications locales."

STM32_DEFCONFIG="$BUILDROOT_DIR/configs/stm32f429_disco_xip_defconfig"
QEMU_DEFCONFIG="$BUILDROOT_DIR/configs/qemu_arm_vexpress_defconfig"
check_file_nonempty "$STM32_DEFCONFIG"
check_file_nonempty "$QEMU_DEFCONFIG"

grep -q 'BR2_cortex_m4=y' "$STM32_DEFCONFIG" || die "le defconfig STM32 ne sélectionne pas Cortex-M4."
grep -q "BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE=\"$EXPECTED_LINUX_VERSION\"" "$STM32_DEFCONFIG" \
    || die "le defconfig STM32 ne sélectionne pas Linux $EXPECTED_LINUX_VERSION."
grep -q 'BR2_LINUX_KERNEL_IMAGE_TARGET_NAME="xipImage"' "$STM32_DEFCONFIG" || die "xipImage non sélectionnée."
grep -q 'BR2_TARGET_ROOTFS_INITRAMFS=y' "$STM32_DEFCONFIG" || die "initramfs non sélectionné."
grep -q 'BR2_TARGET_AFBOOT_STM32=y' "$STM32_DEFCONFIG" || die "afboot-stm32 non sélectionné."
grep -q 'BR2_PACKAGE_HOST_OPENOCD=y' "$STM32_DEFCONFIG" || die "OpenOCD hôte non sélectionné."
ok "le defconfig STM32 correspond au scénario pédagogique"

section "6. Génération des configurations actives"

run_with_log "$LOG_DIR/defconfig-stm32-$TIMESTAMP.log" make_br "$STM32_OUT" stm32f429_disco_xip_defconfig
check_file_nonempty "$STM32_OUT/.config"
grep -q 'BR2_cortex_m4=y' "$STM32_OUT/.config"
grep -q "BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE=\"$EXPECTED_LINUX_VERSION\"" "$STM32_OUT/.config"
ok "configuration active STM32 générée dans $STM32_OUT/.config"

run_with_log "$LOG_DIR/defconfig-qemu-$TIMESTAMP.log" make_br "$QEMU_OUT" qemu_arm_vexpress_defconfig
check_file_nonempty "$QEMU_OUT/.config"
grep -q 'BR2_cortex_a9=y' "$QEMU_OUT/.config"
ok "configuration active QEMU générée dans $QEMU_OUT/.config"

if ((QUICK)); then
    section "Validation rapide terminée"
    cat > "$REPORT" <<EOFREPORT
VALIDATION RAPIDE RÉUSSIE
Date                : $(date --iso-8601=seconds)
Système             : $PRETTY_NAME
Architecture hôte   : $HOST_ARCH
Virtualisation      : ${VIRT:-non détectée}
Buildroot           : $BUILDROOT_REF
Racine de travail   : $WORK_ROOT
Configuration STM32 : $STM32_OUT/.config
Configuration QEMU  : $QEMU_OUT/.config
Builds complets     : non exécutés (--quick)
État reprise        : $STATE_DIR
Journal             : $MAIN_LOG
EOFREPORT
    cat "$REPORT"
    exit 0
fi

section "7. Préparation des sources Linux locales"

prepare_linux_override "$STM32_OUT"
prepare_linux_override "$QEMU_OUT"

section "8. Construction complète STM32F429I-DISC1"

STM32_BUILD_FINGERPRINT="$(step_fingerprint "$STM32_OUT")"
if step_completed "build-stm32" "$STM32_BUILD_FINGERPRINT"; then
    ok "étape déjà validée, make STM32 ignoré (--force-step build-stm32 pour la relancer)"
else
    run_with_log "$LOG_DIR/build-stm32-$TIMESTAMP.log" make_br "$STM32_OUT" -j"$JOBS"
fi

STM32_IMAGES=(
    "$STM32_OUT/images/stm32f429i-disco.bin"
    "$STM32_OUT/images/stm32f429-disco.dtb"
    "$STM32_OUT/images/xipImage"
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
ok "noyau Linux $EXPECTED_LINUX_VERSION : ARM, no-MMU, XIP, initramfs"

check_file_nonempty "$STM32_OUT/target/bin/busybox"
ok "BusyBox installé dans le rootfs préparé"

TARGET_GCC="$(find "$STM32_OUT/host/bin" -maxdepth 1 \( -type f -o -type l \) -name '*-gcc' | sort | head -n1)"
[[ -n "$TARGET_GCC" ]] || die "compilateur croisé introuvable dans $STM32_OUT/host/bin."
file "$TARGET_GCC"
printf 'Triplet cible : %s\n' "$("$TARGET_GCC" -dumpmachine)"
ok "chaîne de compilation croisée opérationnelle"

check_file_nonempty "$STM32_OUT/host/bin/openocd"
file "$STM32_OUT/host/bin/openocd"
"$STM32_OUT/host/bin/openocd" --version 2>&1 | head -n1
ok "OpenOCD hôte construit par Buildroot"

DT_DUMP="$LOG_DIR/stm32f429-disco-$TIMESTAMP.dts"
dtc -I dtb -O dts "$STM32_OUT/images/stm32f429-disco.dtb" > "$DT_DUMP"
grep -q '/dts-v1/' "$DT_DUMP" || die "le DTB n'a pas pu être décompilé correctement."
ok "DTB valide ; décompilation enregistrée dans $DT_DUMP"
mark_step_completed "build-stm32" "$STM32_BUILD_FINGERPRINT"

printf '\nImages STM32 générées :\n'
find "$STM32_OUT/images" -maxdepth 1 -type f -printf '  %-38f %10s octets\n' | sort

section "9. Construction complète QEMU ARM VExpress"

QEMU_BUILD_FINGERPRINT="$(step_fingerprint "$QEMU_OUT")"
if step_completed "build-qemu" "$QEMU_BUILD_FINGERPRINT"; then
    ok "étape déjà validée, make QEMU ignoré (--force-step build-qemu pour la relancer)"
else
    run_with_log "$LOG_DIR/build-qemu-$TIMESTAMP.log" make_br "$QEMU_OUT" -j"$JOBS"
fi

QEMU_IMAGES=(
    "$QEMU_OUT/images/zImage"
    "$QEMU_OUT/images/vexpress-v2p-ca9.dtb"
    "$QEMU_OUT/images/rootfs.ext2"
)
for image in "${QEMU_IMAGES[@]}"; do check_file_nonempty "$image"; done
check_file_nonempty "$QEMU_OUT/host/bin/qemu-system-arm"
file "$QEMU_OUT/host/bin/qemu-system-arm"
ok "cible QEMU et émulateur hôte construits"
mark_step_completed "build-qemu" "$QEMU_BUILD_FINGERPRINT"

printf '\nImages QEMU générées :\n'
find "$QEMU_OUT/images" -maxdepth 1 -type f -printf '  %-38f %10s octets\n' | sort

QEMU_BOOT_OK="non testé"
if ((SKIP_QEMU_TEST == 0)); then
    section "10. Test de démarrage QEMU"
    QEMU_BOOT_LOG="$LOG_DIR/qemu-boot-$TIMESTAMP.log"
    QEMU_START="$QEMU_OUT/images/start-qemu.sh"
    check_file_nonempty "$QEMU_START"

    QEMU_TIMEOUT_CMD=(timeout --signal=TERM --kill-after=5s 90s "$QEMU_START" --serial-only)
    printf -v QEMU_SCRIPT_CMD '%q ' "${QEMU_TIMEOUT_CMD[@]}"
    QEMU_CMD=(script -qefc "$QEMU_SCRIPT_CMD" /dev/null)
    info "Démarrage QEMU via pseudo-terminal ; sortie série aussi enregistrée dans $QEMU_BOOT_LOG"
    if "${QEMU_CMD[@]}" 2>&1 | tee "$QEMU_BOOT_LOG"; then
        QEMU_RC=0
    else
        QEMU_RC=${PIPESTATUS[0]}
    fi
    QEMU_BOOT_BYTES=$(wc -c < "$QEMU_BOOT_LOG" 2>/dev/null || printf '0')
    info "QEMU terminé : code $QEMU_RC, journal $QEMU_BOOT_BYTES octets"

    if grep -Eqi 'Welcome to Buildroot|buildroot login:|login:' "$QEMU_BOOT_LOG"; then
        QEMU_BOOT_OK="oui"
        ok "Linux a démarré sous QEMU jusqu'à l'invite de connexion"
    else
        tail -n 80 "$QEMU_BOOT_LOG" || true
        die "le test QEMU n'a pas atteint l'invite de connexion (code $QEMU_RC). Voir $QEMU_BOOT_LOG"
    fi
else
    warn "test de démarrage QEMU ignoré (--skip-qemu-test)."
fi

STLINK_RESULT="non demandé"
if ((PROBE_STLINK)); then
    section "11. Détection ST-LINK/OpenOCD sans flashage"
    STLINK_RESULT="échec"
    if ! lsusb | grep -Eqi '0483:|STMicroelectronics|ST-LINK'; then
        die "aucun ST-LINK détecté dans la VM. Vérifiez la redirection USB VirtualBox."
    fi
    ok "ST-LINK visible par lsusb"

    OPENOCD_LOG="$LOG_DIR/openocd-probe-$TIMESTAMP.log"
    OPENOCD_SCRIPTS="$STM32_OUT/host/share/openocd/scripts"
    run_with_log "$OPENOCD_LOG" \
        "$STM32_OUT/host/bin/openocd" \
        -s "$OPENOCD_SCRIPTS" \
        -f board/stm32f429disc1.cfg \
        -c "init" \
        -c "reset halt" \
        -c "flash probe 0" \
        -c "flash info 0" \
        -c "shutdown"
    STLINK_RESULT="oui"
    ok "OpenOCD communique avec la carte ; aucune écriture Flash n'a été effectuée"
fi

section "12. Rapport final"

cat > "$REPORT" <<EOFREPORT
VALIDATION COMPLÈTE RÉUSSIE
Date                  : $(date --iso-8601=seconds)
Système               : $PRETTY_NAME
Architecture hôte     : $HOST_ARCH
Virtualisation        : ${VIRT:-non détectée}
Buildroot             : $BUILDROOT_REF
Linux STM32           : $EXPECTED_LINUX_VERSION
Racine de travail     : $WORK_ROOT
Cache téléchargements : $DOWNLOAD_DIR
État reprise          : $STATE_DIR
Sortie STM32          : $STM32_OUT
Sortie QEMU           : $QEMU_OUT
Build STM32           : réussi
Build QEMU            : réussi
Démarrage QEMU        : $QEMU_BOOT_OK
Détection ST-LINK     : $STLINK_RESULT
Journal principal     : $MAIN_LOG
Rapport               : $REPORT

Images STM32 principales :
  $STM32_OUT/images/stm32f429i-disco.bin
  $STM32_OUT/images/stm32f429-disco.dtb
  $STM32_OUT/images/xipImage

Images QEMU principales :
  $QEMU_OUT/images/zImage
  $QEMU_OUT/images/vexpress-v2p-ca9.dtb
  $QEMU_OUT/images/rootfs.ext2
EOFREPORT

cat "$REPORT"
printf '\n%sVALIDATION TERMINÉE AVEC SUCCÈS%s\n' "$C_GREEN" "$C_RESET"
printf 'Ouvrez ensuite dans VS Code Remote-SSH : %s\n' "$WORK_ROOT/uclinux.code-workspace"
printf 'Fiche de connexion hôte : %s\n' "$DOCS_DIR/acces-depuis-hote.txt"
