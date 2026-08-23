# Ari IME 2.6.1

This is the Ari IME identity and packaging release. Typing behavior is
unchanged; the legacy internal identifier has been removed so KDE and Fcitx5
discover the project under its actual name.

## Identity and packaging

- The Fcitx5 display name remains `Ari IME`.
- The machine-facing addon and input method ID is now `ari-ime`.
- The installed descriptor is `ari-ime.conf`, the addon is `ari-ime.so`, and
  the icon and helper commands use the same `ari-ime` identifier.
- CMake, Arch, Debian, native release, and WebAssembly package versions are
  synchronized at `2.6.1`.

The user-data directory and environment variables also use the new `ari-ime`
names. Existing learned data from the previous directory is not migrated
automatically; copy it deliberately if it is still needed.

## WebAssembly

The `@ari-ime/wasm` package is released as version `2.6.1` together with the
native release assets. It keeps the same headless API and generated runtime
layout.

## Validation

- Release build and install smoke check
- Full CTest suite
- Native WebAssembly API test
- Arch and Debian package metadata version checks
- npm package creation and checksum generation
