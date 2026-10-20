#!/bin/zsh
# Installe (ou met à jour) Convertisseur :
#   curl -fsSL https://raw.githubusercontent.com/minh54500/convertisseur/main/install.sh | zsh
set -euo pipefail

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Convertisseur a besoin des outils de développement d'Apple (gratuits)."
  echo "Une fenêtre va s'ouvrir : clique sur « Installer », attends la fin, puis relance la même commande."
  xcode-select --install || true
  exit 1
fi

SRC="$HOME/Library/Application Support/Convertisseur/src"
echo "→ Téléchargement…"
rm -rf "$SRC" && mkdir -p "$SRC"
curl -fsSL https://github.com/minh54500/convertisseur/archive/refs/heads/main.tar.gz | tar xz -C "$SRC" --strip-components 1

zsh "$SRC/build.sh"
echo "\n✓ C'est prêt ! Convertisseur s'ouvre (il est aussi dans ⌘Espace)."
open ~/Applications/Convertisseur.app
