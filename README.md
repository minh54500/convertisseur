# Convertisseur

Petite app Mac pour **convertir**, **fusionner**, **compresser** et **découper** des PDF et des images.

Tout se passe sur ton Mac : aucun fichier n'est envoyé sur internet. L'app se connecte seulement à GitHub, au démarrage, pour voir s'il existe une nouvelle version.

## Installer

Ouvre le **Terminal** (⌘Espace → « Terminal »), colle cette ligne puis appuie sur Entrée :

```sh
curl -fsSL https://raw.githubusercontent.com/minh54500/convertisseur/main/install.sh | zsh
```

Ça prend environ 30 secondes et il n'y a rien d'autre à installer. Il faut macOS 14 (Sonoma) ou plus récent, sur un Mac Apple Silicon ou Intel.

**Mises à jour :** quand une nouvelle version sort, l'app l'annonce au démarrage. Clique sur « Mettre à jour », c'est tout.

## Utiliser

Ouvre **Convertisseur** (⌘Espace → « Convertisseur »), choisis un onglet, puis glisse tes fichiers dans la fenêtre ou sur l'icône du Dock.

| Onglet | Ce qu'il fait |
|---|---|
| **Convertir** | Transforme des PDF et des images en WebP, JPG, PNG ou AVIF. Tu règles la largeur max (1600 px par défaut, idéal pour le web) et la qualité. Un PDF donne une image par page. |
| **Fusionner** | Assemble des PDF et des images en un seul PDF. Tu remets les fichiers dans l'ordre en glissant les lignes. |
| **Compresser** | Allège des PDF trop lourds, par exemple pour les envoyer par mail. Trois niveaux : légère, moyenne ou forte. Les images sont réduites, le texte reste net. |
| **Découper** | Fait un PDF par page, ou extrait seulement certaines pages (ex. `1-3, 7, 10-`). |

- **Enregistrer** : par défaut, les résultats sont créés à côté des originaux. Tu peux aussi choisir un dossier.
- **PDF protégés** : l'app demande le mot de passe. Le fichier créé n'est pas protégé.

### Dans l'encoche

Coche **« Zone de dépôt dans l'encoche »** en bas de la fenêtre. Ensuite, quand tu glisses un fichier vers le haut de l'écran, une bulle descend de l'encoche avec 4 cibles : **WebP**, **JPG**, **Fusionner** et **Compresser**. Lâche le fichier sur l'une d'elles : la conversion se lance, avec les réglages de l'app.

L'app doit rester ouverte pour que la zone fonctionne. Tu peux fermer sa fenêtre, elle continue en arrière-plan. Coche aussi **« Ouvrir au démarrage »** : elle se lancera alors discrètement, sans fenêtre, à chaque démarrage du Mac. Sur un Mac sans encoche, la bulle apparaît en haut au centre de l'écran.

### Clic droit dans le Finder

Sélectionne des fichiers ou un dossier, puis fais clic droit → **Actions rapides** :
- **Convertir en WebP**
- **Convertir en JPG** (pratique pour les photos HEIC d'iPhone)
- **Compresser le PDF**
- **Fusionner en PDF** (dans l'ordre des noms de fichiers)

Ces actions suivent les réglages choisis dans l'app (qualité, largeur, niveau de compression, dossier de sortie). Si elles n'apparaissent pas, ouvre l'app une fois, ou va dans Réglages Système → Général → Login Items et extensions → Finder, et coche-les.

## Ce qu'il faut savoir

- Rien n'est jamais écrasé ni supprimé. Si un nom est déjà pris, un `(1)` est ajouté.
- Un dossier donne un dossier : `Photos` → `Photos_webp/`, avec les mêmes sous-dossiers.
- Les métadonnées des photos (dont la position GPS) sont retirées des images converties.
- Les GIF animés restent animés en WebP et en AVIF.
- Formats acceptés : PDF, JPG, PNG, HEIC, WebP, TIFF, GIF, BMP, AVIF.

## Désinstaller

```sh
curl -fsSL https://raw.githubusercontent.com/minh54500/convertisseur/main/uninstall.sh | zsh
```

## Pour les développeurs

- `convert.py` : le moteur (PyMuPDF + Pillow + pillow-heif). Il marche aussi en ligne de commande, `--help` liste les options.
- `app/Convertisseur.swift` : l'interface SwiftUI, qui lance le moteur et lit sa progression en JSON.
- `app/Notch.swift` : la zone de dépôt sous l'encoche.
- `quick-action/` : les scripts des actions rapides et le modèle Automator.
- `build.sh` : compile l'app (il faut les outils de développement Apple) avec un Python autonome ([python-build-standalone](https://github.com/astral-sh/python-build-standalone)), puis l'installe dans `~/Applications`.
- `build.sh --release` : produit les zip pour Apple Silicon et Intel.
- `release.sh "notes"` : publie la version indiquée dans `VERSION` sur GitHub.

L'app n'est pas signée par Apple. L'installation passe par `curl`, qui ne marque pas le fichier comme « téléchargé » : macOS l'ouvre donc sans afficher l'alerte « développeur non identifié ».
