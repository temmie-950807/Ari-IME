#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Installed as Contents/Resources/ari-ime-dict.
#
# The tool needs libchewing's dictionary, which lives inside this bundle rather
# than in a system directory. The data directory itself needs no help:
# src/user_data.cpp resolves it to ~/Library/Application Support/Ari IME on
# macOS, so the tool and the input method always agree.
#
# This is a shell script, so it lives in Resources rather than MacOS: codesign
# treats everything under MacOS as code that must itself be signed.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
CHEWING_PATH=${CHEWING_PATH:-"${here}/chewing-data"}
export CHEWING_PATH
exec "${here}/../MacOS/ari-ime-dict-bin" "$@"
