#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build a static libchewing for the macOS app bundle.
#
# The macOS build targets libchewing v0.8.5's portable C backend for the same
# reason the WASM package does: it needs no Rust toolchain and no external
# dictionary generator. Unlike the WASM build it needs no source patch and no
# two-stage dictionary bootstrap, because the host compiler can run the
# generator directly.
#
# Prints the three paths the CMake build needs.
set -euo pipefail

readonly CHEWING_TAG="v0.8.5"
# Deliberately not under /tmp: macOS clears it on reboot, and the app build
# holds paths into this prefix. `build-*` is already ignored by git.
# CDPATH is inherited from the caller's environment, and with it set `cd` echoes
# the directory it landed in, which would end up inside the path.
repo_root="$(unset CDPATH; cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${ARI_MACOS_BUILD_DIR:-${repo_root}/build-macos-deps}"
src_dir="${LIBCHEWING_SOURCE_DIR:-${build_dir}/src}"
prefix="${build_dir}/prefix"

for tool in cmake git; do
    command -v "${tool}" >/dev/null 2>&1 || {
        echo "error: ${tool} is required" >&2
        exit 2
    }
done

if [ ! -d "${src_dir}" ]; then
    echo "==> cloning libchewing ${CHEWING_TAG}"
    git clone --depth 1 --branch "${CHEWING_TAG}" \
        https://github.com/chewing/libchewing.git "${src_dir}"
fi

echo "==> configuring"
cmake -S "${src_dir}" -B "${build_dir}/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DWITH_RUST=OFF \
    -DWITH_SQLITE3=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_OSX_ARCHITECTURES="${ARI_MACOS_ARCHS:-arm64}" \
    -DCMAKE_INSTALL_PREFIX="${prefix}" >/dev/null

echo "==> building"
cmake --build "${build_dir}/build" -j"$(sysctl -n hw.ncpu)" >/dev/null
cmake --install "${build_dir}/build" >/dev/null

cat <<EOF

libchewing ${CHEWING_TAG} is ready. Configure the app with:

  cmake -S macos -B build-macos \\
    -DCHEWING_INCLUDE_DIR=${prefix}/include/chewing \\
    -DCHEWING_LIBRARY=${prefix}/lib/libchewing.a \\
    -DCHEWING_DATA_DIR=${prefix}/share/libchewing
EOF
