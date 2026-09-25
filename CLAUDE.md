# Ari-IME — working notes

Traditional Chinese Bopomofo input method. One shared core in `src/`, three
front ends: Fcitx5 (Linux), InputMethodKit (macOS), WASM (web demo).

This file records what cost time to find out. The README describes the project;
this describes the traps.

## Data safety — read this first

The user has said outright: **never overwrite their settings.** It has already
happened once, and the loss was real.

Everything the user owns lives in `~/Library/Application Support/Ari IME`
(macOS) or `~/.config/ari-ime` (Linux):

| file | what it holds |
| --- | --- |
| `userdict.dat` | libchewing's user dictionary — every learned phrase |
| `preferences.tsv` | phrases the user deliberately picked; biases candidate order |
| `templates.tsv` | text templates (`` ` `` + code) |

Settings (layout, punctuation shortcut, per-app English mode) live in
`~/Library/Preferences/org.kaiyasi.inputmethod.AriIME.plist`.

**Test binaries destroy that directory.** `ControllerTest.mm` calls
`resetUserDictionary()` before every run. It gets an isolated directory from
CTest's `ENVIRONMENT` property — run by hand, the variable is unset, the
lookup falls through to the real directory, and it is erased. It now refuses to
start without `ARI_IME_USER_DATA_DIR`, but the rule stands:

- Run tests with `ctest`, never the binaries directly.
- If a binary must be run by hand, pass the directory: `./controller_test /tmp/throwaway`.
- Take checksums before and after anything that touches the data dir, and say
  in the report that they match. `md5 ~/Library/Application\ Support/Ari\ IME/*`.

Other ways the data gets written when nobody expected it:

- **libchewing rewrites `userdict.dat` whenever a context closes.** Merely
  constructing a `Buffer` against the real directory rewrites the file. This is
  why `AriIME --selftest` points at a scratch directory (`macos/main.mm`).
- **`ari-ime-dict import` merges, but also marks every imported phrase as
  "preferred"** — it inflates `preferences.tsv` from tens of entries to
  hundreds. That file means "phrases the user deliberately chose"; marking
  everything defeats it. After a recovery import, rebuild `preferences.tsv`
  from the genuine snapshots instead.

Recovery sources, in order of fidelity:

1. `.backup.<timestamp>.N/` inside the data dir — `ari-ime-dict` writes one
   before every import.
2. The Linux install on `rbin` (`~/.config/ari-ime/`) — `templates.tsv` there
   has matched the Mac's byte for byte.
3. `ari-ime-dict export` from each backup, `sort -u` the union, `import` it
   back. Use `LC_ALL=C` — the default locale collapses distinct CJK lines in
   `sort -u` and silently produces a fraction of the entries.

## Build, test, install

```sh
macos/build-libchewing-macos.sh              # once; writes build-macos-deps/
cmake -S macos -B build-macos \
    -DCHEWING_INCLUDE_DIR=$PWD/build-macos-deps/prefix/include/chewing \
    -DCHEWING_LIBRARY=$PWD/build-macos-deps/prefix/lib/libchewing.a \
    -DCHEWING_DATA_DIR=$PWD/build-macos-deps/prefix/share/libchewing
cmake --build build-macos
cd build-macos && ctest                      # keymap, controller, core_smoke
cd .. && macos/install.sh
```

`install.sh` rsyncs into the existing bundle rather than replacing it: removing
the bundle deregisters the input source, and macOS only rescans
`~/Library/Input Methods` at login, so the entry would vanish until the next
one. It also kills the running server, so **updates need no logout** — only a
first install does.

`AriIME --selftest` checks everything that would otherwise only fail after a
login: dictionary present, controller class resolvable, engine ready, localised
menu name, menu icon, and that `su3` composes.

`build-macos/ari-ime-dict` can be a **stale binary from before the namespace
rename** — it reports `data_dir /Users/…/.config/inputer` and zero entries.
`ari-ime-dict-bin` is the current one. Check the mtime before trusting output.

## Why `src/` needs no macOS code

libchewing and the user-data layer are both configured through the environment,
so the shared core compiles unchanged:

- `CHEWING_PATH` → the dictionary bundled in `Contents/Resources/chewing-data`
- `ARI_IME_USER_DATA_DIR` → overrides the platform default in `src/user_data.cpp`

`wasm/include/` holds a small shim that provides `fcitx::Key` / `KeyStates`
as types only, so `src/` builds without Fcitx5. Beware: in the real Fcitx5
headers `fcitx::KeySym` is a **scoped enum**, so `constexpr fcitx::KeySym k = '`';`
compiles against the shim and fails on Linux. Cast explicitly.

## libchewing (0.8.5, static)

- **`chewing_Reset()` memsets the context, kbtype included.** Re-assert
  `chewing_set_KBType()` after every reset or the layout silently reverts to
  大千 — this made ten of eleven keyboard layouts report themselves unavailable
  (`src/layout.cpp`), and dropped a 許氏/Dvorak user back to 大千 mid-composition
  (`src/zhuyin.cpp`).
- **`chewing_cand_choose_by_index()` takes an absolute index** spanning the
  whole candidate list, exactly like `chewing_cand_string_by_index_static()`.
  Paging to the candidate first and then passing a page-relative index applies
  the offset twice; it looks correct on page 1, where the two coincide, and
  picks the wrong character on every page after.
- `MAX_PHRASE_LEN` is 11 characters. Longer phrases are rejected silently
  (`chewing_userphrase_add` returns 0), so the importer diverts them to
  `phrases.tsv`.
- No `chewing_ack()` in this version; `ARI_IME_LIBCHEWING_LEGACY_OUTPUT` is
  defined and `ARI_IME_LEGACY_PREFERENCE_PROMOTION` deliberately is not.
- **Probing libchewing for punctuation is unreliable on keys the layout spends
  on 注音**: `,` answers ㄝ on 大千, not ，. `explicitChinesePunct()` names those
  five keys (`, . / ; -`) outright.

## InputMethodKit — what does not work

IMK's documented API is wrong in several places. Each of these was confirmed by
experiment, not by reading.

- **`candidateIdentifierAtLineNumber:` returns 0 for every row**, so
  `selectCandidateWithIdentifier:` returns `YES` while selecting nothing, and
  `selectFirstCandidate` throws `NSInvalidArgumentException`. The only thing
  that moves the highlight is `moveDown:` from a freshly populated panel.
- Because the identifier machinery is broken, **candidate numbers are drawn
  into the strings** (`"1. 你"`), and `candidateSelected:` matches against that
  same decorated form.
- **`setAttributes:` replaces the dictionary; it does not merge.** The one IMK
  hands out holds `IMKCandidatesSendServerKeyEventFirst = 1`, which routes key
  events to the controller before the panel. Dropping it hands the whole
  keyboard to the panel and nothing can be selected at all. Always layer onto
  `panel.attributes`.
- **IMK ignores the colours its own header documents.** Setting
  `NSForegroundColorAttributeName` to pure green and
  `NSBackgroundColorDocumentAttribute` to pure red changes nothing on screen —
  the values are stored in `-attributes` and never drawn.
- IMK routes menu commands through `doCommandBySelector:commandDictionary:`,
  not target/action. Toggles work without a tag; anything carrying a value is
  silently dropped if you rely on the action.
- **`TISRegisterInputSource` and `TISEnableInputSource` return success without
  the system's enabled list changing.** Adding the input source back is a GUI-only
  step: System Settings › Keyboard › Text Input › Input Sources › Edit › +.
- `kVK_Delete` is the Backspace key (macOS reports 0x7F); `kVK_ForwardDelete` is
  Delete. Translate by keyCode, not by character.

## Appearance: two colours, one source

The recurring bug on macOS, hit twice in different windows:

> A surface takes its **background** from one place and its **text** from
> another, so the two drift apart and the result is unreadable.

- `NSVisualEffectView` with `NSVisualEffectBlendingModeBehindWindow` samples
  **the document behind the window**. Its brightness follows the page while
  `NSColor.labelColor` follows the system appearance. A white page under Dark
  Mode gives white text on a near-white badge. Do not use vibrancy for anything
  that must stay readable — the mode badge now fills
  `NSColor.windowBackgroundColor` itself.
- The candidate panel is `IMKUIPanel` holding an `IMKUIGlassView` — translucent,
  same failure. Since the window belongs to this process it is reachable through
  `NSApp.windows` (match `[NSStringFromClass(w.class) hasPrefix:@"IMKUI"]`), and
  an opaque `NSView` added below every row paints the glass out. Finding no such
  window must degrade to leaving the panel alone.
- Rule of thumb: take both colours from the same `effectiveAppearance` inside
  one `performAsCurrentDrawingAppearance:` block.
  `AriHUDContrastForTesting()` measures the pair as a WCAG ratio and the
  controller test asserts 4.5:1 in both appearances.

## Distribution

`macos/package-dmg.sh` and `macos/migrate.sh` exist; their headers carry the
detail. The two facts behind both:

- **A quarantined ad-hoc-signed input method fails silently.** It appears in the
  input-source menu, can be selected, and never composes a character — no
  dialog, no log line. Anything arriving by browser, AirDrop or chat is
  quarantined, so `xattr -dr com.apple.quarantine` is not optional. Avoiding the
  step entirely needs a paid Developer ID signature plus notarisation.
- **`cfprefsd` caches the preference file.** A copied plist reads as the old one
  until `killall cfprefsd`.

`hdiutil create -srcfolder` attaches a disk-image device and fails with "Device
not configured" outside a full login session — over ssh, on a build server, from
a background job. `hdiutil makehybrid -hfs` followed by `hdiutil convert` writes
the filesystem directly and works anywhere. Mounting is subject to the same
limit, so a DMG built headlessly has to be mounted and tested by hand before it
goes anywhere.

## Repository

- `origin` → `kaiyasi/Ari-IME` (upstream, read-only in practice)
- `fork` → `temmie-950807/Ari-IME` (the user's; `rbin` updates from here)
- Work on `macos-port`.

Upstream 2.6.x renamed the namespace `inputer` → `ari_ime` and the macro prefix
`INPUTER_` → `ARI_IME_`. Old binaries and old env-var names still exist on disk
in places; see the stale `ari-ime-dict` note above.

The Linux install on `rbin` lives under `~/.local` with
`~/.config/environment.d/ari-ime.conf` for persistence. Note that
`scripts/install-local.sh:40` builds the addon path as
`$install_prefix/lib/fcitx5`, while CMake installs to
`$install_prefix/lib/<triplet>/fcitx5` on Debian. Fcitx5 then loads the older
system addon instead of the freshly built one, which looks exactly like the
build having had no effect — set the multiarch path by hand.

## Testing style

Assert-based, no framework: `macos/CoreSmokeTest.cpp` (core),
`macos/ControllerTest.mm` (front end), `macos/KeyMapTest.mm` (key translation).

A test that passes the first time it is written has proved nothing. **Break the
fix, watch the test fail, restore it** — that step has caught vacuous assertions
in this repo more than once. Say in the report that it was done.
