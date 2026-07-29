#!/usr/bin/env bash
#
# Étape 1 : validation de l'hôte et création de l'environnement de travail.

set -Eeuo pipefail
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=uclinux_common.sh
source "$SCRIPT_DIR/uclinux_common.sh"

: "${SKIP_APT:=0}"
: "${ALLOW_OTHER_RELEASE:=0}"

require_cmd() {
    local __fn="${FUNCNAME[0]}"

    debug_enter "$__fn"
    command -v "$1" >/dev/null 2>&1 || die "commande absente : $1"
    debug_exit "$__fn" 0
}

create_minicom_acm0_profile() {
    local profile=${1:-"$HOME/.minirc.acm0"}

    cat >"$profile" <<'MINICOMEOF'
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

configure_serial_access() {
    local current_user

    current_user="$(id -un)"
    if ! getent group dialout >/dev/null 2>&1; then
        warn "groupe dialout absent : accès automatique aux ports série non configuré."
        return 0
    fi

    if id -nG "$current_user" | grep -qw dialout; then
        ok "utilisateur $current_user membre du groupe dialout"
        return 0
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo usermod -aG dialout "$current_user"
        warn "utilisateur $current_user ajouté au groupe dialout."
        warn "Fermez puis rouvrez la session avant d'utiliser la console série."
    else
        warn "sudo absent : ajoutez $current_user au groupe dialout avant d'utiliser la console série."
    fi
}

uclinux_step_setup_validation() {
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

    FREE_KIB="$(df -Pk "$WORK_ROOT" | awk 'NR==2 {print $4}')"
    FREE_GIB=$((FREE_KIB / 1024 / 1024))
    ((FREE_GIB >= 25)) \
        || die "espace libre insuffisant sur le système de fichiers de $WORK_ROOT : ${FREE_GIB} Gio ; prévoyez au moins 25 Gio."
    ok "espace libre sur le système de fichiers de $WORK_ROOT : environ ${FREE_GIB} Gio"

    section "2. Installation des outils Ubuntu"

    APT_PACKAGES=(
        build-essential binutils git wget curl ca-certificates
        rsync cpio unzip bzip2 gzip xz-utils tar patch perl bc
        file findutils gawk sed diffutils coreutils
        python3 libncurses-dev bison flex libssl-dev libelf-dev
        device-tree-compiler usbutils
        openssh-server iproute2 time locales minicom
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

    for cmd in gcc g++ make git wget rsync cpio file bc python3 bison flex dtc ssh sshd readelf timeout sha256sum script minicom; do
        require_cmd "$cmd"
    done
    ok "outils fondamentaux présents"

    printf 'gcc       : '; gcc --version | head -n1
    printf 'make      : '; make --version | head -n1
    printf 'git       : '; git --version
    printf 'DTC       : '; dtc --version
    printf 'Minicom   : '; minicom --version | head -n1
    MINICOM_PROFILE="$(create_minicom_acm0_profile)"
    ok "profil minicom créé : minicom acm0 -> /dev/ttyACM0, 115200 8N1 ($MINICOM_PROFILE)"
    configure_serial_access
    [[ -x "$SCRIPT_DIR/connect_stm32_console.sh" ]] \
        || die "script de console STM32 absent ou non exécutable : $SCRIPT_DIR/connect_stm32_console.sh"
    ok "console STM32 : $SCRIPT_DIR/connect_stm32_console.sh"

    section "3. Accès SSH depuis l'hôte"

    if command -v systemctl >/dev/null 2>&1; then
        if command -v sudo >/dev/null 2>&1; then
            sudo systemctl enable --now ssh
            systemctl is-active --quiet ssh || die "le service SSH n'est pas actif."
            ok "service SSH actif et activé au démarrage"
        else
            warn "sudo absent : activation automatique de SSH non vérifiée."
        fi
    else
        warn "systemctl absent : activation automatique de SSH non vérifiée."
    fi

    if ss -ltn 2>/dev/null | grep -Eq ':[[:space:]]*22\b|:22[[:space:]]'; then
        ok "un serveur écoute sur le port TCP 22"
    else
        warn "le port TCP 22 n'a pas été détecté ; vérifiez 'systemctl status ssh'."
    fi

    section "4. Arborescence de travail"

    uclinux_ensure_workspace_dirs
    CURRENT_USER="${USER:-${LOGNAME:-utilisateur}}"
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

    cat > "$DOCS_DIR/acces-depuis-hote.txt" <<HOSTEOF
Accès recommandé depuis macOS/Windows/Linux
============================================

1. Dans VirtualBox, conservez l'adaptateur réseau en mode NAT.
2. Ajoutez une redirection de port :
     hôte 127.0.0.1:2222  ->  invité :22/TCP

Commande à exécuter sur l'hôte :
     ssh -p 2222 ${CURRENT_USER}@127.0.0.1

Entrée possible dans ~/.ssh/config sur l'hôte :

Host uclinux-vm
    HostName 127.0.0.1
    User ${CURRENT_USER}
    Port 2222

Dans VS Code :
  - installer l'extension « Remote - SSH » ;
  - se connecter à « uclinux-vm » ;
  - ouvrir le dossier ${WORK_ROOT}.

Console série STM32F429I-DISC1 :
  - PA9 est connecté sur RX du lien USB-TTL
  - PA10 est connecté sur TX du lien USB-TTL
  - carte GND sur GND USB-TTL
  - lancer : $SCRIPT_DIR/connect_stm32_console.sh
  - profil généré : $HOME/.minirc.acm0 (/dev/ttyACM0, 115200 8N1)
  - quitter minicom : Ctrl-A puis X.

Le projet Buildroot doit rester sur le disque Linux de la VM,
pas dans un dossier partagé VirtualBox.
HOSTEOF

    ok "racine de travail : $WORK_ROOT"
    printf '%s\n' \
        "  buildroot/   sources Buildroot" \
        "  downloads/   cache des archives téléchargées" \
        "  outputs/     sorties séparées par cible" \
        "  labs/        travaux étudiants" \
        "  documents/   fiches d'utilisation" \
        "  logs/        journaux et rapports"
    ok "fiche d'accès créée : $DOCS_DIR/acces-depuis-hote.txt"
}

usage() {
    cat <<'USAGE'
Étape 1 : validation de l'hôte et création de l'environnement de travail.

Utilisation :
  ./1_setup_validation.sh [options]

Options :
  --root CHEMIN              Racine de travail, défaut : $UCLINUX_ROOT ou $HOME/uclinux
  --skip-apt                 Ne pas installer les paquets Ubuntu
  --allow-other-release      Accepter une version Ubuntu autre que 24.04
  --quiet                    Masquer la sortie verbeuse des commandes longues
  --debug                    Tracer l'entrée et la sortie des fonctions
  -h, --help                 Afficher cette aide
USAGE
}

while (($#)); do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || { echo "ERREUR : --root attend un chemin." >&2; exit 2; }
            WORK_ROOT=$2
            shift 2
            ;;
        --skip-apt) SKIP_APT=1; shift ;;
        --allow-other-release) ALLOW_OTHER_RELEASE=1; shift ;;
        --quiet) QUIET=1; shift ;;
        --debug) DEBUG_TRACE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERREUR : option inconnue : $1" >&2; usage; exit 2 ;;
    esac
done

uclinux_begin_logging setup-validation
uclinux_step_setup_validation
section "Étape 1 terminée"
ok "validation de l'hôte terminée"
