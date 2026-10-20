#!/bin/zsh
# Désinstalle Convertisseur :
#   curl -fsSL https://raw.githubusercontent.com/minh54500/convertisseur/main/uninstall.sh | zsh
osascript -e 'quit app "Convertisseur"' 2>/dev/null
rm -rf ~/Applications/Convertisseur.app \
       ~/Library/Services/{"Convertir en WebP","Convertir en JPG","Fusionner en PDF","Compresser le PDF"}.workflow \
       ~/Library/Application\ Support/Convertisseur
defaults delete io.github.minh54500.convertisseur 2>/dev/null
/System/Library/CoreServices/pbs -flush
echo "✓ Convertisseur a été désinstallé."
