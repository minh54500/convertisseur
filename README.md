# Convertisseur

Petite app Mac pour **convertir** des PDF et des images en WebP, JPG, PNG ou AVIF, et pour **fusionner** des PDF et des images en un seul PDF.

Tout se passe sur ton Mac : aucun fichier n'est envoyé sur internet.

## Installer

Ouvre le **Terminal** (⌘Espace → « Terminal »), colle cette ligne puis appuie sur Entrée :

```sh
curl -fsSL https://raw.githubusercontent.com/minh54500/convertisseur/main/install.sh | zsh
```

- Il faut macOS 14 (Sonoma) ou plus récent, sur un Mac Apple Silicon ou Intel.
- La première fois, macOS peut te demander d'installer les « outils de développement ». Accepte, attends la fin de l'installation, puis relance la même commande.
- Pour mettre l'app à jour, relance la même commande.

## Utiliser

**Avec l'app** (⌘Espace → « Convertisseur ») :
- **Convertir** : glisse des fichiers ou des dossiers dans la fenêtre, ou sur l'icône dans le Dock. Tu choisis le format, la largeur max (1600 px par défaut, idéal pour le web) et la qualité.
- **Fusionner en PDF** : ajoute des PDF et des images, remets-les dans l'ordre en glissant les lignes, puis clique sur « Fusionner ».

**Sans ouvrir l'app**, fais un clic droit sur des fichiers ou un dossier dans le Finder → **Actions rapides** :
- **Convertir en WebP**
- **Fusionner en PDF** (dans l'ordre alphabétique des noms)

Si ces actions n'apparaissent pas, va dans Réglages Système → Général → Login Items et extensions → Finder, et coche-les.

## Ce que ça fait exactement

| Ce que tu donnes | Ce que tu obtiens |
|---|---|
| Un dossier `Photos` | `Photos_webp/` à côté, avec les mêmes sous-dossiers |
| Des fichiers seuls | Le résultat à côté de chaque fichier |
| Un PDF | Une image par page : `nom-p01.webp`, `nom-p02.webp`… |
| Un GIF animé (vers WebP ou AVIF) | Une image qui reste animée |
| Plusieurs fichiers à fusionner | `Fusion.pdf`, avec les images mises à la largeur A4 |

- Rien n'est jamais écrasé ni supprimé. Si un nom est déjà pris, un `(1)` est ajouté.
- Les métadonnées des photos (dont la position GPS) sont retirées des images converties.
- Formats acceptés : PDF, JPG, PNG, HEIC, WebP, TIFF, GIF, BMP, AVIF.

## En ligne de commande

```sh
R=~/Applications/Convertisseur.app/Contents/Resources
$R/venv/bin/python3 $R/convert.py ~/Dossier --to jpg -q 85 -w 0
$R/venv/bin/python3 $R/convert.py --merge a.pdf b.jpg -o resultat.pdf
```

## Désinstaller

```sh
curl -fsSL https://raw.githubusercontent.com/minh54500/convertisseur/main/uninstall.sh | zsh
```

## Pour les développeurs

- `convert.py` : le moteur (PyMuPDF + Pillow + pillow-heif).
- `app/Convertisseur.swift` : l'interface SwiftUI, qui lance le moteur et lit sa progression en JSON.
- `build.sh` : compile l'app avec `swiftc`, y intègre l'environnement Python, l'installe dans `~/Applications` et génère les actions rapides à partir de `quick-action/template.workflow`.

L'app n'est pas signée par Apple. C'est pour ça qu'elle est compilée sur ta machine pendant l'installation : macOS ne la bloque pas.
