#!/bin/zsh
# Publie une nouvelle version sur GitHub (les apps installées la proposeront au lancement).
#   1. change le numéro dans VERSION, commit et push
#   2. ./release.sh "Ce qui change dans cette version"
set -euo pipefail
cd "${0:A:h}"
REPO=minh54500/convertisseur
VERSION=$(<VERSION)
NOTES=${1:-"Version $VERSION"}

[[ -z $(git status --porcelain) ]] || { echo "✗ Commit d'abord tes changements."; exit 1; }
git push -q origin main

# Jeton GitHub enregistré par git (trousseau macOS)
TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill | sed -n 's/^password=//p')
[[ -n $TOKEN ]] || { echo "✗ Pas d'identifiants GitHub enregistrés pour git."; exit 1; }
api() { curl -fsS -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" "$@"; }

./build.sh --release

body=$(NOTES=$NOTES VERSION=$VERSION /usr/bin/python3 -c 'import json, os; print(json.dumps({
  "tag_name": "v" + os.environ["VERSION"], "target_commitish": "main",
  "name": "Convertisseur " + os.environ["VERSION"], "body": os.environ["NOTES"]}))')
id=$(api -d "$body" https://api.github.com/repos/$REPO/releases | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')

for zip in build/Convertisseur-{arm64,x86_64}.zip; do
  echo "→ Envoi de ${zip:t}…"
  api -H "Content-Type: application/zip" --data-binary @$zip \
    "https://uploads.github.com/repos/$REPO/releases/$id/assets?name=${zip:t}" >/dev/null
done
echo "✓ Version $VERSION publiée : https://github.com/$REPO/releases/tag/v$VERSION"
