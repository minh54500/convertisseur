#!/bin/zsh
# ./build.sh            construit l'app pour ce Mac et l'installe dans ~/Applications (+ actions rapides)
# ./build.sh --release  construit build/Convertisseur-arm64.zip et build/Convertisseur-x86_64.zip
#
# L'app embarque son propre Python (python-build-standalone) : rien à installer chez l'utilisateur.
# Seul ce script a besoin des outils de développement Apple (swiftc).
set -euo pipefail
cd "${0:A:h}"

VERSION=$(<VERSION)
BUNDLE_ID=io.github.minh54500.convertisseur
PY_TAG=20261013
PY_VER=3.12.15
CACHE=build-cache
mkdir -p $CACHE

python_archive() {  # $1 = aarch64 | x86_64
  local name="cpython-$PY_VER+$PY_TAG-$1-apple-darwin-install_only.tar.gz"
  if [[ ! -f $CACHE/$name ]]; then
    echo "→ Téléchargement de Python ($1)…" >&2
    curl -fL --progress-bar -o $CACHE/$name.part \
      "https://github.com/astral-sh/python-build-standalone/releases/download/$PY_TAG/${name//+/%2B}"
    mv $CACHE/$name.part $CACHE/$name
  fi
  print $CACHE/$name
}

# Python de cette machine, pour lancer pip et pré-compiler le code.
HOST_ARCH=$(uname -m); [[ $(sysctl -n hw.optional.arm64 2>/dev/null) == 1 ]] && HOST_ARCH=arm64
if [[ ! -x $CACHE/host/python/bin/python3 ]]; then
  mkdir -p $CACHE/host
  tar xzf $(python_archive ${HOST_ARCH/arm64/aarch64}) -C $CACHE/host
fi
HOST_PY=$CACHE/host/python/bin/python3

build_app() {  # $1 = arm64 | x86_64
  local arch=$1 app=build/$1/Convertisseur.app
  local res=$app/Contents/Resources
  local platforms=(--platform macosx_11_0_arm64)
  [[ $arch == x86_64 ]] && platforms=(--platform macosx_10_15_x86_64 --platform macosx_10_13_x86_64 --platform macosx_10_9_x86_64)

  echo "→ Construction pour $arch…"
  rm -rf build/$arch && mkdir -p $app/Contents/MacOS $res

  swiftc -O -parse-as-library -swift-version 5 -target $arch-apple-macos14 \
    app/Convertisseur.swift -o $app/Contents/MacOS/Convertisseur 2>&1 | grep -E "error" || true
  [[ -x $app/Contents/MacOS/Convertisseur ]] || { echo "✗ La compilation a échoué"; exit 1; }

  # Python autonome + bibliothèques
  tar xzf $(python_archive ${arch/arm64/aarch64}) -C $res
  local lib=$res/python/lib/python3.12
  $HOST_PY -m pip install -q --disable-pip-version-check --no-compile --only-binary=:all: \
    --python-version 3.12 --implementation cp $platforms --target $lib/site-packages -r requirements.txt

  # Allègement : tout ce qui ne sert pas au moteur
  rm -rf $res/python/include $res/python/share $res/python/lib/{tcl,tk,itcl,thread}*(N) \
         $lib/{test,idlelib,tkinter,turtledemo,ensurepip,lib2to3,pydoc_data} \
         $lib/lib-dynload/_tkinter*(N) $lib/site-packages/pip*(N)
  find $res/python -name __pycache__ -prune -exec rm -rf {} +
  # Bytecode pré-compilé (sans vérification de date) : rien n'est écrit dans l'app au lancement.
  $HOST_PY -m compileall -q -j 0 --invalidation-mode unchecked-hash $lib >/dev/null || true

  cp convert.py $res/
  cp build/Convertisseur.icns $res/

  # Actions rapides, générées depuis le modèle ; l'app les installe au premier lancement.
  mkdir -p $res/services
  for script in quick-action/*.sh(N); do
    local name=${script:t:r}
    [[ $name == common ]] && continue
    local wf=$res/services/$name.workflow
    cp -R quick-action/template.workflow $wf
    plutil -replace NSServices.0.NSMenuItem.default -string "$name" $wf/Contents/Info.plist
    plutil -replace actions.0.action.ActionParameters.COMMAND_STRING \
      -string "$(sed "s/BUNDLE_ID/$BUNDLE_ID/g" quick-action/common.sh; cat $script)" $wf/Contents/document.wflow
  done

  cat > $app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Convertisseur</string>
  <key>CFBundleDisplayName</key><string>Convertisseur</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Convertisseur</string>
  <key>CFBundleIconFile</key><string>Convertisseur</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
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

  codesign --force --deep -s - $app 2>/dev/null || true
}

mkdir -p build
swift app/make-icon.swift build/Convertisseur.iconset
iconutil -c icns build/Convertisseur.iconset -o build/Convertisseur.icns

if [[ ${1:-} == --release ]]; then
  for arch in arm64 x86_64; do
    build_app $arch
    rm -f build/Convertisseur-$arch.zip
    ditto -c -k --keepParent build/$arch/Convertisseur.app build/Convertisseur-$arch.zip
    echo "✓ build/Convertisseur-$arch.zip ($(du -h build/Convertisseur-$arch.zip | cut -f1))"
  done
  exit 0
fi

build_app $HOST_ARCH
osascript -e 'quit app "Convertisseur"' 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/Convertisseur.app
cp -R build/$HOST_ARCH/Convertisseur.app ~/Applications/
defaults delete $BUNDLE_ID servicesVersion 2>/dev/null || true  # l'app réinstalle les actions rapides au lancement
echo "✓ Installé : ~/Applications/Convertisseur.app (v$VERSION)"
