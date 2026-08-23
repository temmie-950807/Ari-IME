// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
//
// Key translation is where a macOS port quietly goes wrong: backspace and
// forward delete are reversed relative to X11, letter case lives in a different
// string depending on which modifiers are held, and the keypad cannot be
// identified from modifier flags. Each of those has a case below.
//
// The two character arguments mirror what AppKit reports: `characters` has
// every modifier applied, `charactersIgnoringModifiers` has Control, Option and
// Command removed — and, in practice, the letter case with them.
#import <Carbon/Carbon.h>
#import <Cocoa/Cocoa.h>

#include <cassert>
#include <cstdio>
#include <cstdlib>

#include <fcitx-utils/keysym.h>

#import "KeyMap.h"

namespace {

void expectKeyFrom(unsigned short keyCode, NSString *characters,
                   NSString *ignoringModifiers, NSEventModifierFlags flags,
                   fcitx::KeySym expectedSym, std::uint32_t expectedStates,
                   const char *what) {
    const fcitx::Key key =
        AriKeyFromParts(keyCode, characters, ignoringModifiers, flags);
    if (key.sym() != expectedSym || key.states().bits() != expectedStates) {
        std::fprintf(stderr,
                     "%s: got sym=0x%x states=0x%x, want sym=0x%x states=0x%x\n",
                     what, key.sym(), key.states().bits(), expectedSym,
                     expectedStates);
        std::abort();
    }
}

// For keys where AppKit reports the same string either way.
void expectKey(unsigned short keyCode, NSString *characters,
               NSEventModifierFlags flags, fcitx::KeySym expectedSym,
               std::uint32_t expectedStates, const char *what) {
    expectKeyFrom(keyCode, characters, characters, flags, expectedSym,
                  expectedStates, what);
}

constexpr std::uint32_t kShift = static_cast<std::uint32_t>(fcitx::KeyState::Shift);
constexpr std::uint32_t kCtrl = static_cast<std::uint32_t>(fcitx::KeyState::Ctrl);
constexpr std::uint32_t kAlt = static_cast<std::uint32_t>(fcitx::KeyState::Alt);
constexpr std::uint32_t kSuper = static_cast<std::uint32_t>(fcitx::KeyState::Super);

} // namespace

int main(void) {
    @autoreleasepool {
        // macOS labels the backspace key "Delete" and reports 0x7F for it.
        // Reversing this pair makes backspace delete forwards.
        expectKey(kVK_Delete, @"", 0, FcitxKey_BackSpace, 0, "backspace");
        expectKey(kVK_ForwardDelete, @"", 0, FcitxKey_Delete, 0,
                  "forward delete");
        // Shift+forward-delete reaches the core as the forget-this-candidate key.
        expectKey(kVK_ForwardDelete, @"", NSEventModifierFlagShift,
                  FcitxKey_Delete, kShift, "shift+forward delete");

        // Typing letters: `characters` already carries the case, and it must
        // survive so Shift+A produces a capital in the middle of Chinese input.
        expectKeyFrom(kVK_ANSI_A, @"a", @"a", 0, 'a', 0, "a");
        expectKeyFrom(kVK_ANSI_A, @"A", @"a", NSEventModifierFlagShift, 'A',
                      kShift, "shift+a is uppercase");
        expectKeyFrom(kVK_ANSI_A, @"A", @"a", NSEventModifierFlagCapsLock, 'A', 0,
                      "capslock+a is uppercase");
        expectKeyFrom(kVK_ANSI_A, @"a", @"a",
                      NSEventModifierFlagCapsLock | NSEventModifierFlagShift, 'a',
                      kShift, "capslock+shift+a is lowercase");
        // Shift on a digit selects a different symbol, which is layout data —
        // it must be taken from the reported characters, not derived.
        expectKeyFrom(kVK_ANSI_1, @"!", @"1", NSEventModifierFlagShift, '!',
                      kShift, "shift+1 is the shifted symbol");
        expectKeyFrom(kVK_ANSI_9, @"(", @"9", NSEventModifierFlagShift, '(',
                      kShift, "shift+9 is an open parenthesis");
        expectKeyFrom(kVK_ANSI_0, @")", @"0", NSEventModifierFlagShift, ')',
                      kShift, "shift+0 is a close parenthesis");

        // Adding Control must not lose the shifted symbol, or the temporary
        // Chinese-punctuation gesture has nothing to convert.
        expectKeyFrom(kVK_ANSI_9, @"(", @"9",
                      NSEventModifierFlagShift | NSEventModifierFlagControl, '(',
                      kShift | kCtrl, "control+shift+9 keeps the parenthesis");
        expectKeyFrom(kVK_ANSI_0, @")", @"0",
                      NSEventModifierFlagShift | NSEventModifierFlagControl, ')',
                      kShift | kCtrl, "control+shift+0 keeps the parenthesis");
        expectKeyFrom(kVK_ANSI_Comma, @"<", @",",
                      NSEventModifierFlagShift | NSEventModifierFlagControl, '<',
                      kShift | kCtrl, "control+shift+comma");
        expectKeyFrom(kVK_ANSI_Quote, @"\"", @"'",
                      NSEventModifierFlagShift | NSEventModifierFlagControl, '"',
                      kShift | kCtrl, "control+shift+apostrophe");

        // Control turns a letter into a control code and Option produces an
        // accented symbol; only then does the bare key come from the other
        // string, with the case reapplied from the flags.
        expectKeyFrom(kVK_ANSI_Z, @"\x1a", @"z", NSEventModifierFlagControl,
                      FcitxKey_z, kCtrl, "control+z undo needs lowercase z");
        expectKeyFrom(kVK_ANSI_Z, @"\x1a", @"z",
                      NSEventModifierFlagControl | NSEventModifierFlagShift, 'Z',
                      kCtrl | kShift, "control+shift+z is uppercase");
        expectKeyFrom(kVK_ANSI_LeftBracket, @"“", @"[", NSEventModifierFlagOption,
                      FcitxKey_bracketleft, kAlt, "option+[ corner quote");
        expectKeyFrom(kVK_ANSI_RightBracket, @"‘", @"]",
                      NSEventModifierFlagOption, FcitxKey_bracketright, kAlt,
                      "option+] corner quote");
        expectKeyFrom(kVK_ANSI_V, @"v", @"v", NSEventModifierFlagCommand, 'v',
                      kSuper, "command+v stays with the application");

        // The keypad is identified by key code. NSEventModifierFlagNumericPad
        // is also set for the arrow keys, so it cannot be used for this.
        expectKey(kVK_ANSI_Keypad0, @"0", NSEventModifierFlagNumericPad,
                  FcitxKey_KP_0, 0, "keypad 0");
        expectKey(kVK_ANSI_Keypad9, @"9", NSEventModifierFlagNumericPad,
                  FcitxKey_KP_9, 0, "keypad 9");
        expectKey(kVK_ANSI_KeypadDecimal, @".", NSEventModifierFlagNumericPad,
                  FcitxKey_KP_Decimal, 0, "keypad decimal");
        expectKey(kVK_ANSI_KeypadEnter, @"", NSEventModifierFlagNumericPad,
                  FcitxKey_KP_Enter, 0, "keypad enter");
        expectKey(kVK_LeftArrow, @"", NSEventModifierFlagNumericPad,
                  FcitxKey_Left, 0, "left arrow sets the numeric pad flag too");

        // Editing and navigation keys come from key codes, because a MacBook
        // synthesises Home/End/PageUp/PageDown from Fn+arrow.
        expectKey(kVK_Return, @"\r", 0, FcitxKey_Return, 0, "return");
        expectKey(kVK_Escape, @"", 0, FcitxKey_Escape, 0, "escape");
        expectKey(kVK_Space, @" ", 0, FcitxKey_space, 0, "space");
        expectKey(kVK_Space, @" ", NSEventModifierFlagControl, FcitxKey_space,
                  kCtrl, "control+space");
        expectKey(kVK_Home, @"", 0, FcitxKey_Home, 0, "home");
        expectKey(kVK_End, @"", 0, FcitxKey_End, 0, "end");
        expectKey(kVK_PageUp, @"", 0, FcitxKey_Page_Up, 0, "page up");
        expectKey(kVK_PageDown, @"", 0, FcitxKey_Page_Down, 0, "page down");
        expectKey(kVK_UpArrow, @"", 0, FcitxKey_Up, 0, "up arrow");
        expectKey(kVK_DownArrow, @"", 0, FcitxKey_Down, 0, "down arrow");

        // The core reads Shift+Tab straight off Tab plus the Shift bit, so no
        // ISO_Left_Tab needs synthesising.
        expectKey(kVK_Tab, @"\t", 0, FcitxKey_Tab, 0, "tab");
        expectKey(kVK_Tab, @"\t", NSEventModifierFlagShift, FcitxKey_Tab, kShift,
                  "shift+tab");

        // Nothing actionable: the caller must let the application have the key.
        expectKey(kVK_ANSI_A, @"", 0, 0, 0, "no characters");
        expectKey(kVK_F1, @"", 0, 0, 0, "function key");
        assert(AriKeyFromNSEvent(nil).sym() == 0 && "nil event must be inert");

        std::puts("keymap test passed");
    }
    return 0;
}
