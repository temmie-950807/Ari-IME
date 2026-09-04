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
    echo "==> updating the existing ${APP_NAME} in place"
    # The running server holds the old bundle open; stopping it first keeps the
    # replacement from being half-applied.
    killall AriIME 2>/dev/null || true
    # Deliberately not `rm -rf` followed by a fresh copy. Removing the bundle
    # takes the input source out of the system's registry, and macOS only
    # rescans ~/Library/Input Methods at login — so the entry disappears from
    # the input-source menu and cannot be selected until the next login, which
    # looks exactly like the update having broken the input method. rsync
    # replaces the contents without the bundle directory ever ceasing to exist.
    rsync -a --delete "${source_app}/" "${target_app}/"
else
    cp -R "${source_app}" "${target_app}"
fi
echo "==> installed to ${target_app}"


cat <<EOF

Check it took: the input-source menu ends with the running build, and

  ${target_app}/Contents/MacOS/AriIME --selftest

prints the same line. Both report the copy this process actually loaded, not
whatever is on disk, so a stale server cannot look like a fresh one.

Updates need no logout: the old server was killed above and macOS starts the
new one on the next keystroke. Switch away from Ari IME and back to be sure.

If Ari-IME is missing from the input menu, adding it back is a manual step —
no command-line call can do it. TISRegisterInputSource and TISEnableInputSource
both return success without the system's enabled list ever changing, so the
only thing that works is:

  System Settings > Keyboard > Text Input > Input Sources > Edit > +
    > Traditional Chinese > Ari-IME

If it is not offered in that list, log out and back in first, then repeat:
macOS only rescans ~/Library/Input Methods at login, which is also why a
first install always needs one.
EOF
