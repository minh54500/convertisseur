#!/bin/zsh
# Construit Convertisseur.app (moteur Python embarqué), l'installe dans ~/Applications
# et ajoute les actions rapides du Finder.
set -euo pipefail
cd "${0:A:h}"

APP=build/Convertisseur.app
RES=$APP/Contents/Resources
BUNDLE_ID=io.github.minh54500.convertisseur

if [[ ! -x .venv/bin/python3 ]]; then
  echo "→ Installation du moteur Python…"
  /usr/bin/python3 -m venv .venv
  .venv/bin/pip install -q --upgrade pip
fi
.venv/bin/pip install -q -r requirements.txt

echo "→ Compilation de l'app…"
rm -rf build && mkdir -p $APP/Contents/MacOS $RES
swiftc -O -parse-as-library -swift-version 5 app/Convertisseur.swift -o $APP/Contents/MacOS/Convertisseur 2>&1 | grep -E "error" || true
[[ -x $APP/Contents/MacOS/Convertisseur ]] || { echo "✗ La compilation a échoué"; exit 1; }

swift app/make-icon.swift build/Convertisseur.iconset
iconutil -c icns build/Convertisseur.iconset -o $RES/Convertisseur.icns

cp convert.py $RES/
cp -R .venv $RES/venv
find $RES/venv -name __pycache__ -prune -exec rm -rf {} +

cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Convertisseur</string>
  <key>CFBundleDisplayName</key><string>Convertisseur</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Convertisseur</string>
  <key>CFBundleIconFile</key><string>Convertisseur</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Fichiers et dossiers</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string><string>public.image</string><string>public.folder</string></array>
  </dict></array>
</dict></plist>
EOF

codesign --force --deep -s - $APP 2>/dev/null || true

mkdir -p ~/Applications
rm -rf ~/Applications/Convertisseur.app
cp -R $APP ~/Applications/
echo "✓ App installée : ~/Applications/Convertisseur.app"

# --- Actions rapides (clic droit dans le Finder), générées depuis le modèle
ENGINE='R="$HOME/Applications/Convertisseur.app/Contents/Resources"
run() { "$R/venv/bin/python3" "$R/convert.py" "$@" 2>/dev/null; }
notify() { osascript -e "on run a" -e "display notification (item 1 of a) with title \"Convertisseur\" sound name \"Glass\"" -e "end run" "$1"; }
'
add_action() {  # $1 = nom du menu, $2 = script
  local wf=~/Library/Services/"$1.workflow"
  rm -rf "$wf" && cp -R quick-action/template.workflow "$wf"
  plutil -replace NSServices.0.NSMenuItem.default -string "$1" "$wf/Contents/Info.plist"
  plutil -replace actions.0.action.ActionParameters.COMMAND_STRING -string "$ENGINE$2" "$wf/Contents/document.wflow"
}
mkdir -p ~/Library/Services

add_action "Convertir en WebP" "q=\$(defaults read $BUNDLE_ID quality 2>/dev/null || echo 82)
w=\$(defaults read $BUNDLE_ID maxWidth 2>/dev/null || echo 1600)
out=\$(run --to webp -q \"\$q\" -w \"\$w\" \"\$@\")
notify \"\${out##*\$'\n'}\""

add_action "Fusionner en PDF" 'out=$(run --merge "${(@on)@}")
notify "${out##*$'"'"'\n'"'"'}"
dest=$(print -r -- "$out" | sed -n "s/^→ //p")
[[ -f "$dest" ]] && open -R "$dest"'

/System/Library/CoreServices/pbs -flush
echo "✓ Actions rapides : clic droit → Actions rapides → Convertir en WebP / Fusionner en PDF"
