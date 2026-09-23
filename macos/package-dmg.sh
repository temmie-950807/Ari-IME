#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Wrap the built input method in a .dmg that someone else can download.
#
#   macos/package-dmg.sh [OUTPUT.dmg]
#
# Read this before handing the result to anyone:
#
# The bundle is ad-hoc signed, which is not the same as unsigned but is not a
# Developer ID either. macOS quarantines anything that arrives from a browser,
# AirDrop or a messaging app, and a quarantined input method fails in the worst
# possible way — it appears in the input-source menu, can be selected, and
# never composes a character. There is no dialog and no error.
#
# So the disk image ships an installer that strips the quarantine flag, and a
# README with the same command for anyone who would rather see what is run.
# The only way to avoid the step entirely is a paid Developer ID signature plus
# notarisation; see the note at the end of the README this writes.
set -euo pipefail

readonly APP_NAME="AriIME.app"
build_dir="${ARI_MACOS_BUILD_DIR:-build-macos}"
source_app="${build_dir}/${APP_NAME}"

if [ ! -d "${source_app}" ]; then
    echo "error: ${source_app} not found. Build it first:" >&2
    echo "  cmake --build ${build_dir}" >&2
    exit 1
fi
if ! codesign --verify "${source_app}" 2>/dev/null; then
    echo "error: ${source_app} is not signed; Apple Silicon will refuse it." >&2
    echo "       codesign --force --sign - ${source_app}" >&2
    exit 1
fi

version="$(plutil -extract CFBundleShortVersionString raw \
    "${source_app}/Contents/Info.plist")"
arch="$(lipo -archs "${source_app}/Contents/MacOS/AriIME" | tr ' ' '-')"
output="${1:-AriIME-${version}-${arch}.dmg}"

staging="$(mktemp -d)"
trap 'rm -rf "${staging}"' EXIT
root="${staging}/Ari-IME"
mkdir -p "${root}"
cp -Rp "${source_app}" "${root}/"

# An input method does not live in /Applications, so the usual drag-to-a-symlink
# layout does not apply: it belongs in ~/Library/Input Methods, and a symlink to
# a path inside somebody else's home cannot be baked into a disk image.
cat > "${root}/安裝 Ari-IME.command" <<'INSTALLER'
#!/bin/bash
# Double-click this. It copies the input method into place and clears the
# quarantine flag that a downloaded ad-hoc signed bundle carries — without
# that the input method appears in the menu and silently never works.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${HOME}/Library/Input Methods"

echo "==> 安裝到 ${target}"
mkdir -p "${target}"
killall AriIME 2>/dev/null || true
rm -rf "${target}/AriIME.app"
cp -Rp "${here}/AriIME.app" "${target}/"
xattr -dr com.apple.quarantine "${target}/AriIME.app" 2>/dev/null || true

echo "==> 檢查"
"${target}/AriIME.app/Contents/MacOS/AriIME" --selftest || true

cat <<'EOF'

安裝完成。接下來：

  1. 登出再登入（macOS 只在登入時掃描輸入法資料夾，第一次裝一定要）
  2. 系統設定 > 鍵盤 > 輸入方式 > 輸入來源 > 編輯 > +
       > 繁體中文 > Ari-IME

EOF
read -n 1 -s -r -p "按任意鍵關閉這個視窗"
INSTALLER
chmod +x "${root}/安裝 Ari-IME.command"

cat > "${root}/README.txt" <<EOF
Ari-IME ${version} (${arch})
繁體中文注音輸入法
https://github.com/temmie-950807/Ari-IME

安裝
----
在這個視窗裡對「安裝 Ari-IME.command」按右鍵 > 打開 > 打開。

第一次一定要用右鍵，直接連按兩下會被 macOS 擋下來。這不是有問題，是因為
這個程式沒有付費的 Apple 開發者簽章（見下面）。

macOS 15 以上右鍵可能也會被擋。那就先按一次連按兩下，被擋之後去
系統設定 > 隱私權與安全性，往下捲會看到「仍要打開」，按它。

然後登出再登入，macOS 只在登入時掃描輸入法資料夾。回來之後：

  系統設定 > 鍵盤 > 輸入方式 > 輸入來源 > 編輯 > + > 繁體中文 > Ari-IME

不想執行腳本的話，兩行指令是一樣的事：

  cp -R /Volumes/Ari-IME/AriIME.app ~/Library/Input\\ Methods/
  xattr -dr com.apple.quarantine ~/Library/Input\\ Methods/AriIME.app

第二行不能省。下載來的檔案會被 macOS 標記隔離，被隔離的輸入法會出現在
選單裡、選得起來、但一個字都打不出來，而且不會有任何錯誤訊息。

系統需求
--------
macOS 11 以上，${arch} 架構。

為什麼要多這一步
----------------
讓 macOS 直接信任的作法是 Apple Developer ID 簽章加公證，那需要每年
99 美元的開發者帳號。這份是 ad-hoc 簽章，所以第一次需要手動放行。
放行之後就跟一般程式一樣。

授權
----
GPL-3.0-or-later。原始碼在上面的網址，裡面含有 libchewing（LGPL-2.1）。
EOF

rm -f "${output}"
# makehybrid + convert rather than `hdiutil create -srcfolder`: create attaches
# a disk-image device to lay the filesystem down, which fails outside a full
# login session ("Device not configured") — on a build server, over ssh, or
# from a background job. makehybrid writes the filesystem directly.
hdiutil makehybrid -hfs -hfs-volume-name "Ari-IME" \
    -o "${staging}/raw.dmg" "${root}" >/dev/null
hdiutil convert "${staging}/raw.dmg" -format UDZO -o "${output}" >/dev/null

echo "==> ${output} ($(du -h "${output}" | cut -f1), ${arch})"
cat <<EOF

Inside: ${APP_NAME}, 安裝 Ari-IME.command, README.txt

Before sending it anywhere, test it from the mounted image, not from the
directory it was built in. Two things only the mounted copy can tell you, and
both fail silently for the recipient:

  open "${output}"
  ls -l /Volumes/Ari-IME                       # the .command must be -rwxr-xr-x
  codesign --verify /Volumes/Ari-IME/AriIME.app
  # then right-click the installer > Open, and check the input method works


Recipients on Intel Macs need an x86_64 or universal build; this one is
${arch}. To build universal:

  ARI_MACOS_ARCHS="arm64;x86_64" macos/build-libchewing-macos.sh
  cmake -S macos -B build-macos -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" ...
EOF
