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
#   -h, --help                 Afficher l'aide
#
# Le script est réexécutable. Il ne supprime ni les sources, ni les sorties.

set -Eeuo pipefail
umask 022

BUILDROOT_REF="2025.08"
EXPECTED_LINUX_VERSION="6.1.133"
LINUX_SOURCE_TARBALL="linux-$EXPECTED_LINUX_VERSION.tar.xz"
LINUX_SNAPSHOT_TARBALL="linux-$EXPECTED_LINUX_VERSION.tar.gz"
LINUX_SNAPSHOT_URL="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/snapshot/linux-$EXPECTED_LINUX_VERSION.tar.gz"
LINUX_SNAPSHOT_SHA256="0779d87e024366adb8d3a07d17f4783c0c43091595bc09e1b682b8766642f496"
WORK_ROOT="${HOME}/uclinux"
JOBS="$(nproc 2>/dev/null || echo 2)"
SKIP_APT=0
QUICK=0
SKIP_QEMU_TEST=0
PROBE_STLINK=0
ALLOW_OTHER_RELEASE=0

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
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
MAIN_LOG="$LOG_DIR/validation-$TIMESTAMP.log"
REPORT="$LOG_DIR/report-$TIMESTAMP.txt"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$MAIN_LOG") 2>&1

if [[ -t 1 ]]; then
    C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
    C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

info() { printf '%s[INFO]%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

on_error() {
    local rc=$?
    printf '%s[FAIL]%s erreur ligne %s, commande : %s (code %s)\n' \
        "$C_RED" "$C_RESET" "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-?}" "$rc" >&2
    printf 'Journal : %s\n' "$MAIN_LOG" >&2
    exit "$rc"
}
trap on_error ERR

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "commande absente : $1"
}

check_file_nonempty() {
    local path=$1
    [[ -s "$path" ]] || die "fichier attendu absent ou vide : $path"
    ok "présent : $path"
}

run_with_log() {
    local logfile=$1
    shift
    info "Exécution : $*"
    set +e
    "$@" 2>&1 | tee "$logfile"
    local rc=${PIPESTATUS[0]}
    set -e
    ((rc == 0)) || die "commande en échec (code $rc), voir $logfile"
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

set_hash_file_entry() {
    local hash_file=$1
    local source=$2
    local hash=$3
    local tmp="${hash_file}.tmp.$$"

    awk -v source="$source" -v hash="$hash" '
        $1 == "sha256" && $3 == source {
            if (!done) {
                printf "sha256  %s  %s\n", hash, source
                done = 1
            }
            next
        }
        { print }
        END {
            if (!done) {
                printf "sha256  %s  %s\n", hash, source
            }
        }
    ' "$hash_file" > "$tmp"
    mv -f "$tmp" "$hash_file"
}

download_with_sha256() {
    local dest=$1
    local expected_hash=$2
    shift 2

    local actual_hash
    if [[ -s "$dest" ]]; then
        actual_hash="$(sha256_file "$dest")"
        if [[ "$actual_hash" == "$expected_hash" ]]; then
            ok "archive déjà en cache : $dest"
            return 0
        fi
        warn "archive en cache invalide, nouveau téléchargement : $dest"
    fi

    local tmp="${dest}.tmp.$$"
    local url
    for url in "$@"; do
        rm -f "$tmp"
        info "Téléchargement : $url"
        if wget -nd -t 3 --connect-timeout=10 -O "$tmp" "$url"; then
            actual_hash="$(sha256_file "$tmp")"
            if [[ "$actual_hash" == "$expected_hash" ]]; then
                mv -f "$tmp" "$dest"
                ok "archive téléchargée et vérifiée : $dest"
                return 0
            fi
            warn "empreinte SHA-256 incorrecte pour $url"
        else
            warn "téléchargement impossible : $url"
        fi
    done

    rm -f "$tmp"
    die "impossible de télécharger une archive valide : $dest"
}

prefetch_linux_source() {
    local source_xz="$DOWNLOAD_DIR/$LINUX_SOURCE_TARBALL"
    local snapshot_gz="$DOWNLOAD_DIR/$LINUX_SNAPSHOT_TARBALL"
    local hash_file="$BUILDROOT_DIR/board/stmicroelectronics/stm32f429-disco/patches/linux/linux.hash"
    local expected_hash
    local actual_hash

    expected_hash="$(awk -v source="$LINUX_SOURCE_TARBALL" '$1 == "sha256" && $3 == source { print $2; exit }' "$hash_file")"
    if [[ -n "$expected_hash" && -s "$source_xz" ]]; then
        actual_hash="$(sha256_file "$source_xz")"
        if [[ "$actual_hash" == "$expected_hash" ]]; then
            ok "archive Linux déjà prête : $source_xz"
            return 0
        fi
        warn "archive Linux présente mais non conforme au hash local : $source_xz"
    fi

    download_with_sha256 "$snapshot_gz" "$LINUX_SNAPSHOT_SHA256" "$LINUX_SNAPSHOT_URL"

    local tmp="${source_xz}.tmp.$$"
    rm -f "$tmp"
    info "Recompression locale : $LINUX_SNAPSHOT_TARBALL -> $LINUX_SOURCE_TARBALL"
    gzip -dc "$snapshot_gz" | xz -0 -T0 -c > "$tmp"
    mv -f "$tmp" "$source_xz"

    actual_hash="$(sha256_file "$source_xz")"
    set_hash_file_entry "$hash_file" "$LINUX_SOURCE_TARBALL" "$actual_hash"
    ok "archive Linux préparée : $source_xz"
    ok "empreinte locale mise à jour dans $hash_file"
}

make_br() {
    local out=$1
    shift
    make -C "$BUILDROOT_DIR" O="$out" BR2_DL_DIR="$DOWNLOAD_DIR" "$@"
}

section() {
    printf '\n%s================================================================%s\n' "$C_BOLD" "$C_RESET"
    printf '%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"
    printf '%s================================================================%s\n' "$C_BOLD" "$C_RESET"
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
    $SUDO apt-get update
    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "${APT_PACKAGES[@]}"
else
    warn "installation APT ignorée (--skip-apt)."
fi

for cmd in gcc g++ make git wget rsync cpio file bc python3 bison flex dtc qemu-system-arm openocd ssh sshd lsusb readelf timeout sha256sum gzip xz; do
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
    git clone --branch "$BUILDROOT_REF" --depth 1 \
        https://gitlab.com/buildroot.org/buildroot.git \
        "$BUILDROOT_DIR"
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

make_br "$STM32_OUT" stm32f429_disco_xip_defconfig
check_file_nonempty "$STM32_OUT/.config"
grep -q 'BR2_cortex_m4=y' "$STM32_OUT/.config"
grep -q "BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE=\"$EXPECTED_LINUX_VERSION\"" "$STM32_OUT/.config"
ok "configuration active STM32 générée dans $STM32_OUT/.config"

make_br "$QEMU_OUT" qemu_arm_vexpress_defconfig
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
Journal             : $MAIN_LOG
EOFREPORT
    cat "$REPORT"
    exit 0
fi

section "7. Préchargement de l'archive Linux $EXPECTED_LINUX_VERSION"

prefetch_linux_source

section "8. Construction complète STM32F429I-DISC1"

run_with_log "$LOG_DIR/build-stm32-$TIMESTAMP.log" \
    make_br "$STM32_OUT" -j"$JOBS"

STM32_IMAGES=(
    "$STM32_OUT/images/stm32f429i-disco.bin"
    "$STM32_OUT/images/stm32f429-disco.dtb"
    "$STM32_OUT/images/xipImage"
)
for image in "${STM32_IMAGES[@]}"; do check_file_nonempty "$image"; done

VMLINUX="$STM32_OUT/build/linux-$EXPECTED_LINUX_VERSION/vmlinux"
KERNEL_CONFIG="$STM32_OUT/build/linux-$EXPECTED_LINUX_VERSION/.config"
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

printf '\nImages STM32 générées :\n'
find "$STM32_OUT/images" -maxdepth 1 -type f -printf '  %-38f %10s octets\n' | sort

section "9. Construction complète QEMU ARM VExpress"

run_with_log "$LOG_DIR/build-qemu-$TIMESTAMP.log" \
    make_br "$QEMU_OUT" -j"$JOBS"

QEMU_IMAGES=(
    "$QEMU_OUT/images/zImage"
    "$QEMU_OUT/images/vexpress-v2p-ca9.dtb"
    "$QEMU_OUT/images/rootfs.ext2"
)
for image in "${QEMU_IMAGES[@]}"; do check_file_nonempty "$image"; done
check_file_nonempty "$QEMU_OUT/host/bin/qemu-system-arm"
file "$QEMU_OUT/host/bin/qemu-system-arm"
ok "cible QEMU et émulateur hôte construits"

printf '\nImages QEMU générées :\n'
find "$QEMU_OUT/images" -maxdepth 1 -type f -printf '  %-38f %10s octets\n' | sort

QEMU_BOOT_OK="non testé"
if ((SKIP_QEMU_TEST == 0)); then
    section "10. Test de démarrage QEMU"
    QEMU_BOOT_LOG="$LOG_DIR/qemu-boot-$TIMESTAMP.log"
    set +e
    timeout --signal=TERM --kill-after=5s 90s \
        "$QEMU_OUT/host/bin/qemu-system-arm" \
        -M vexpress-a9 \
        -smp 1 \
        -m 256 \
        -kernel "$QEMU_OUT/images/zImage" \
        -dtb "$QEMU_OUT/images/vexpress-v2p-ca9.dtb" \
        -drive "file=$QEMU_OUT/images/rootfs.ext2,if=sd,format=raw" \
        -append "console=ttyAMA0,115200 rootwait root=/dev/mmcblk0" \
        -display none \
        -monitor none \
        -serial stdio \
        -net nic,model=lan9118 \
        -net user \
        >"$QEMU_BOOT_LOG" 2>&1
    QEMU_RC=$?
    set -e

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
