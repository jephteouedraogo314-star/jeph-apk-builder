#!/data/data/com.termux/files/usr/bin/bash
# Correctif : réinstalle dh-build et dh-key (sans refaire toute l'installation).
BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
mkdir -p "$BIN_DIR"

cat > "$BIN_DIR/dh-key" <<'DH_KEY_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# dh-key : crée la clé de signature des APK release (une seule fois)
proot-distro login ubuntu -- bash -c '
. /root/.digitalhub_env
mkdir -p /root/keystore
if [ -f /root/keystore/digitalhub.jks ]; then
    echo "Clé déjà présente : /root/keystore/digitalhub.jks (dans Ubuntu)"
    exit 0
fi
keytool -genkeypair -v -keystore /root/keystore/digitalhub.jks \
    -alias digitalhub -keyalg RSA -keysize 2048 -validity 10000
'
if proot-distro login ubuntu -- test -f /root/keystore/digitalhub.jks; then
    echo
    echo "Clé créée dans Ubuntu : /root/keystore/digitalhub.jks"
    echo "SAUVEGARDE-LA ailleurs et note le mot de passe : sans elle,"
    echo "tu ne pourras plus publier de mises à jour de ton application."
    echo
    echo "Pour en faire une copie dans Termux :"
    echo "  proot-distro login ubuntu -- cat /root/keystore/digitalhub.jks > ~/digitalhub.jks"
fi
DH_KEY_EOF

cat > "$BIN_DIR/dh-build" <<'DH_BUILD_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# dh-build : compile un projet Android (dossier ou .zip) en APK
# Usage : dh-build <projet|projet.zip> [debug|release]
# Le projet est envoyé dans Ubuntu par un flux tar : aucun chemin interne
# de proot-distro n'est utilisé, donc ça marche quelle que soit sa version.
set -u
set -o pipefail

DL="$HOME/storage/downloads"
SRC="${1:-}"
MODE="${2:-debug}"
OUT="$DL"
[ -d "$OUT" ] || OUT="$HOME"
T0="$(date +%s)"
LOG="$HOME/dh-build.log"

# Commande dans Ubuntu avec l'environnement Android chargé.
ub() { proot-distro login ubuntu -- bash -c ". /root/.digitalhub_env 2>/dev/null; $1"; }

if [ -z "$SRC" ]; then
    echo "Usage : dh-build <projet|projet.zip> [debug|release]"
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
UPROJ="/root/projects/$NAME"

# ---- Préparation dans un dossier temporaire de Termux ---------------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

if [ -f "$SRC" ]; then
    unzip -q "$SRC" -d "$STAGE" || { echo "ZIP illisible."; exit 1; }
else
    cp -r "$SRC"/. "$STAGE"/ || { echo "Copie du projet impossible."; exit 1; }
fi

SETTINGS="$(find "$STAGE" -maxdepth 3 \( -name settings.gradle -o -name settings.gradle.kts \) -print -quit)"
[ -n "$SETTINGS" ] || { echo "Aucun projet Gradle trouvé (settings.gradle absent)."; exit 1; }
PROJ="$(dirname "$SETTINGS")"
rm -rf "$PROJ/build" "$PROJ/app/build" "$PROJ/.gradle"

echo "Projet  : $NAME"
echo "Tâche   : $TASK"
echo
echo "Envoi du projet dans Ubuntu..."

if ! tar -C "$PROJ" -cf - . | proot-distro login ubuntu -- bash -c \
    "rm -rf '$UPROJ' && mkdir -p '$UPROJ' && tar --no-same-owner -C '$UPROJ' -xf -"
then
    echo "Envoi impossible. Vérifie Ubuntu : proot-distro login ubuntu"
    exit 1
fi

if ! ub "[ -f '$UPROJ/settings.gradle' ] || [ -f '$UPROJ/settings.gradle.kts' ]"; then
    echo "Le projet n'est pas arrivé dans Ubuntu ($UPROJ)."
    exit 1
fi

# ---- Compilation ----------------------------------------------------------------
proot-distro login ubuntu -- bash -c "
. /root/.digitalhub_env
cd '$UPROJ' || exit 1
chmod +x gradlew 2>/dev/null
if [ -x ./gradlew ]; then G=./gradlew; else G=gradle; fi
echo \"Compilation avec \$G\"
\$G --no-daemon $TASK
" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}

if [ "$RC" -ne 0 ]; then
    echo
    echo "ÉCHEC de la compilation. Détails : $LOG"
    echo "--- Dernières lignes ---"
    tail -n 25 "$LOG"
    exit "$RC"
fi

# ---- Récupération de l'APK ------------------------------------------------------
# Copie un fichier d'Ubuntu vers Termux.
fetch() {
    proot-distro login ubuntu -- cat "$1" > "$2" && [ -s "$2" ]
}

FINAL=""
if [ "$MODE" = "debug" ]; then
    APK="$(ub "find '$UPROJ' -path '*/outputs/apk/debug/*' -name '*.apk' -print -quit" | tr -d '\r')"
    [ -n "$APK" ] || { echo "APK debug introuvable."; exit 1; }
    FINAL="$OUT/${NAME}-debug.apk"
    fetch "$APK" "$FINAL" || { echo "Copie de l'APK impossible."; exit 1; }
else
    SIGNED="$(ub "find '$UPROJ' -path '*/outputs/apk/release/*' -name '*.apk' ! -name '*unsigned*' -print -quit" | tr -d '\r')"
    UNSIGNED="$(ub "find '$UPROJ' -path '*/outputs/apk/release/*' -name '*unsigned*.apk' -print -quit" | tr -d '\r')"
    FINAL="$OUT/${NAME}-release.apk"
    if [ -n "$SIGNED" ]; then
        fetch "$SIGNED" "$FINAL" || { echo "Copie de l'APK impossible."; exit 1; }
    elif [ -n "$UNSIGNED" ]; then
        ub "[ -f /root/keystore/digitalhub.jks ]" || { echo "Aucune clé de signature. Lance d'abord : dh-key"; exit 1; }
        UDIR="${UNSIGNED%/*}"
        UFILE="${UNSIGNED##*/}"
        proot-distro login ubuntu -- bash -c "
        . /root/.digitalhub_env
        cd '$UDIR' || exit 1
        rm -f aligned.apk signed.apk
        zipalign -p -f 4 '$UFILE' aligned.apk &&
        apksigner sign --ks /root/keystore/digitalhub.jks --out signed.apk aligned.apk
        " || { echo "Signature impossible."; exit 1; }
        fetch "$UDIR/signed.apk" "$FINAL" || { echo "Copie de l'APK impossible."; exit 1; }
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

chmod +x "$BIN_DIR/dh-key" "$BIN_DIR/dh-build"
echo "dh-build et dh-key mis à jour."
