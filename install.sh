#!/data/data/com.termux/files/usr/bin/bash

set -u

# ============================================================
#              JEPH DIGITALHUB APK BUILDER
# ============================================================

GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
WHITE='\033[1;37m'
RESET='\033[0m'

# ============================================================
#                    AFFICHAGE
# ============================================================

stage() {
    echo
    printf '%b\n' "${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
    printf '%b\n' "${CYAN}║  [$1/08] $2                                      ║${RESET}"
    printf '%b\n' "${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
}

info() {
    printf '%b\n' "  ${CYAN}↳${RESET} $1"
}

ok() {
    printf '%b\n' "  ${GREEN}✓${RESET} $1"
}

warn() {
    printf '%b\n' "  ${YELLOW}!${RESET} $1"
}

fail() {
    printf '%b\n' "  ${RED}✗${RESET} $1"
    exit 1
}

# ============================================================
#                  BARRE DE PROGRESSION
# ============================================================

draw_bar() {
    local pct="$1"
    local width=24
    local filled=$((pct * width / 100))
    local empty=$((width - filled))
    local bar=""
    local i

    for ((i=0; i<filled; i++)); do
        bar+="█"
    done

    for ((i=0; i<empty; i++)); do
        bar+="░"
    done

    printf "\r  [%s] %3d%%" "$bar" "$pct"
}

progress_filter() {
    local last="-1"
    local value

    while IFS= read -r value; do
        value="${value%\%}"

        [[ "$value" =~ ^[0-9]{1,3}$ ]] || continue

        if [ "$value" != "$last" ]; then
            draw_bar "$value"
            last="$value"
        fi
    done
}

# ============================================================
#             TÉLÉCHARGEMENT AVEC POURCENTAGE
# ============================================================

download_clean() {
    local label="$1"
    local url="$2"
    local output="$3"
    local status

    echo
    info "$label"

    set +e

    wget --progress=bar:force:noscroll \
        -O "$output" \
        "$url" 2>&1 |
        stdbuf -o0 tr '\r' '\n' |
        grep --line-buffered -oE '[0-9]{1,3}%' |
        progress_filter

    status=${PIPESTATUS[0]}

    set -e

    if [ "$status" -ne 0 ]; then
        printf "\n"
        fail "$label a échoué."
    fi

    draw_bar 100
    printf "\n"
    ok "$label terminé."
}

# ============================================================
#                       EN-TÊTE
# ============================================================

clear

printf '%b\n' "${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
printf '%b\n' "${CYAN}║                                                    ║${RESET}"
printf '%b\n' "${CYAN}║              JJJJJ  EEEEE  PPPP   H  H            ║${RESET}"
printf '%b\n' "${CYAN}║                J    E      P   P  H  H            ║${RESET}"
printf '%b\n' "${CYAN}║                J    EEEE   PPPP   HHHH            ║${RESET}"
printf '%b\n' "${CYAN}║             J  J    E      P      H  H            ║${RESET}"
printf '%b\n' "${CYAN}║              JJ     EEEEE  P      H  H            ║${RESET}"
printf '%b\n' "${CYAN}║                                                    ║${RESET}"
printf '%b\n' "${CYAN}║             DIGITALHUB APK BUILDER                 ║${RESET}"
printf '%b\n' "${CYAN}║                                                    ║${RESET}"
printf '%b\n' "${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"

echo
printf '%b\n' "${WHITE}  Installation de l'environnement APK Builder${RESET}"
printf '%b\n' "${CYAN}  DigitalHub • Jeph Ouedraogo${RESET}"

# ============================================================
# [01/08] TERMUX
# ============================================================

stage "01" "TERMUX"

info "Vérification de Termux..."

if command -v pkg >/dev/null 2>&1; then
    ok "Termux détecté."
else
    fail "Ce script doit être exécuté dans Termux."
fi

info "Mise à jour des dépôts Termux..."

pkg update -y >/dev/null 2>&1 || true
pkg upgrade -y >/dev/null 2>&1 || true

ok "Termux prêt."

# ============================================================
# [02/08] OUTILS TERMUX
# ============================================================

stage "02" "OUTILS TERMUX"

info "Vérification des outils nécessaires..."

PACKAGES="proot-distro wget curl unzip tar git nano"

for package in $PACKAGES; do
    if ! command -v "$package" >/dev/null 2>&1; then
        info "Installation de $package..."

        pkg install -y "$package" >/dev/null 2>&1 ||
            fail "Impossible d'installer $package."
    fi
done

ok "Outils Termux disponibles."

# ============================================================
# [03/08] UBUNTU
# ============================================================

stage "03" "UBUNTU"

info "Vérification d'Ubuntu..."

if proot-distro login ubuntu -- echo "UBUNTU_OK" >/dev/null 2>&1; then
    ok "Ubuntu déjà installé et fonctionnel."
else
    info "Téléchargement et installation d'Ubuntu..."

    proot-distro install ubuntu >/dev/null 2>&1 ||
        fail "Installation d'Ubuntu impossible."

    ok "Ubuntu installé."
fi

# ============================================================
# [04/08] STOCKAGE
# ============================================================

stage "04" "STOCKAGE"

if [ -d "$HOME/storage/downloads" ]; then
    ok "Accès au stockage déjà configuré."
else
    info "Configuration de l'accès au stockage..."

    termux-setup-storage >/dev/null 2>&1 || true

    sleep 2

    if [ -d "$HOME/storage/downloads" ]; then
        ok "Stockage configuré."
    else
        warn "Autorisation du stockage nécessaire."
    fi
fi

# ============================================================
# [05/08] JAVA 17
# ============================================================

stage "05" "JAVA 17"

info "Vérification de Java..."

if proot-distro login ubuntu -- bash -c \
    'command -v java >/dev/null 2>&1 && java -version 2>&1 | grep -q "17\."'
then
    ok "Java 17 installé."
else
    info "Installation de Java 17..."

    proot-distro login ubuntu -- bash -c '
        export DEBIAN_FRONTEND=noninteractive

        apt-get update -qq
        apt-get install -y -qq openjdk-17-jdk
    ' >/dev/null 2>&1 ||
        fail "Installation de Java 17 impossible."

    ok "Java 17 installé."
fi

info "Vérification de Java..."

proot-distro login ubuntu -- bash -c \
    'java -version 2>&1 | head -n 1' 2>/dev/null

ok "Java fonctionne."

# ============================================================
# [06/08] ANDROID SDK
# ============================================================

stage "06" "ANDROID SDK"

SDK_DIR="/root/android-sdk"

info "Vérification des Android Command-line Tools..."

if proot-distro login ubuntu -- bash -c \
    "[ -x '$SDK_DIR/cmdline-tools/latest/bin/sdkmanager' ]" \
    >/dev/null 2>&1
then
    ok "Android Command-line Tools déjà présents."
else
    info "Préparation du dossier Android SDK..."

    proot-distro login ubuntu -- bash -c '
        mkdir -p /root/android-sdk/cmdline-tools
    ' || fail "Impossible de préparer Android SDK."

    info "Téléchargement des Android Command-line Tools..."

    proot-distro login ubuntu -- bash -c '
        wget \
        --progress=bar:force:noscroll \
        -O /tmp/commandlinetools.zip \
        "https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip"
    ' 2>&1 |
        stdbuf -o0 tr '\r' '\n' |
        grep --line-buffered -oE '[0-9]{1,3}%' |
        progress_filter

    DOWNLOAD_STATUS=${PIPESTATUS[0]}

    if [ "$DOWNLOAD_STATUS" -ne 0 ]; then
        printf "\n"
        fail "Téléchargement des Android Command-line Tools impossible."
    fi

    draw_bar 100
    printf "\n"
    ok "Téléchargement terminé."

    proot-distro login ubuntu -- bash -c '
        set -e

        rm -rf /root/android-sdk/cmdline-tools/latest
        mkdir -p /root/android-sdk/cmdline-tools/latest

        rm -rf /tmp/android-cmdline

        unzip -q /tmp/commandlinetools.zip \
            -d /tmp/android-cmdline

        cp -r /tmp/android-cmdline/cmdline-tools/* \
            /root/android-sdk/cmdline-tools/latest/

        rm -rf /tmp/android-cmdline
        rm -f /tmp/commandlinetools.zip
    ' || fail "Installation des Command-line Tools impossible."

    ok "Android Command-line Tools installés."
fi

# ============================================================
# VARIABLES ANDROID
# ============================================================

export ANDROID_HOME="$SDK_DIR"
export ANDROID_SDK_ROOT="$SDK_DIR"
export PATH="$SDK_DIR/cmdline-tools/latest/bin:$SDK_DIR/platform-tools:$PATH"

# ============================================================
# LICENCES ANDROID
# ============================================================

echo
info "Vérification des licences Android..."

set +e

proot-distro login ubuntu -- bash -c '
    export ANDROID_HOME=/root/android-sdk
    export ANDROID_SDK_ROOT=/root/android-sdk
    export PATH=/root/android-sdk/cmdline-tools/latest/bin:/root/android-sdk/platform-tools:$PATH

    yes | sdkmanager --licenses >/dev/null 2>&1
'

LICENSE_STATUS=$?

set -e

if [ "$LICENSE_STATUS" -ne 0 ]; then
    fail "Impossible de vérifier les licences Android."
fi

draw_bar 100
printf "\n"
ok "Licences Android vérifiées."

# ============================================================
# PLATFORM TOOLS
# ============================================================

echo
info "Vérification de Platform Tools..."

if proot-distro login ubuntu -- bash -c \
    "[ -x /root/android-sdk/platform-tools/adb ]" \
    >/dev/null 2>&1
then
    ok "Platform Tools déjà installés."
else
    info "Installation de Platform Tools..."

    proot-distro login ubuntu -- bash -c '
        export ANDROID_HOME=/root/android-sdk
        export ANDROID_SDK_ROOT=/root/android-sdk
        export PATH=/root/android-sdk/cmdline-tools/latest/bin:/root/android-sdk/platform-tools:$PATH

        yes | sdkmanager "platform-tools" >/dev/null 2>&1
    '

    STATUS=$?

    if [ "$STATUS" -ne 0 ]; then
        fail "Installation de Platform Tools impossible."
    fi

    draw_bar 100
    printf "\n"
    ok "Platform Tools installés."
fi

# ============================================================
# ANDROID PLATFORM 35
# ============================================================

echo
info "Vérification d'Android Platform 35..."

if proot-distro login ubuntu -- bash -c \
    "[ -d /root/android-sdk/platforms/android-35 ]" \
    >/dev/null 2>&1
then
    ok "Android Platform 35 déjà installé."
else
    info "Installation d'Android Platform 35..."

    proot-distro login ubuntu -- bash -c '
        export ANDROID_HOME=/root/android-sdk
        export ANDROID_SDK_ROOT=/root/android-sdk
        export PATH=/root/android-sdk/cmdline-tools/latest/bin:/root/android-sdk/platform-tools:$PATH

        yes | sdkmanager "platforms;android-35" >/dev/null 2>&1
    '

    STATUS=$?

    if [ "$STATUS" -ne 0 ]; then
        fail "Installation d'Android Platform 35 impossible."
    fi

    draw_bar 100
    printf "\n"
    ok "Android Platform 35 installé."
fi

# ============================================================
# BUILD TOOLS 35.0.0
# ============================================================

echo
info "Vérification de Build Tools 35.0.0..."

if proot-distro login ubuntu -- bash -c \
    "[ -d /root/android-sdk/build-tools/35.0.0 ]" \
    >/dev/null 2>&1
then
    ok "Build Tools 35.0.0 déjà installés."
else
    info "Installation de Build Tools 35.0.0..."

    proot-distro login ubuntu -- bash -c '
        export ANDROID_HOME=/root/android-sdk
        export ANDROID_SDK_ROOT=/root/android-sdk
        export PATH=/root/android-sdk/cmdline-tools/latest/bin:/root/android-sdk/platform-tools:$PATH

        yes | sdkmanager "build-tools;35.0.0" >/dev/null 2>&1
    '

    STATUS=$?

    if [ "$STATUS" -ne 0 ]; then
        fail "Installation de Build Tools 35.0.0 impossible."
    fi

    draw_bar 100
    printf "\n"
    ok "Build Tools 35.0.0 installés."
fi

# ============================================================
# [07/08] GRADLE 8.7
# ============================================================

stage "07" "GRADLE 8.7"

GRADLE_DIR="/root/gradle-8.7"

if proot-distro login ubuntu -- bash -c \
    "[ -x '$GRADLE_DIR/bin/gradle' ]" \
    >/dev/null 2>&1
then
    ok "Gradle 8.7 installé."
else
    info "Téléchargement de Gradle 8.7..."

    proot-distro login ubuntu -- bash -c '
        wget \
        --progress=bar:force:noscroll \
        -O /tmp/gradle-8.7-bin.zip \
        "https://services.gradle.org/distributions/gradle-8.7-bin.zip"
    ' 2>&1 |
        stdbuf -o0 tr '\r' '\n' |
        grep --line-buffered -oE '[0-9]{1,3}%' |
        progress_filter

    DOWNLOAD_STATUS=${PIPESTATUS[0]}

    if [ "$DOWNLOAD_STATUS" -ne 0 ]; then
        printf "\n"
        fail "Téléchargement de Gradle 8.7 impossible."
    fi

    draw_bar 100
    printf "\n"
    ok "Téléchargement terminé."

    proot-distro login ubuntu -- bash -c '
        set -e

        rm -rf /root/gradle-8.7

        unzip -q /tmp/gradle-8.7-bin.zip -d /root

        rm -f /tmp/gradle-8.7-bin.zip
    ' || fail "Installation de Gradle 8.7 impossible."

    ok "Gradle 8.7 installé."
fi

# ============================================================
# [08/08] VÉRIFICATION
# ============================================================

stage "08" "VÉRIFICATION"

ok "Termux"

if proot-distro login ubuntu -- echo "OK" >/dev/null 2>&1; then
    ok "Ubuntu"
fi

if proot-distro login ubuntu -- bash -c \
    'java -version 2>&1 | grep -q "17\."'
then
    ok "Java 17"
fi

if proot-distro login ubuntu -- bash -c \
    '[ -d /root/android-sdk/platforms/android-35 ]'
then
    ok "Android SDK 35"
else
    warn "Android SDK non installé."
fi

if proot-distro login ubuntu -- bash -c \
    '[ -d /root/android-sdk/build-tools/35.0.0 ]'
then
    ok "Build Tools 35.0.0"
else
    warn "Build Tools non installés."
fi

if proot-distro login ubuntu -- bash -c \
    '[ -x /root/gradle-8.7/bin/gradle ]'
then
    ok "Gradle 8.7"
else
    warn "Gradle 8.7 non installé."
fi

# ============================================================
#                 SYSTEM PROGRESS
# ============================================================

echo

printf '%b\n' "${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
printf '%b\n' "${CYAN}║                                                    ║${RESET}"
printf '%b\n' "${CYAN}║              DIGITALHUB                            ║${RESET}"
printf '%b\n' "${CYAN}║              SYSTEM PROGRESS                       ║${RESET}"
printf '%b\n' "${CYAN}║                                                    ║${RESET}"
printf '%b\n' "${CYAN}╠══════════════════════════════════════════════════════╣${RESET}"
printf '%b\n' "${CYAN}║                                                    ║${RESET}"
printf '%b\n' "${CYAN}║   ✓ TERMUX                                        ║${RESET}"
printf '%b\n' "${CYAN}║   ✓ UBUNTU                                        ║${RESET}"
printf '%b\n' "${CYAN}║   ✓ JAVA 17                                       ║${RESET}"
printf '%b\n' "${CYAN}║   ✓ ANDROID SDK 35                                ║${RESET}"
printf '%b\n' "${CYAN}║   ✓ BUILD TOOLS 35.0.0                            ║${RESET}"
printf '%b\n' "${CYAN}║   ✓ GRADLE 8.7                                    ║${RESET}"
printf '%b\n' "${CYAN}║                                                    ║${RESET}"
printf '%b\n' "${CYAN}╠══════════════════════════════════════════════════════╣${RESET}"
printf '%b\n' "${CYAN}║                                                    ║${RESET}"
printf '%b\n' "${CYAN}║   PROCHAINE ÉTAPE                                  ║${RESET}"
printf '%b\n' "${CYAN}║   ANDROID APK BUILD                                ║${RESET}"
printf '%b\n' "${CYAN}║                                                    ║${RESET}"
printf '%b\n' "${CYAN}╠══════════════════════════════════════════════════════╣${RESET}"
printf '%b\n' "${CYAN}║                                                    ║${RESET}"
printf '%b\n' "${CYAN}║   Créé par : Jeph Ouedraogo                       ║${RESET}"
printf '%b\n' "${CYAN}║   DIGITALHUB APK BUILDER                           ║${RESET}"
printf '%b\n' "${CYAN}║                                                    ║${RESET}"
printf '%b\n' "${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"

echo
printf '%b\n' "${WHITE}             BUILD • CREATE • SHIP 🚀${RESET}"
echo
