#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Move an installed Ari IME, with everything it has learned, to another Mac.
#
#   old Mac:  macos/migrate.sh export ~/Desktop/ari-ime-migration.tar.gz
#   new Mac:  macos/migrate.sh import ~/Desktop/ari-ime-migration.tar.gz
#
# Three things have to travel together, and two of them are easy to forget:
#
#   the app bundle          ~/Library/Input Methods/AriIME.app
#   what it has learned     ~/Library/Application Support/Ari IME
#   how it is configured    ~/Library/Preferences/<bundle id>.plist
#
# Copying only the bundle gives a working input method that has forgotten every
# phrase, template and preference.
set -euo pipefail

readonly APP_NAME="AriIME.app"
readonly BUNDLE_ID="org.kaiyasi.inputmethod.AriIME"
readonly APP_DIR="${HOME}/Library/Input Methods"
readonly DATA_DIR="${HOME}/Library/Application Support/Ari IME"
readonly PLIST="${HOME}/Library/Preferences/${BUNDLE_ID}.plist"

usage() {
    echo "usage: $0 export|import ARCHIVE.tar.gz" >&2
    exit 2
}

[ $# -eq 2 ] || usage
mode="$1"
archive="$2"

case "${mode}" in
export)
    [ -d "${APP_DIR}/${APP_NAME}" ] || {
        echo "error: ${APP_DIR}/${APP_NAME} not found — nothing installed here." >&2
        exit 1
    }

    # The bundle is ad-hoc signed and built for one architecture. Recording it
    # lets the import side refuse a copy that could never run, instead of
    # leaving an input method that silently does nothing.
    arch="$(lipo -archs "${APP_DIR}/${APP_NAME}/Contents/MacOS/AriIME")"

    staging="$(mktemp -d)"
    trap 'rm -rf "${staging}"' EXIT
    mkdir -p "${staging}/payload"

    # -p keeps the bundle's permissions and, with it, the ad-hoc signature.
    cp -Rp "${APP_DIR}/${APP_NAME}" "${staging}/payload/"
    if [ -d "${DATA_DIR}" ]; then
        cp -Rp "${DATA_DIR}" "${staging}/payload/user-data"
    fi
    if [ -f "${PLIST}" ]; then
        cp -p "${PLIST}" "${staging}/payload/settings.plist"
    fi
    echo "${arch}" > "${staging}/payload/arch"

    tar -czf "${archive}" -C "${staging}/payload" .
    echo "==> wrote ${archive} ($(du -h "${archive}" | cut -f1), ${arch})"
    cat <<EOF

Contents:
  ${APP_NAME}       the input method itself
  user-data/        dictionary, preferred phrases, templates
  settings.plist    layout, punctuation shortcut, per-app English mode

Copy it to the new Mac and run there:

  $0 import ${archive##*/}
EOF
    ;;

import)
    [ -f "${archive}" ] || { echo "error: ${archive} not found" >&2; exit 1; }

    staging="$(mktemp -d)"
    trap 'rm -rf "${staging}"' EXIT
    tar -xzf "${archive}" -C "${staging}"
    [ -d "${staging}/${APP_NAME}" ] || {
        echo "error: ${archive} does not look like an Ari IME migration archive." >&2
        exit 1
    }

    # A bundle built for another architecture cannot be installed, but the
    # dictionary, templates and settings are only files and travel anywhere.
    # They are most of what is being migrated, so an unusable bundle stops the
    # bundle rather than the migration.
    want="$(cat "${staging}/arch" 2>/dev/null || echo unknown)"
    here="$(uname -m)"
    install_app=yes
    if [ "${want}" != "unknown" ] && [ "${want}" != "${here}" ]; then
        install_app=no
        echo "note: the archive holds a ${want} build and this Mac is ${here}."
        echo "      Bringing the data across; the app has to be built here."
    fi

    if [ "${install_app}" = yes ]; then
        # Anything that arrived by AirDrop, a download or a USB stick carries a
        # quarantine flag, and a quarantined ad-hoc-signed bundle is loaded by
        # nobody. It fails silently: the input source appears and never composes.
        xattr -dr com.apple.quarantine "${staging}/${APP_NAME}" 2>/dev/null || true
        codesign --force --sign - "${staging}/${APP_NAME}" >/dev/null 2>&1 || true
        codesign --verify "${staging}/${APP_NAME}" 2>/dev/null || {
            echo "error: the bundle is not validly signed after the copy." >&2
            exit 1
        }
    fi

    # Never overwrite data that is already here. A second Mac may have been
    # typed on before anyone got round to migrating, and that learning is as
    # real as the learning being imported.
    stamp="$(date +%Y%m%d%H%M%S)"
    for existing in "${DATA_DIR}" "${PLIST}"; do
        if [ -e "${existing}" ]; then
            mv "${existing}" "${existing}.before-migration.${stamp}"
            echo "==> kept the existing $(basename "${existing}") as .before-migration.${stamp}"
        fi
    done

    # A Mac that has never run this has none of these directories.
    mkdir -p "${APP_DIR}" "$(dirname "${DATA_DIR}")" "$(dirname "${PLIST}")"
    if [ "${install_app}" = yes ]; then
        killall AriIME 2>/dev/null || true
        rm -rf "${APP_DIR}/${APP_NAME}"
        cp -Rp "${staging}/${APP_NAME}" "${APP_DIR}/"
    fi
    if [ -d "${staging}/user-data" ]; then
        cp -Rp "${staging}/user-data" "${DATA_DIR}"
    fi
    if [ -f "${staging}/settings.plist" ]; then
        cp -p "${staging}/settings.plist" "${PLIST}"
    fi

    # cfprefsd caches preference files and will otherwise serve the state from
    # before the copy, so the imported settings would appear not to have taken.
    killall cfprefsd 2>/dev/null || true

    if [ "${install_app}" != yes ]; then
        cat <<EOF

==> data and settings are in place; the app is not.

Build it on this Mac from the same checkout:

  macos/build-libchewing-macos.sh
  cmake -S macos -B build-macos \\
      -DCHEWING_INCLUDE_DIR=... -DCHEWING_LIBRARY=... -DCHEWING_DATA_DIR=...
  cmake --build build-macos
  macos/install.sh

install.sh leaves the data alone, so what was just imported stays.
EOF
        exit 0
    fi

    echo "==> installed to ${APP_DIR}/${APP_NAME}"
    "${APP_DIR}/${APP_NAME}/Contents/MacOS/AriIME" --selftest || true

    cat <<EOF

Now log out and back in — macOS only rescans ~/Library/Input Methods at login,
so a first install on a Mac always needs one. Then add it:

  System Settings > Keyboard > Text Input > Input Sources > Edit > +
    > Traditional Chinese > Ari-IME
EOF
    ;;

*)
    usage
    ;;
esac
