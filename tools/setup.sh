#!/usr/bin/env bash
# Fetch everything needed to build locally (Linux / macOS).
# The game itself is NOT downloaded: assets/game_base.pck must be present.
set -euo pipefail

cd "$(dirname "$0")/.."
GODOT_VERSION="${GODOT_VERSION:-4.7.2}"

echo "== Python deps =="
python3 -m pip install --upgrade --quiet Pillow

echo "== Android SDK build-tools (apksigner) =="
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
if ! ls "$SDK"/build-tools/*/apksigner >/dev/null 2>&1; then
  echo "  no apksigner under $SDK/build-tools"
  echo "  install via: sdkmanager 'build-tools;34.0.0'"
  echo "  or point ANDROID_HOME / ABUELA_APKSIGNER at an existing install"
else
  echo "  found: $(ls "$SDK"/build-tools/*/apksigner | tail -1)"
fi

echo "== Godot ${GODOT_VERSION} Android export template =="
if [ -f templates/android_release.apk ]; then
  echo "  already present"
else
  mkdir -p templates
  URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_export_templates.tpz"
  echo "  downloading (1.2 GB, only the android template is extracted)..."
  python3 tools/fetch_template.py "$URL" templates/android_release.apk
fi

if [ ! -f assets/game_base.pck ]; then
  echo
  echo "!! assets/game_base.pck is missing."
  echo "   Either pull it from Git LFS:   git lfs pull"
  echo "   or extract it from your own ABUELA.exe:"
  echo "     ABUELA_EXE=/path/to/ABUELA.exe python3 tools/extract_base.py"
fi

echo "== done =="
