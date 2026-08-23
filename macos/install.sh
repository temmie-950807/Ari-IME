#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install the built input method into the current user's Input Methods folder.
set -euo pipefail

readonly APP_NAME="AriIME.app"
build_dir="${ARI_MACOS_BUILD_DIR:-build-macos}"
source_app="${build_dir}/${APP_NAME}"
target_dir="${HOME}/Library/Input Methods"
target_app="${target_dir}/${APP_NAME}"

if [ ! -d "${source_app}" ]; then
    echo "error: ${source_app} not found. Build it first:" >&2
    echo "  cmake --build ${build_dir}" >&2
    exit 1
fi

if ! codesign --verify "${source_app}" 2>/dev/null; then
    echo "error: ${source_app} is not signed. Apple Silicon will refuse to" >&2
    echo "       run it. Rebuild, or sign it with: codesign --force --sign - ${source_app}" >&2
    exit 1
fi

mkdir -p "${target_dir}"

if [ -e "${target_app}" ]; then
    echo "==> replacing the existing ${APP_NAME}"
    # The running server holds the old bundle open; stopping it first keeps the
    # replacement from being half-applied.
    killall AriIME 2>/dev/null || true
    rm -rf "${target_app}"
fi

cp -R "${source_app}" "${target_app}"
echo "==> installed to ${target_app}"

cat <<'EOF'

Next: log out and log back in.

macOS only rescans ~/Library/Input Methods at login, so the entry will not
appear in System Settings until then. After logging back in:

  System Settings > Keyboard > Text Input > Input Sources > Edit > + > Ari IME

This applies to updates too, not just the first install.
EOF
