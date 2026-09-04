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

cat <<EOF

Check it took: the input-source menu ends with the running build, and

  ${target_app}/Contents/MacOS/AriIME --selftest

prints the same line. Both report the copy this process actually loaded, not
whatever is on disk, so a stale server cannot look like a fresh one.

Updates need no logout: the old server was killed above and macOS starts the
new one on the next keystroke. Switch away from Ari IME and back to be sure.

First install only: log out and back in, then add it under
  System Settings > Keyboard > Text Input > Input Sources > Edit > + > Ari IME
macOS only rescans ~/Library/Input Methods at login, so a brand-new bundle
does not appear in that list until then.
EOF
