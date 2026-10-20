# Partie commune des actions rapides (l'identifiant de l'app est inséré par build.sh).
for A in ~/Applications/Convertisseur.app /Applications/Convertisseur.app; do [[ -d $A ]] && break; done
R=$A/Contents/Resources
pref() { defaults read BUNDLE_ID $1 2>/dev/null || echo $2; }
o=$(pref outDir "")
OUT=(); [[ -n $o && -d $o ]] && OUT=(--out-dir "$o")
run() { "$R/python/bin/python3" "$R/convert.py" "${OUT[@]}" "$@" 2>/dev/null; }
notify() { osascript -e 'on run a' -e 'display notification (item 1 of a) with title "Convertisseur" sound name "Glass"' -e 'end run' "${1##*$'\n'}"; }
