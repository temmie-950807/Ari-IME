# Ari IME 2.6.0

This is a hardening release from a full code audit covering the input engine,
the dictionary tool, the packaging scripts, and the WebAssembly core. No
everyday typing behavior changes except for the fixes listed below, and the
complete maintainer regression suite (buffer, layout, user data, profile and
dict-tool helpers) passes against this tree.

## Engine fixes

- The Hsu layout now treats `s` as its neutral-tone key. Previously a 輕聲
  syllable such as ㄅㄚ˙ fell through to literal English.
- Full-width punctuation conversion no longer probes keys that are 注音 keys
  in the active layout; keypad `/ - .` under 全形標點 mode and invalid-syllable
  extensions commit their literal or full-width form instead of a stray
  Bopomofo glyph.
- Reinterpreting an English cell with ↑, or exploding a character to raw keys,
  clears the previous candidate list first: a phantom window wired to stale
  run indices could previously send a pick to the wrong cell.
- Pasted text is validated per grapheme cluster. Malformed UTF-8 from the
  clipboard is folded into a separator instead of reaching client
  applications, C1 controls no longer pass through invisibly, and a stray
  ZWJ can no longer glue plain ASCII neighbors into one oversized cell.

## State hygiene

- Per-character readings cached for reconversion are cleared when the keyboard
  layout changes; stale 大千 readings could otherwise be re-fed through 倚天
  and produce garbage candidates forever.
- Reading caches evict oldest-first instead of an arbitrary hash element.

## Tooling

- `ari-ime-dict import` validates that readings are canonical Bopomofo before
  touching the dictionary, reports the offending line number on both parse and
  libchewing rejection, tolerates a UTF-8 BOM, and file exports go through a
  temporary file with rename so a failed export cannot truncate an existing
  destination.
- `ari-ime-enable` resolves a symlinked Fcitx5 profile and edits its target,
  instead of silently replacing the link and detaching dotfile management.
- `ari-ime-reset-data` stamps backups with the pid and uses `mv -n`, so two
  rapid runs cannot destroy each other's safety copies.
- `install-ubuntu.sh` verifies the package checksum before `dpkg-deb` parses
  the download.
- `check.sh` cleans up its `.SRCINFO` temp file even when regeneration fails.

## WebAssembly

- Every exported C ABI function guards against exceptions escaping into JS
  frames, keeping the boundary safe even if exception unwinding is enabled in
  a future build.
- The JS wrapper rejects non-integer keysyms/modifiers and validates learning
  state types before writing them into the virtual filesystem.

Validation: strict-warning compile sweep clean (`-Wshadow -Wcast-qual
-Wdouble-promotion -Wold-style-cast`), full CTest suite green, sanitizer and
fuzz CI jobs green, package metadata consistency verified with
`makepkg --printsrcinfo`.
