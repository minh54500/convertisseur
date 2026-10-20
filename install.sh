#!/bin/zsh
# Installe (ou met à jour) Convertisseur, sans rien d'autre à installer :
#   curl -fsSL https://raw.githubusercontent.com/minh54500/convertisseur/main/install.sh | zsh
set -euo pipefail
REPO=minh54500/convertisseur

if (( ${$(sw_vers -productVersion)%%.*} < 14 )); then
  echo "✗ Convertisseur demande macOS 14 (Sonoma) ou plus récent."
  exit 1
fi
[[ $(sysctl -n hw.optional.arm64 2>/dev/null) == 1 ]] && ARCH=arm64 || ARCH=x86_64

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "→ Téléchargement de Convertisseur…"
curl -fL --progress-bar -o "$TMP/app.zip" "https://github.com/$REPO/releases/latest/download/Convertisseur-$ARCH.zip"
ditto -x -k "$TMP/app.zip" "$TMP"

[[ ${1:-} == --update ]] || osascript -e 'quit app "Convertisseur"' 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/Convertisseur.app
mv "$TMP/Convertisseur.app" ~/Applications/
rm -rf ~/Library/Application\ Support/Convertisseur  # ancienne installation (v1.1, compilée sur place)

echo "✓ Convertisseur est installé dans ~/Applications (il est aussi dans ⌘Espace)."
[[ ${1:-} == --update ]] || open ~/Applications/Convertisseur.app
