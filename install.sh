#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#              JEPH DIGITALHUB APK BUILDER  (v3)
# ------------------------------------------------------------
# Nouveautés par rapport à la v2 :
#  - durée estimée affichée dans l'en-tête (Essentiel : max 1h,
#    Complet : max 1h30) + temps écoulé à chaque étape
#  - deux profils : 1) Essentiel  2) Complet (outils en plus)
#  - correction des cadres (tr ne gère pas les caractères UTF-8)
#  - alignement des cadres correct avec les accents
#  - pkg upgrade non interactif (ne se bloque plus)
#  - APT corrigé pour proot (sandbox root) + retries réseau
#  - wake-lock Termux : le téléphone ne coupe plus l'install
#  - vérification Internet + espace disque avant de commencer
#  - Ctrl+C propre, ancien log conservé (.old)
#  - ARM64 n'est plus un "warning" : seulement un vrai problème
#  - outils en plus : Node.js, npm, Cordova, Capacitor,
#    ImageMagick, jq, Python 3, rsync, apktool, Platform 34
#  - commandes prêtes à l'emploi : dh-new, dh-build et dh-key
# ============================================================

set -u

SDK_DIR="/root/android-sdk"
GRADLE_DIR="/root/gradle-8.7"
PLATFORM="android-35"
BT_VER="35.0.0"
BT_DIR="$SDK_DIR/build-tools/$BT_VER"
LOG_FILE="$HOME/digitalhub-install.log"
TOTAL_STAGES=10
START_TS="$(date +%s)"
PROFILE=""

GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
WHITE='\033[1;37m'
RESET='\033[0m'

[ -s "$LOG_FILE" ] && mv -f "$LOG_FILE" "$LOG_FILE.old"
: > "$LOG_FILE"

# ============================================================
#                    AFFICHAGE RESPONSIVE
#  Tout est calculé selon la largeur réelle de l'écran : aucune
#  ligne ne dépasse, donc rien ne "retombe" en bas du téléphone.
#  Terminal sans UTF-8, ou DH_ASCII=1 : mode ASCII (compatible
#  avec tous les téléphones et toutes les polices).
# ============================================================

UTEST='é'
if [ "${DH_ASCII:-0}" != "1" ] && [ "${#UTEST}" -eq 1 ]; then
    UNI=1
    TL='╔'; TR='╗'; BL='╚'; BR='╝'; HL='═'; VL='║'
    S_OK='✓'; S_ERR='✗'; S_INFO='↳'; S_WARN='!'
    B_FULL='█'; B_EMPTY='░'; ELL='…'; DOT='•'
else
    UNI=0
    TL='+'; TR='+'; BL='+'; BR='+'; HL='-'; VL='|'
    S_OK='+'; S_ERR='x'; S_INFO='>'; S_WARN='!'
    B_FULL='#'; B_EMPTY='.'; ELL='~'; DOT='-'
fi

# Retire les accents (mode ASCII uniquement).
deaccent() {
    local t="$1" p
    for p in 'é:e' 'è:e' 'ê:e' 'ë:e' 'à:a' 'â:a' 'ä:a' 'î:i' 'ï:i' 'ô:o' 'ö:o' \
             'ù:u' 'û:u' 'ü:u' 'ç:c' 'É:E' 'È:E' 'Ê:E' 'À:A' 'Ç:C' "’:'"; do
        t="${t//${p%%:*}/${p##*:}}"
    done
    printf '%s' "$t"
}

norm() {
    if [ "$UNI" -eq 1 ]; then printf '%s' "$1"; else deaccent "$1"; fi
}

# Largeur réelle du terminal (lue sur /dev/tty, sinon 40 par prudence).
term_width() {
    local cols=""
    cols="$(stty size 2>/dev/null </dev/tty | awk '{print $2}')"
    [[ "$cols" =~ ^[0-9]+$ ]] && (( cols > 0 )) || cols="${COLUMNS:-}"
    [[ "$cols" =~ ^[0-9]+$ ]] && (( cols > 0 )) || cols="$(tput cols 2>/dev/null </dev/tty)"
    [[ "$cols" =~ ^[0-9]+$ ]] && (( cols > 0 )) || cols=40
    printf '%s' "$cols"
}

# Largeur d'un cadre : 4 colonnes de marge pour ne jamais toucher le bord.
box_width() {
    local width=$(( $(term_width) - 4 ))
    (( width > 56 )) && width=56
    (( width < 20 )) && width=20
    printf '%s' "$width"
}

fit_text() {
    local text="$1"
    local max="$2"
    if (( ${#text} > max )); then
        printf '%s' "${text:0:max-1}${ELL}"
    else
        printf '%s' "$text"
    fi
}

# Découpe un texte en lignes (par mots) de largeur maximale $1 -> tableau WRAP_OUT.
wrap_text() {
    local width="$1" text="$2" line="" word
    local -a words=()
    WRAP_OUT=()
    (( width < 4 )) && width=4
    IFS=' ' read -r -a words <<< "$text"
    for word in "${words[@]+"${words[@]}"}"; do
        while (( ${#word} > width )); do
            [ -n "$line" ] && { WRAP_OUT+=("$line"); line=""; }
            WRAP_OUT+=("${word:0:width}")
            word="${word:width}"
        done
        if [ -z "$line" ]; then
            line="$word"
        elif (( ${#line} + 1 + ${#word} <= width )); then
            line="$line $word"
        else
            WRAP_OUT+=("$line")
            line="$word"
        fi
    done
    WRAP_OUT+=("$line")
}

# Répète un caractère (compatible UTF-8, contrairement à tr).
line_chars() {
    local char="$1" count="$2" s="" i
    (( count < 1 )) && count=1
    for ((i=0; i<count; i++)); do s+="$char"; done
    printf '%s' "$s"
}

box_top() {
    printf '%b\n' "${CYAN}${TL}$(line_chars "$HL" $(($1-2)))${TR}${RESET}"
}

box_bottom() {
    printf '%b\n' "${CYAN}${BL}$(line_chars "$HL" $(($1-2)))${BR}${RESET}"
}

# Ligne de cadre : le texte long passe à la ligne DANS le cadre.
# Remplissage manuel : printf %-*s compte des octets, pas des caractères.
box_line() {
    local text="$1" width="$2" inner i pad
    inner=$((width - 4))
    wrap_text "$inner" "$(norm "$text")"
    for i in "${!WRAP_OUT[@]}"; do
        pad=$((inner - ${#WRAP_OUT[$i]}))
        (( pad < 0 )) && pad=0
        printf '%b %s' "${CYAN}${VL}${RESET}" "${WRAP_OUT[$i]}"
        printf '%*s' "$pad" ''
        printf '%b\n' " ${CYAN}${VL}${RESET}"
    done
}

# Ligne de cadre sans retour à la ligne (dessin ASCII).
box_raw() {
    local text width="$2" inner pad
    inner=$((width - 4))
    text="$(fit_text "$(norm "$1")" "$inner")"
    pad=$((inner - ${#text}))
    (( pad < 0 )) && pad=0
    printf '%b %s' "${CYAN}${VL}${RESET}" "$text"
    printf '%*s' "$pad" ''
    printf '%b\n' " ${CYAN}${VL}${RESET}"
}

fmt_dur() {
    local s="$1" h m
    h=$((s / 3600)); m=$(((s % 3600) / 60)); s=$((s % 60))
    if (( h > 0 )); then
        printf '%dh%02dmin' "$h" "$m"
    elif (( m > 0 )); then
        printf '%dmin%02ds' "$m" "$s"
    else
        printf '%ds' "$s"
    fi
}

elapsed() { fmt_dur $(( $(date +%s) - START_TS )); }

stage() {
    local width
    width="$(box_width)"
    echo
    box_top "$width"
    box_line "[$1/$TOTAL_STAGES] $2" "$width"
    box_line "Écoulé : $(elapsed)" "$width"
    box_bottom "$width"
    printf '\n=== [%s/%s] %s (écoulé %s) ===\n' "$1" "$TOTAL_STAGES" "$2" "$(elapsed)" >> "$LOG_FILE"
}

# Message à la ligne selon la largeur. say COULEUR SYMBOLE TEXTE
# (symbole vide = simple texte coloré).
say() {
    local color="$1" sym="$2" msg="$3" width i prefix
    width=$(( $(term_width) - 5 ))
    (( width < 12 )) && width=12
    wrap_text "$width" "$(norm "$msg")"
    for i in "${!WRAP_OUT[@]}"; do
        if [ -n "$sym" ]; then
            if [ "$i" -eq 0 ]; then
                prefix="  ${color}${sym}${RESET} "
            else
                prefix="    "
            fi
            printf '%b%s\n' "$prefix" "${WRAP_OUT[$i]}"
        else
            printf '%b%s%b\n' "  ${color}" "${WRAP_OUT[$i]}" "${RESET}"
        fi
    done
}

info() { say "$CYAN"   "$S_INFO" "$1"; }
ok()   { say "$GREEN"  "$S_OK"   "$1"; }
warn() { say "$YELLOW" "$S_WARN" "$1"; }
err()  { say "$RED"    "$S_ERR"  "$1"; }
note() { say "$1" "" "$2"; }

fail() {
    err "$1"
    note "$WHITE" "Détails : $LOG_FILE"
    exit 1
}

cleanup() {
    command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock >/dev/null 2>&1
    return 0
}

on_interrupt() {
    printf '\n'
    warn "Interrompu. Relance le script : il reprend là où il s'est arrêté."
    exit 130
}

trap cleanup EXIT
trap on_interrupt INT TERM

# ============================================================
#              SUIVI DES RÉSULTATS (OK / WARNING / ERROR)
# ============================================================

RES_NAMES=()
RES_STATES=()
RES_MSGS=()

record() {
    local name="$1" state="$2" msg="${3:-}"
    RES_NAMES+=("$name")
    RES_STATES+=("$state")
    RES_MSGS+=("$msg")
    case "$state" in
        OK)      ok   "$name${msg:+ : $msg}" ;;
        WARNING) warn "$name${msg:+ : $msg}" ;;
        *)       err  "$name${msg:+ : $msg}" ;;
    esac
}

# ============================================================
#                  BARRE DE PROGRESSION
# ============================================================

draw_bar() {
    local pct="$1"
    local cols width filled empty bar="" i

    cols="$(term_width)"
    width=$((cols - 14))
    (( width > 30 )) && width=30
    (( width < 8 )) && width=8

    filled=$((pct * width / 100))
    empty=$((width - filled))

    for ((i=0; i<filled; i++)); do bar+="$B_FULL"; done
    for ((i=0; i<empty; i++)); do bar+="$B_EMPTY"; done

    printf "\r  [%s] %3d%%" "$bar" "$pct"
}

progress_filter() {
    local last="-1"
    local value

    while IFS= read -r value; do
        value="${value%\%}"
        [[ "$value" =~ ^[0-9]{1,3}$ ]] || continue
        (( value > 100 )) && continue

        if [ "$value" != "$last" ]; then
            draw_bar "$value"
            last="$value"
        fi
    done
}

# ============================================================
#                  EXÉCUTION DANS UBUNTU
# ============================================================

# Environnement chargé avant chaque commande exécutée dans Ubuntu.
# La fonction runs() renvoie faux si le binaire est introuvable (127)
# ou incompatible avec l'architecture (126 : Exec format error).
read -r -d '' UB_ENV <<'EOF'
export DEBIAN_FRONTEND=noninteractive
export ANDROID_HOME=/root/android-sdk
export ANDROID_SDK_ROOT=/root/android-sdk
export PATH=/root/gradle-8.7/bin:/root/android-sdk/cmdline-tools/latest/bin:/root/android-sdk/platform-tools:/root/android-sdk/build-tools/35.0.0:$PATH
runs() { "$@" >/dev/null 2>&1; local rc=$?; [ $rc -ne 126 ] && [ $rc -ne 127 ]; }
EOF

# Exécute une commande dans Ubuntu (sortie visible, à rediriger si besoin).
ub() {
    proot-distro login ubuntu -- bash -c "${UB_ENV}"$'\n'"$1"
}

# Test silencieux dans Ubuntu.
ub_test() {
    ub "$1" >/dev/null 2>&1
}

# Écrit une propriété dans /root/.gradle/gradle.properties (remplace l'ancienne).
gradle_prop() {
    ub_test "mkdir -p /root/.gradle && touch /root/.gradle/gradle.properties && sed -i '/^$1=/d' /root/.gradle/gradle.properties && echo '$1=$2' >> /root/.gradle/gradle.properties"
}

SPIN='|/-\'

# Exécute une commande longue dans Ubuntu avec un spinner honnête
# (pas de faux pourcentage). La sortie complète va dans le log.
run_step() {
    local label="$1" cmd="$2" pid i=0 rc cols line

    printf '\n--- %s\n' "$label" >> "$LOG_FILE"
    ( ub "$cmd" >> "$LOG_FILE" 2>&1 ) &
    pid=$!
    cols="$(term_width)"

    # Une seule ligne, tronquée à la largeur de l'écran : jamais de retour à la ligne.
    while kill -0 "$pid" 2>/dev/null; do
        line="$(fit_text "$(norm "$label ($(elapsed))")" $((cols - 6)))"
        printf '\r\033[K  %s %s' "${SPIN:$((i % 4)):1}" "$line"
        i=$((i + 1))
        sleep 0.3
    done

    wait "$pid"
    rc=$?
    printf '\r\033[K'
    return $rc
}

# Téléchargement dans Ubuntu avec vrai pourcentage wget (5 essais).
download_ub() {
    local label="$1" url="$2" dest="$3" st

    info "$label"
    printf '\n--- download %s -> %s\n' "$url" "$dest" >> "$LOG_FILE"

    proot-distro login ubuntu -- wget \
        --tries=5 --timeout=30 --waitretry=3 \
        --progress=bar:force:noscroll \
        -O "$dest" "$url" 2>&1 |
        stdbuf -o0 tr '\r' '\n' |
        grep --line-buffered -oE '[0-9]{1,3}%' |
        progress_filter
    st=${PIPESTATUS[0]}

    if [ "$st" -ne 0 ] || ! ub_test "[ -s '$dest' ]"; then
        printf '\n'
        return 1
    fi

    draw_bar 100
    printf '\n'
    return 0
}

# ============================================================
#                  AUTHENTIFICATION
# ============================================================

# On ne stocke plus le mot de passe en clair, seulement son empreinte SHA-256.
# Pour le changer :  printf '%s' 'nouveau_mot_de_passe' | sha256sum
# Note : une empreinte publique reste attaquable par force brute si le mot
# de passe est faible. Choisis une phrase longue.
PASSWORD_SHA256="${INSTALL_PASSWORD_SHA256:-6f8fee2b604cb5c832dc42155bf5030008607627bb7b7ecc7b8e1a87692c08d8}"

authenticate() {
    local user_password hash attempt width
    width="$(box_width)"

    echo
    box_top "$width"
    box_line "AUTHENTIFICATION" "$width"
    box_line "" "$width"
    box_line "Mot de passe requis" "$width"
    box_bottom "$width"
    echo

    for attempt in 1 2 3; do
        printf "  Mot de passe : "
        read -r -s user_password
        printf "\n"

        hash="$(printf '%s' "$user_password" | sha256sum | cut -d' ' -f1)"
        unset user_password

        if [ "$hash" = "$PASSWORD_SHA256" ]; then
            ok "Authentification réussie."
            return 0
        fi

        warn "Mot de passe incorrect ($attempt/3)."
    done

    fail "Trop de tentatives. Installation annulée."
}

# ============================================================
#                  CHOIX DU PROFIL
# ============================================================

choose_profile() {
    local width choice
    PROFILE="${DH_PROFILE:-}"

    case "$PROFILE" in
        1|essentiel|Essentiel) PROFILE=1 ;;
        2|complet|Complet)     PROFILE=2 ;;
        *)
            width="$(box_width)"
            echo
            box_top "$width"
            box_line "CHOIX DE L'INSTALLATION" "$width"
            box_line "" "$width"
            box_line "1) Essentiel : max 1h" "$width"
            box_line "SDK, Java, Gradle" "$width"
            box_line "2) Complet : max 1h30" "$width"
            box_line "+ Node, Cordova, Capacitor," "$width"
            box_line "+ ImageMagick, apktool, API 34" "$width"
            box_bottom "$width"
            echo
            printf "  Ton choix [1/2] (défaut 2) : "
            read -r choice
            case "$choice" in
                1) PROFILE=1 ;;
                *) PROFILE=2 ;;
            esac
            ;;
    esac

    width="$(box_width)"
    echo
    box_top "$width"
    if [ "$PROFILE" = "1" ]; then
        box_line "Profil : ESSENTIEL" "$width"
        box_line "Durée maximale : 1h" "$width"
    else
        box_line "Profil : COMPLET" "$width"
        box_line "Durée maximale : 1h30" "$width"
    fi
    box_line "(selon ta connexion Internet)" "$width"
    box_bottom "$width"
    printf '\n=== Profil %s ===\n' "$PROFILE" >> "$LOG_FILE"
}

# ============================================================
#                       EN-TÊTE
# ============================================================

clear

WIDTH="$(box_width)"

box_top "$WIDTH"
box_line "" "$WIDTH"
if [ $((WIDTH - 4)) -ge 25 ]; then
    box_raw "JJJJJ  EEEEE  PPPP   H  H" "$WIDTH"
    box_raw "  J    E      P   P  H  H" "$WIDTH"
    box_raw "  J    EEEE   PPPP   HHHH" "$WIDTH"
    box_raw "J  J   E      P      H  H" "$WIDTH"
    box_raw " JJ    EEEEE  P      H  H" "$WIDTH"
else
    box_line "JEPH" "$WIDTH"
fi
box_line "" "$WIDTH"
box_line "DIGITALHUB APK BUILDER v3" "$WIDTH"
box_line "" "$WIDTH"
box_line "DURÉE ESTIMÉE DE L'INSTALLATION" "$WIDTH"
box_line "Essentiel : max 1h" "$WIDTH"
box_line "Complet   : max 1h30" "$WIDTH"
box_line "(selon ta connexion Internet)" "$WIDTH"
box_line "" "$WIDTH"
box_bottom "$WIDTH"

echo
note "$WHITE" "Installation de l'environnement APK Builder"
note "$CYAN" "DigitalHub $DOT Jeph Ouedraogo"

authenticate
choose_profile

# ============================================================
# [01/10] TERMUX
# ============================================================

stage "01" "TERMUX"

if ! command -v pkg >/dev/null 2>&1; then
    fail "Ce script doit être exécuté dans Termux."
fi

# Espace disque : l'installation complète occupe environ 5 Go.
FREE_KB="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
[[ "${FREE_KB:-}" =~ ^[0-9]+$ ]] || FREE_KB=0
FREE_GB=$((FREE_KB / 1024 / 1024))

if [ "$FREE_KB" -eq 0 ]; then
    record "Espace disque" "WARNING" "impossible à mesurer"
elif [ "$FREE_KB" -lt 4194304 ]; then
    fail "Espace insuffisant : ${FREE_GB} Go libres (minimum 4 Go, idéal 6 Go)."
elif [ "$FREE_KB" -lt 6291456 ]; then
    record "Espace disque" "WARNING" "${FREE_GB} Go libres (6 Go conseillés)"
else
    record "Espace disque" "OK" "${FREE_GB} Go libres"
fi

# Empêche Android d'endormir Termux pendant l'installation.
if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock >/dev/null 2>&1 && info "Wake-lock activé (le téléphone ne coupe pas Termux)."
fi

export DEBIAN_FRONTEND=noninteractive
info "Mise à jour des dépôts Termux..."
pkg update -y >> "$LOG_FILE" 2>&1 || warn "pkg update a signalé une erreur (voir log)."
apt-get -y -o Dpkg::Options::="--force-confnew" -o Dpkg::Options::="--force-confdef" upgrade >> "$LOG_FILE" 2>&1 \
    || warn "La mise à niveau a signalé une erreur (voir log)."

record "Termux" "OK" "prêt"

# ============================================================
# [02/10] OUTILS TERMUX
# ============================================================

stage "02" "OUTILS TERMUX"

MISSING_TOOLS=""
for tool in proot-distro wget curl unzip zip tar git nano stdbuf awk; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        info "Installation de $tool..."
        case "$tool" in
            stdbuf) pkgname="coreutils" ;;
            awk)    pkgname="gawk" ;;
            *)      pkgname="$tool" ;;
        esac
        if ! pkg install -y "$pkgname" >> "$LOG_FILE" 2>&1; then
            MISSING_TOOLS="$MISSING_TOOLS $tool"
        fi
    fi
done

if [ -n "$MISSING_TOOLS" ]; then
    fail "Impossible d'installer :$MISSING_TOOLS"
fi

record "Outils Termux" "OK" "disponibles"

if curl -fsI --max-time 20 https://dl.google.com >/dev/null 2>&1; then
    record "Connexion Internet" "OK" "dl.google.com joignable"
else
    fail "Pas de connexion Internet (dl.google.com injoignable)."
fi

# ============================================================
# [03/10] UBUNTU + ARCHITECTURE
# ============================================================

stage "03" "UBUNTU"

if proot-distro login ubuntu -- echo "UBUNTU_OK" >/dev/null 2>&1; then
    record "Ubuntu" "OK" "déjà installé et fonctionnel"
else
    info "Téléchargement et installation d'Ubuntu..."
    if proot-distro install ubuntu >> "$LOG_FILE" 2>&1 &&
       proot-distro login ubuntu -- echo "UBUNTU_OK" >/dev/null 2>&1
    then
        record "Ubuntu" "OK" "installé"
    else
        fail "Installation d'Ubuntu impossible."
    fi
fi

# APT dans proot : évite l'erreur "Couldn't drop privileges" et réessaie le réseau.
ub_test 'mkdir -p /etc/apt/apt.conf.d && printf "APT::Sandbox::User \"root\";\nAcquire::Retries \"3\";\n" > /etc/apt/apt.conf.d/99proot'

ARCH="$(ub 'uname -m' 2>/dev/null | tr -d '\r\n')"
IS_ARM=0

case "$ARCH" in
    aarch64|arm64)
        IS_ARM=1
        record "Architecture" "OK" "ARM64 (outils adaptés automatiquement)"
        ;;
    x86_64)
        record "Architecture" "OK" "x86_64"
        ;;
    *)
        record "Architecture" "WARNING" "inconnue ($ARCH)"
        ;;
esac

# ============================================================
# [04/10] STOCKAGE
# ============================================================

stage "04" "STOCKAGE"

if [ -d "$HOME/storage/downloads" ]; then
    record "Stockage" "OK" "accès déjà configuré"
else
    info "Configuration de l'accès au stockage..."
    termux-setup-storage >/dev/null 2>&1 || true
    sleep 2

    if [ -d "$HOME/storage/downloads" ]; then
        record "Stockage" "OK" "configuré"
    else
        record "Stockage" "WARNING" "autorisation du stockage nécessaire"
    fi
fi

# ============================================================
# [05/10] JAVA 17 + DÉPENDANCES UBUNTU
# ============================================================

stage "05" "JAVA 17"

java17_ok() {
    ub_test 'command -v java && command -v wget && command -v unzip && command -v zip && java -version 2>&1 | grep -q "version \"17"'
}

if java17_ok; then
    info "Java 17, wget, unzip et zip déjà présents."
else
    if ! run_step "Installation de Java 17 et des outils de base..." \
        'apt-get update -qq && apt-get install -y -qq openjdk-17-jdk wget unzip zip curl git ca-certificates'
    then
        fail "Installation de Java 17 impossible."
    fi
fi

if java17_ok; then
    JAVA_LINE="$(ub 'java -version 2>&1 | head -n 1' 2>/dev/null | tr -d '\r')"
    record "Java 17" "OK" "$JAVA_LINE"
else
    fail "Java 17 introuvable après installation."
fi

# ============================================================
# [06/10] ANDROID SDK
# ============================================================

stage "06" "ANDROID SDK"

# ---- Command-line Tools ----------------------------------------------------

info "Vérification des Android Command-line Tools..."

if ub_test "[ -x '$SDK_DIR/cmdline-tools/latest/bin/sdkmanager' ]"; then
    record "Command-line Tools" "OK" "déjà présents"
else
    CMDLINE_OK=0
    # Plusieurs builds possibles : on essaie jusqu'à ce qu'un téléchargement réussisse.
    for build in 15859902 13114758 11479570 11076708; do
        URL="https://dl.google.com/android/repository/commandlinetools-linux-${build}_latest.zip"
        if download_ub "Téléchargement des Command-line Tools ($build)..." "$URL" /tmp/cmdline.zip; then
            CMDLINE_OK=1
            break
        fi
        warn "Build $build indisponible, essai suivant..."
    done

    if [ "$CMDLINE_OK" -ne 1 ]; then
        fail "Téléchargement des Command-line Tools impossible."
    fi

    if run_step "Extraction des Command-line Tools..." "
        set -e
        unzip -tq /tmp/cmdline.zip >/dev/null
        rm -rf '$SDK_DIR/cmdline-tools/latest' /tmp/android-cmdline
        mkdir -p '$SDK_DIR/cmdline-tools'
        unzip -q /tmp/cmdline.zip -d /tmp/android-cmdline
        mv /tmp/android-cmdline/cmdline-tools '$SDK_DIR/cmdline-tools/latest'
        rm -rf /tmp/android-cmdline /tmp/cmdline.zip
    " && ub_test "[ -x '$SDK_DIR/cmdline-tools/latest/bin/sdkmanager' ]"
    then
        record "Command-line Tools" "OK" "installés"
    else
        fail "Installation des Command-line Tools impossible."
    fi
fi

# ---- Licences --------------------------------------------------------------

echo
info "Vérification des licences Android..."

licenses_ok() { ub_test "[ -s '$SDK_DIR/licenses/android-sdk-license' ]"; }

if ! licenses_ok; then
    # "Broken pipe" à la fin de yes | sdkmanager est normal :
    # on juge sur le fichier de licence, pas sur le code retour.
    run_step "Acceptation des licences..." \
        'yes | sdkmanager --sdk_root="$ANDROID_HOME" --licenses'
fi

if licenses_ok; then
    record "Licences SDK" "OK" "acceptées"
else
    record "Licences SDK" "ERROR" "fichier de licence absent (voir log)"
fi

# Installe un paquet sdkmanager (le code retour est ignoré, on vérifie les fichiers).
sdk_install() {
    run_step "Installation de $1..." \
        "yes | sdkmanager --sdk_root=\"\$ANDROID_HOME\" \"$1\""
}

# ---- Platform Tools --------------------------------------------------------

echo
info "Vérification de Platform Tools..."

if ! ub_test "[ -f '$SDK_DIR/platform-tools/adb' ]"; then
    ub_test "rm -rf '$SDK_DIR/platform-tools'"
    sdk_install "platform-tools"
fi

if ub_test "[ -f '$SDK_DIR/platform-tools/adb' ]"; then
    record "Platform Tools" "OK" "présents"
else
    record "Platform Tools" "ERROR" "adb absent après installation"
fi

# ---- Android Platform 35 ---------------------------------------------------

echo
info "Vérification d'Android Platform 35..."

platform_ok() { ub_test "[ -f '$SDK_DIR/platforms/$PLATFORM/android.jar' ]"; }

if ! platform_ok; then
    if ub_test "[ -d '$SDK_DIR/platforms/$PLATFORM' ]"; then
        warn "Dossier $PLATFORM incomplet (android.jar absent) : réparation."
        ub_test "rm -rf '$SDK_DIR/platforms/$PLATFORM'"
    fi
    sdk_install "platforms;$PLATFORM"
fi

if platform_ok; then
    record "Platform 35" "OK" "android.jar présent"
else
    record "Platform 35" "ERROR" "android.jar absent après installation"
fi

# ---- Build Tools 35.0.0 ----------------------------------------------------

echo
info "Vérification de Build Tools $BT_VER..."

buildtools_ok() {
    ub_test "for f in aapt2 zipalign apksigner d8; do [ -e '$BT_DIR'/\$f ] || exit 1; done"
}

if ! buildtools_ok; then
    if ub_test "[ -d '$BT_DIR' ]"; then
        warn "Build Tools $BT_VER incomplets : réparation."
        ub_test "rm -rf '$BT_DIR'"
    fi
    sdk_install "build-tools;$BT_VER"
fi

if buildtools_ok; then
    record "Build Tools $BT_VER" "OK" "fichiers présents"
else
    record "Build Tools $BT_VER" "ERROR" "outils manquants après installation"
fi

# ---- Composants SDK supplémentaires (profil Complet) -------------------------

if [ "$PROFILE" = "2" ]; then
    echo
    info "Composants SDK supplémentaires (Platform 34, Build Tools 34.0.0)..."

    if ! ub_test "[ -f '$SDK_DIR/platforms/android-34/android.jar' ]"; then
        ub_test "rm -rf '$SDK_DIR/platforms/android-34'"
        sdk_install "platforms;android-34"
    fi
    if ub_test "[ -f '$SDK_DIR/platforms/android-34/android.jar' ]"; then
        record "Platform 34" "OK" "android.jar présent"
    else
        record "Platform 34" "WARNING" "absent (optionnel)"
    fi

    if ! ub_test "[ -e '$SDK_DIR/build-tools/34.0.0/d8' ]"; then
        ub_test "rm -rf '$SDK_DIR/build-tools/34.0.0'"
        sdk_install "build-tools;34.0.0"
    fi
    if ub_test "[ -e '$SDK_DIR/build-tools/34.0.0/d8' ]"; then
        record "Build Tools 34.0.0" "OK" "fichiers présents"
    else
        record "Build Tools 34.0.0" "WARNING" "absents (optionnel)"
    fi
fi

# ---- Binaires natifs : compatibilité d'architecture -------------------------

echo
info "Test d'exécution des binaires Android..."

native_ok() { ub_test "runs '$1' $2"; }

NEED_REPAIR=0
native_ok "$BT_DIR/aapt2" version   || NEED_REPAIR=1
native_ok "$BT_DIR/zipalign" ""     || NEED_REPAIR=1
native_ok "$SDK_DIR/platform-tools/adb" version || NEED_REPAIR=1

if [ "$NEED_REPAIR" -eq 1 ] && [ "$IS_ARM" -eq 1 ]; then
    warn "Binaires x86_64 non exécutables sur ARM64 : remplacement par les versions apt."

    run_step "Installation de aapt, zipalign, adb (apt)..." '
        apt-get update -qq
        for p in aapt zipalign adb; do
            apt-get install -y -qq "$p" || echo "paquet $p indisponible"
        done
    '

    ub_test '
        for pair in "aapt2:$ANDROID_HOME/build-tools/35.0.0" \
                    "zipalign:$ANDROID_HOME/build-tools/35.0.0" \
                    "adb:$ANDROID_HOME/platform-tools"; do
            n="${pair%%:*}"; d="${pair#*:}"
            [ -x "/usr/bin/$n" ] && ln -sf "/usr/bin/$n" "$d/$n"
        done
        true
    '
fi

# Verdict par composant (WARNING sur ARM, ERROR sur x86_64 où ça devrait marcher)
BIN_FAIL_STATE="ERROR"
[ "$IS_ARM" -eq 1 ] && BIN_FAIL_STATE="WARNING"

if native_ok "$BT_DIR/aapt2" version; then
    record "aapt2" "OK" "exécutable"
else
    record "aapt2" "$BIN_FAIL_STATE" "non exécutable sur cette architecture"
fi

if native_ok "$BT_DIR/zipalign" ""; then
    record "zipalign" "OK" "exécutable"
else
    record "zipalign" "$BIN_FAIL_STATE" "non exécutable sur cette architecture"
fi

if native_ok "$SDK_DIR/platform-tools/adb" version; then
    record "adb" "OK" "exécutable"
else
    record "adb" "$BIN_FAIL_STATE" "non exécutable (inutile pour compiler un APK)"
fi

if native_ok "$BT_DIR/apksigner" version; then
    record "apksigner" "OK" "exécutable"
else
    record "apksigner" "ERROR" "ne démarre pas (voir Java)"
fi

# Gradle doit utiliser l'aapt2 natif sur ARM64 (celui téléchargé par Maven est x86_64).
if [ "$IS_ARM" -eq 1 ] && native_ok "$BT_DIR/aapt2" version; then
    gradle_prop "android.aapt2FromMavenOverride" "/usr/bin/aapt2"
    info "gradle.properties : android.aapt2FromMavenOverride configuré."
fi

# ---- Variables d'environnement persistantes ---------------------------------

echo
info "Configuration d'ANDROID_HOME et du PATH dans Ubuntu..."

read -r -d '' ENV_FILE <<'EOF'
# DigitalHub APK Builder - fichier généré automatiquement
export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
export ANDROID_HOME=/root/android-sdk
export ANDROID_SDK_ROOT=/root/android-sdk
export GRADLE_HOME=/root/gradle-8.7
export PATH="$GRADLE_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/build-tools/35.0.0:$PATH"
EOF

ENV_B64="$(printf '%s\n' "$ENV_FILE" | base64 -w0)"

ub_test "echo '$ENV_B64' | base64 -d > /root/.digitalhub_env"
ub_test "for f in /root/.bashrc /root/.profile; do touch \$f; grep -qxF '. /root/.digitalhub_env' \$f || echo '. /root/.digitalhub_env' >> \$f; done"

if ub_test '. /root/.digitalhub_env && [ "$ANDROID_HOME" = /root/android-sdk ] && echo "$PATH" | grep -q "build-tools/35.0.0" && echo "$PATH" | grep -q "platform-tools" && echo "$PATH" | grep -q "cmdline-tools/latest/bin"'; then
    record "ANDROID_HOME / PATH" "OK" "persistés dans Ubuntu"
else
    record "ANDROID_HOME / PATH" "ERROR" "configuration non appliquée"
fi

# ============================================================
# [07/10] GRADLE 8.7
# ============================================================

stage "07" "GRADLE 8.7"

if ub_test "[ -x '$GRADLE_DIR/bin/gradle' ]"; then
    record "Gradle 8.7" "OK" "déjà installé"
else
    ub_test "rm -rf '$GRADLE_DIR'"

    if ! download_ub "Téléchargement de Gradle 8.7..." \
        "https://services.gradle.org/distributions/gradle-8.7-bin.zip" /tmp/gradle-8.7-bin.zip
    then
        record "Gradle 8.7" "ERROR" "téléchargement impossible"
    elif run_step "Extraction de Gradle 8.7..." "
        set -e
        unzip -tq /tmp/gradle-8.7-bin.zip >/dev/null
        unzip -q /tmp/gradle-8.7-bin.zip -d /root
        rm -f /tmp/gradle-8.7-bin.zip
    " && ub_test "[ -x '$GRADLE_DIR/bin/gradle' ]"
    then
        record "Gradle 8.7" "OK" "installé"
    else
        record "Gradle 8.7" "ERROR" "extraction impossible (voir log)"
    fi
fi

# Réglages Gradle adaptés à un téléphone (mémoire limitée).
gradle_prop "org.gradle.jvmargs" "-Xmx1536m -XX:MaxMetaspaceSize=512m -Dfile.encoding=UTF-8"
gradle_prop "org.gradle.parallel" "false"
record "Réglages Gradle" "OK" "mémoire 1,5 Go, build non parallèle"

# ============================================================
# [08/10] OUTILS SUPPLÉMENTAIRES (profil Complet)
# ============================================================

stage "08" "OUTILS SUPPLÉMENTAIRES"

check_tool() {
    local label="$1" bin="$2" vcmd="$3" v
    if ub_test "command -v $bin"; then
        v="$(ub "$vcmd" 2>/dev/null | head -n 1 | tr -d '\r')"
        record "$label" "OK" "${v:-présent}"
    else
        record "$label" "WARNING" "non installé (optionnel)"
    fi
}

if [ "$PROFILE" != "2" ]; then
    record "Outils supplémentaires" "OK" "ignorés (profil Essentiel)"
else
    EXTRA_PKGS="nodejs npm imagemagick jq python3 rsync apktool"

    run_step "Installation des outils supplémentaires..." "
        apt-get update -qq
        for p in $EXTRA_PKGS; do
            apt-get install -y -qq \$p || echo \"paquet \$p indisponible\"
        done
        true
    "

    check_tool "Node.js"     node    "node -v"
    check_tool "npm"         npm     "npm -v"
    check_tool "ImageMagick" convert "convert -version | head -n 1"
    check_tool "jq"          jq      "jq --version"
    check_tool "Python 3"    python3 "python3 --version"
    check_tool "rsync"       rsync   "rsync --version | head -n 1"
    check_tool "apktool"     apktool "apktool --version"

    if ub_test "command -v npm"; then
        if ! ub_test "command -v cordova && command -v cap"; then
            run_step "Installation de Cordova et Capacitor (npm)..." \
                "npm install -g cordova @capacitor/cli --no-audit --no-fund"
        fi
        check_tool "Cordova"       cordova "cordova --version"
        check_tool "Capacitor CLI" cap     "cap --version"
    else
        record "Cordova / Capacitor" "WARNING" "npm absent, installation ignorée"
    fi
fi

# ============================================================
# [09/10] COMMANDES dh-key ET dh-build
# ============================================================

stage "09" "COMMANDES DH"

BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
mkdir -p "$BIN_DIR"

cat > "$BIN_DIR/dh-key" <<'DH_KEY_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# dh-key : crée la clé de signature des APK release (une seule fois)
proot-distro login ubuntu -- bash -c '
. /root/.digitalhub_env
mkdir -p /root/keystore
if [ -f /root/keystore/digitalhub.jks ]; then
    echo "Clé déjà présente : /root/keystore/digitalhub.jks"
    exit 0
fi
keytool -genkeypair -v -keystore /root/keystore/digitalhub.jks \
    -alias digitalhub -keyalg RSA -keysize 2048 -validity 10000
'
ROOTFS="${PREFIX:-/data/data/com.termux/files/usr}/var/lib/proot-distro/installed-rootfs/ubuntu"
if [ -f "$ROOTFS/root/keystore/digitalhub.jks" ]; then
    echo
    echo "Clé : $ROOTFS/root/keystore/digitalhub.jks"
    echo "SAUVEGARDE-LA ailleurs (et note le mot de passe) : sans elle,"
    echo "tu ne pourras plus publier de mises à jour de ton application."
fi
DH_KEY_EOF

cat > "$BIN_DIR/dh-build" <<'DH_BUILD_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# dh-build : compile un projet Android (dossier ou .zip) en APK
# Usage : dh-build <projet.zip|dossier> [debug|release]
set -u

ROOTFS="${PREFIX:-/data/data/com.termux/files/usr}/var/lib/proot-distro/installed-rootfs/ubuntu"
DL="$HOME/storage/downloads"
SRC="${1:-}"
MODE="${2:-debug}"
OUT="$DL"
[ -d "$OUT" ] || OUT="$HOME"
T0="$(date +%s)"

if [ -z "$SRC" ]; then
    echo "Usage : dh-build <projet.zip|dossier> [debug|release]"
    echo
    echo "Projets (dh-new) :"
    ls -1 "$HOME/projets" 2>/dev/null | sed 's|^|  |'
    echo "ZIP trouvés dans Téléchargements :"
    ls -1t "$DL"/*.zip 2>/dev/null | head -n 5 | sed 's|.*/|  |'
    exit 1
fi

case "$MODE" in
    debug)   TASK="assembleDebug" ;;
    release) TASK="assembleRelease" ;;
    *) echo "Mode inconnu : $MODE (debug ou release)"; exit 1 ;;
esac

if [ ! -e "$SRC" ]; then
    if [ -e "$HOME/projets/$1" ]; then
        SRC="$HOME/projets/$1"
    else
        SRC="$DL/$1"
    fi
fi
[ -e "$SRC" ] || { echo "Introuvable : $1"; exit 1; }

NAME="$(basename "$SRC" .zip)"
NAME="${NAME//[^A-Za-z0-9._-]/_}"
DEST="$ROOTFS/root/projects/$NAME"

mkdir -p "$ROOTFS/root/projects"
rm -rf "$DEST"

if [ -f "$SRC" ]; then
    mkdir -p "$DEST"
    unzip -q "$SRC" -d "$DEST" || { echo "ZIP illisible."; exit 1; }
else
    cp -r "$SRC" "$DEST"
fi

SETTINGS="$(find "$DEST" -maxdepth 3 \( -name settings.gradle -o -name settings.gradle.kts \) -print -quit)"
[ -n "$SETTINGS" ] || { echo "Aucun projet Gradle trouvé (settings.gradle absent)."; exit 1; }
PROJ="$(dirname "$SETTINGS")"
UPROJ="${PROJ#$ROOTFS}"

echo "Projet  : $NAME"
echo "Tâche   : $TASK"
echo

proot-distro login ubuntu -- bash -c "
. /root/.digitalhub_env
cd '$UPROJ' || exit 1
chmod +x gradlew 2>/dev/null
if [ -x ./gradlew ]; then G=./gradlew; else G=gradle; fi
echo \"Compilation avec \$G\"
\$G --no-daemon $TASK
" 2>&1 | tee "$HOME/dh-build.log"
RC=${PIPESTATUS[0]}

if [ "$RC" -ne 0 ]; then
    echo
    echo "ÉCHEC de la compilation. Détails : $HOME/dh-build.log"
    exit "$RC"
fi

FINAL=""
if [ "$MODE" = "debug" ]; then
    APK="$(find "$PROJ" -path '*/outputs/apk/debug/*' -name '*.apk' -print -quit)"
    [ -n "$APK" ] || { echo "APK debug introuvable."; exit 1; }
    FINAL="$OUT/${NAME}-debug.apk"
    cp -f "$APK" "$FINAL"
else
    SIGNED="$(find "$PROJ" -path '*/outputs/apk/release/*' -name '*.apk' ! -name '*unsigned*' -print -quit)"
    UNSIGNED="$(find "$PROJ" -path '*/outputs/apk/release/*' -name '*unsigned*.apk' -print -quit)"
    FINAL="$OUT/${NAME}-release.apk"
    if [ -n "$SIGNED" ]; then
        cp -f "$SIGNED" "$FINAL"
    elif [ -n "$UNSIGNED" ]; then
        [ -f "$ROOTFS/root/keystore/digitalhub.jks" ] || { echo "Aucune clé de signature. Lance d'abord : dh-key"; exit 1; }
        UDIR="${UNSIGNED%/*}"
        UFILE="${UNSIGNED##*/}"
        UDIR_IN="${UDIR#$ROOTFS}"
        proot-distro login ubuntu -- bash -c "
        . /root/.digitalhub_env
        cd '$UDIR_IN' || exit 1
        rm -f aligned.apk signed.apk
        zipalign -p -f 4 '$UFILE' aligned.apk &&
        apksigner sign --ks /root/keystore/digitalhub.jks --out signed.apk aligned.apk
        " || { echo "Signature impossible."; exit 1; }
        cp -f "$UDIR/signed.apk" "$FINAL"
    else
        echo "APK release introuvable."
        exit 1
    fi
fi

echo
echo "APK prêt : $FINAL"
ls -lh "$FINAL" | awk '{print "Taille  : " $5}'
echo "Durée   : $(( $(date +%s) - T0 )) s"
DH_BUILD_EOF

cat > "$BIN_DIR/dh-new" <<'DH_NEW_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# dh-new : transforme un index.html (ou un dossier / un .zip) en projet Android
# Usage : dh-new <index.html|dossier|projet.zip> [NomApp] [version]
# Relancé sur le même nom : met à jour le contenu web et augmente versionCode.
set -u

DL="$HOME/storage/downloads"
ROOT="$HOME/projets"
SRC="${1:-}"
NAME="${2:-}"
VN="${3:-}"

if [ -z "$SRC" ]; then
    echo "Usage : dh-new <index.html|dossier|projet.zip> [NomApp] [version]"
    echo
    echo "Fichiers trouvés dans Téléchargements :"
    ls -1t "$DL"/*.html "$DL"/*.zip 2>/dev/null | head -n 8 | sed 's|.*/|  |'
    exit 1
fi

if [ ! -e "$SRC" ] && [ -e "$DL/$1" ]; then
    SRC="$DL/$1"
fi
[ -e "$SRC" ] || { echo "Introuvable : $1"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/web"

if [ -d "$SRC" ]; then
    cp -r "$SRC"/. "$TMP/web/" || { echo "Copie impossible."; exit 1; }
    BASE="$(basename "$(cd "$SRC" && pwd)")"
elif [[ "$SRC" == *.zip ]]; then
    unzip -q "$SRC" -d "$TMP/web" || { echo "ZIP illisible."; exit 1; }
    BASE="$(basename "$SRC" .zip)"
else
    case "$SRC" in
        *.html|*.htm) ;;
        *) echo "Fichier non pris en charge (attendu : .html, .zip ou dossier)."; exit 1 ;;
    esac
    cp "$SRC" "$TMP/web/index.html"
    BASE="$(basename "$SRC")"
    BASE="${BASE%.*}"
fi
rm -rf "$TMP/web/.git"

IDX="$(find "$TMP/web" -maxdepth 3 -name index.html -print -quit)"
[ -n "$IDX" ] || { echo "index.html introuvable dans : $1"; exit 1; }
WEB="$(dirname "$IDX")"

# ---- Nom de l'application ---------------------------------------------------
DEFAULT_NAME="$BASE"
[ "$BASE" = "index" ] && DEFAULT_NAME="MonApplication"

if [ -z "$NAME" ]; then
    if [ -t 0 ]; then
        printf "Nom de l'application [%s] : " "$DEFAULT_NAME"
        read -r NAME
    fi
    NAME="${NAME:-$DEFAULT_NAME}"
fi

SLUG="$(printf '%s' "$NAME" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"
[ -n "$SLUG" ] || SLUG="app"
case "$SLUG" in [0-9]*) SLUG="app$SLUG" ;; esac

DIRNAME="$(printf '%s' "${NAME// /_}" | tr -cd 'A-Za-z0-9._-')"
[ -n "$DIRNAME" ] || DIRNAME="$SLUG"
PROJ="$ROOT/$DIRNAME"

# ---- Package et versions (conservés si le projet existe déjà) -----------------
PKG="com.digitalhub.$SLUG"
VC=1
UPDATE=0

if [ -f "$PROJ/app/build.gradle" ]; then
    UPDATE=1
    OLD_PKG="$(sed -n "s/.*applicationId *['\"]\([^'\"]*\)['\"].*/\1/p" "$PROJ/app/build.gradle" | head -n 1)"
    OLD_VC="$(sed -n 's/.*versionCode *\([0-9][0-9]*\).*/\1/p' "$PROJ/app/build.gradle" | head -n 1)"
    OLD_VN="$(sed -n "s/.*versionName *['\"]\([^'\"]*\)['\"].*/\1/p" "$PROJ/app/build.gradle" | head -n 1)"
    [ -n "$OLD_PKG" ] && PKG="$OLD_PKG"
    [ -n "$OLD_VC" ] && VC=$((OLD_VC + 1))
    [ -z "$VN" ] && VN="${OLD_VN:-1.0}"
fi

VN="${VN:-1.0}"
VN="${VN//[^0-9A-Za-z._-]/}"
[ -n "$VN" ] || VN="1.0"

PKG_PATH="${PKG//.//}"
MAIN="$PROJ/app/src/main"

rm -rf "$MAIN"
mkdir -p "$MAIN/java/$PKG_PATH" "$MAIN/res/values" "$MAIN/assets"

# ---- Contenu web --------------------------------------------------------------
cp -r "$WEB"/. "$MAIN/assets/"

# ---- Icône (icon.png, logo.png ou ic_launcher.png dans ton dossier) -----------
ICON_ATTR=""
for f in icon.png logo.png ic_launcher.png; do
    if [ -f "$WEB/$f" ]; then
        mkdir -p "$MAIN/res/mipmap-xxxhdpi"
        cp "$WEB/$f" "$MAIN/res/mipmap-xxxhdpi/ic_launcher.png"
        ICON_ATTR='android:icon="@mipmap/ic_launcher"'
        break
    fi
done

# ---- Nom affiché (échappé pour XML et Android) --------------------------------
XML_NAME="$(printf '%s' "$NAME" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e "s/'/\\\\'/g" -e 's/"/\\"/g')"
printf '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <string name="app_name">%s</string>\n</resources>\n' \
    "$XML_NAME" > "$MAIN/res/values/strings.xml"

# ---- Fichiers Gradle ----------------------------------------------------------
cat > "$PROJ/settings.gradle" <<'EOF'
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "DigitalHubApp"
include ':app'
EOF

cat > "$PROJ/build.gradle" <<'EOF'
plugins {
    id 'com.android.application' version '8.6.1' apply false
}
EOF

cat > "$PROJ/gradle.properties" <<'EOF'
org.gradle.jvmargs=-Xmx1536m -Dfile.encoding=UTF-8
android.nonTransitiveRClass=true
EOF

printf 'sdk.dir=/root/android-sdk\n' > "$PROJ/local.properties"

sed -e "s|__PKG__|$PKG|g" -e "s|__VC__|$VC|g" -e "s|__VN__|$VN|g" > "$PROJ/app/build.gradle" <<'EOF'
plugins {
    id 'com.android.application'
}

android {
    namespace '__PKG__'
    compileSdk 35
    buildToolsVersion '35.0.0'

    defaultConfig {
        applicationId '__PKG__'
        minSdk 24
        targetSdk 34
        versionCode __VC__
        versionName '__VN__'
    }

    buildTypes {
        release {
            minifyEnabled false
        }
    }

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
}
EOF

# ---- Manifest -----------------------------------------------------------------
sed -e "s|__ICON__|$ICON_ATTR|g" > "$MAIN/AndroidManifest.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.INTERNET" />

    <application
        android:label="@string/app_name"
        __ICON__
        android:allowBackup="true"
        android:hardwareAccelerated="true"
        android:theme="@android:style/Theme.DeviceDefault.Light.NoActionBar">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:configChanges="orientation|screenSize|keyboard|keyboardHidden|screenLayout|smallestScreenSize|uiMode"
            android:windowSoftInputMode="adjustResize">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

    </application>
</manifest>
EOF

# ---- Activité : WebView qui affiche assets/index.html --------------------------
# - liens WhatsApp / Telegram / tel: / mailto: ouverts hors de l'app
#   (corrige ERR_UNKNOWN_URL_SCHEME)
# - sélecteur de fichiers (envoi de capture d'écran de paiement)
# - bouton retour = page précédente
sed -e "s|__PKG__|$PKG|g" > "$MAIN/java/$PKG_PATH/MainActivity.java" <<'EOF'
package __PKG__;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.Bundle;
import android.os.Message;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

public class MainActivity extends Activity {

    private static final String HOME = "file:///android_asset/index.html";
    private static final int FILE_REQ = 1001;

    private WebView web;
    private ValueCallback<Uri[]> fileCallback;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        web = new WebView(this);
        setContentView(web);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setJavaScriptCanOpenWindowsAutomatically(true);
        s.setSupportMultipleWindows(true);

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri u = request.getUrl();
                if (u.toString().startsWith("file:///android_asset/")) {
                    return false;
                }
                openExternal(u);
                return true;
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback,
                                             FileChooserParams params) {
                if (fileCallback != null) {
                    fileCallback.onReceiveValue(null);
                }
                fileCallback = callback;
                try {
                    startActivityForResult(params.createIntent(), FILE_REQ);
                } catch (ActivityNotFoundException e) {
                    fileCallback = null;
                    Toast.makeText(MainActivity.this,
                            "Aucune application pour choisir un fichier", Toast.LENGTH_SHORT).show();
                    return false;
                }
                return true;
            }

            // window.open / target="_blank" : on ouvre le lien à l'extérieur.
            @Override
            public boolean onCreateWindow(WebView view, boolean isDialog,
                                          boolean isUserGesture, Message resultMsg) {
                final boolean[] done = {false};
                WebView tmp = new WebView(MainActivity.this);
                tmp.setWebViewClient(new WebViewClient() {
                    @Override
                    public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) {
                        if (!done[0]) {
                            done[0] = true;
                            openExternal(r.getUrl());
                        }
                        return true;
                    }

                    @Override
                    public void onPageStarted(WebView v, String url, Bitmap favicon) {
                        if (!done[0] && url != null && !url.equals("about:blank")) {
                            done[0] = true;
                            v.stopLoading();
                            openExternal(Uri.parse(url));
                        }
                    }
                });
                WebView.WebViewTransport transport = (WebView.WebViewTransport) resultMsg.obj;
                transport.setWebView(tmp);
                resultMsg.sendToTarget();
                return true;
            }
        });

        if (savedInstanceState == null) {
            web.loadUrl(HOME);
        } else {
            web.restoreState(savedInstanceState);
        }
    }

    private void openExternal(Uri uri) {
        try {
            Intent i;
            if ("intent".equals(uri.getScheme())) {
                i = Intent.parseUri(uri.toString(), Intent.URI_INTENT_SCHEME);
                i.addCategory(Intent.CATEGORY_BROWSABLE);
                i.setComponent(null);
                i.setSelector(null);
            } else {
                i = new Intent(Intent.ACTION_VIEW, uri);
            }
            startActivity(i);
        } catch (Exception e) {
            Toast.makeText(this, "Impossible d'ouvrir ce lien", Toast.LENGTH_SHORT).show();
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode == FILE_REQ) {
            if (fileCallback != null) {
                fileCallback.onReceiveValue(
                        WebChromeClient.FileChooserParams.parseResult(resultCode, data));
                fileCallback = null;
            }
            return;
        }
        super.onActivityResult(requestCode, resultCode, data);
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        web.saveState(outState);
    }

    @Override
    public void onBackPressed() {
        if (web.canGoBack()) {
            web.goBack();
        } else {
            super.onBackPressed();
        }
    }

    @Override
    protected void onPause() {
        super.onPause();
        web.onPause();
    }

    @Override
    protected void onResume() {
        super.onResume();
        web.onResume();
    }

    @Override
    protected void onDestroy() {
        if (web != null) {
            web.destroy();
        }
        super.onDestroy();
    }
}
EOF

echo
if [ "$UPDATE" -eq 1 ]; then
    echo "Projet mis à jour : $PROJ"
else
    echo "Projet créé : $PROJ"
fi
echo "Application : $NAME"
echo "Package     : $PKG"
echo "Version     : $VN (code $VC)"
[ -n "$ICON_ATTR" ] && echo "Icône       : trouvée et utilisée" || echo "Icône       : par défaut (mets icon.png dans ton dossier pour la changer)"
echo
echo "Garde le même nom d'application : le package doit rester identique"
echo "pour que les mises à jour s'installent par-dessus l'ancienne version."
echo

if [ -t 0 ] && [ -z "${DH_NO_PROMPT:-}" ] && command -v dh-build >/dev/null 2>&1; then
    printf "Compiler maintenant (APK debug) ? [O/n] "
    read -r ANS
    case "$ANS" in
        n|N|non|Non) ;;
        *) exec dh-build "$PROJ" debug ;;
    esac
fi

echo "Pour compiler :  dh-build $DIRNAME"
echo "(la 1re compilation télécharge les dépendances : 5 à 15 min)"
DH_NEW_EOF

chmod +x "$BIN_DIR/dh-key" "$BIN_DIR/dh-build" "$BIN_DIR/dh-new"

if [ -x "$BIN_DIR/dh-build" ] && [ -x "$BIN_DIR/dh-key" ] && [ -x "$BIN_DIR/dh-new" ]; then
    record "Commandes dh-new/build/key" "OK" "installées"
else
    record "Commandes dh-new/build/key" "ERROR" "création impossible"
fi

# ============================================================
# [10/10] VÉRIFICATION
# ============================================================

stage "10" "VÉRIFICATION"

# Exécution réelle, sans projet : "gradle --version" ne demande pas de build.gradle.
if ub 'gradle --version 2>&1 | grep -q "^Gradle 8\.7"' >> "$LOG_FILE" 2>&1; then
    record "Gradle (exécution)" "OK" "gradle --version fonctionne"
else
    record "Gradle (exécution)" "ERROR" "gradle --version échoue"
fi

# L'avertissement "ancien CLI déprécié" de sdkmanager est bénin : on teste le démarrage.
if ub_test 'sdkmanager --sdk_root="$ANDROID_HOME" --version'; then
    record "sdkmanager" "OK" "démarre correctement"
else
    record "sdkmanager" "ERROR" "ne démarre pas"
fi

# ============================================================
#                 SYSTEM PROGRESS (résumé réel)
# ============================================================

N_OK=0; N_WARN=0; N_ERR=0
for s in "${RES_STATES[@]}"; do
    case "$s" in
        OK) N_OK=$((N_OK+1)) ;;
        WARNING) N_WARN=$((N_WARN+1)) ;;
        *) N_ERR=$((N_ERR+1)) ;;
    esac
done

if [ "$N_ERR" -gt 0 ]; then
    VERDICT="ERREURS DÉTECTÉES"
elif [ "$N_WARN" -gt 0 ]; then
    VERDICT="TERMINÉ AVEC AVERTISSEMENTS"
else
    VERDICT="INSTALLATION COMPLÈTE"
fi

echo
WIDTH="$(box_width)"

box_top "$WIDTH"
box_line "" "$WIDTH"
box_line "DIGITALHUB" "$WIDTH"
box_line "SYSTEM PROGRESS" "$WIDTH"
box_line "" "$WIDTH"

for idx in "${!RES_NAMES[@]}"; do
    case "${RES_STATES[$idx]}" in
        OK)      mark="$S_OK" ;;
        WARNING) mark="$S_WARN" ;;
        *)       mark="$S_ERR" ;;
    esac
    box_line "$mark ${RES_NAMES[$idx]}" "$WIDTH"
done

box_line "" "$WIDTH"
box_line "$VERDICT" "$WIDTH"
box_line "OK:$N_OK  WARN:$N_WARN  ERR:$N_ERR" "$WIDTH"
box_line "Durée totale : $(elapsed)" "$WIDTH"
box_line "" "$WIDTH"
box_line "Créé par : Jeph Ouedraogo" "$WIDTH"
box_line "DIGITALHUB APK BUILDER" "$WIDTH"
box_line "" "$WIDTH"
box_bottom "$WIDTH"

echo
note "$WHITE" "Log détaillé : $LOG_FILE"

if [ "$N_ERR" -gt 0 ]; then
    note "$RED" "Relance le script : il répare les composants incomplets."
    echo
    exit 1
fi

if [ "$N_WARN" -gt 0 ]; then
    note "$YELLOW" "Des composants optionnels manquent (voir les lignes ! ci-dessus)."
fi

echo
note "$WHITE" "Pour créer ton application :"
note "$CYAN" "dh-new index.html"
note "$WHITE" "  crée le projet Android"
note "$CYAN" "dh-build NomDuProjet"
note "$WHITE" "  APK debug dans Téléchargements"
note "$CYAN" "dh-key"
note "$WHITE" "  clé de signature (1 seule fois)"
note "$CYAN" "dh-build NomDuProjet release"
note "$WHITE" "  APK signé"
echo
note "$WHITE" "BUILD $DOT CREATE $DOT SHIP"
echo
