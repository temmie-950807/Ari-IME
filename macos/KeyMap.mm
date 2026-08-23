// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#import "KeyMap.h"

#import <Carbon/Carbon.h> // kVK_* virtual key codes

#include <cctype>

#include <fcitx-utils/keysym.h>

namespace {

// Physical keys are matched by virtual key code rather than by the 0xF7xx
// function-key characters AppKit reports. A MacBook has no dedicated
// Home/End/PageUp/PageDown; those arrive as Fn+arrow chords whose reported
// character is not dependable, but whose key code is.
fcitx::KeySym symForKeyCode(unsigned short keyCode) {
    switch (keyCode) {
    case kVK_Return:
        return FcitxKey_Return;
    case kVK_ANSI_KeypadEnter:
        return FcitxKey_KP_Enter;
    case kVK_Tab:
        return FcitxKey_Tab;
    case kVK_Space:
        return FcitxKey_space;
    // macOS names the top-right key "Delete" but it is the backspace key, and
    // it reports 0x7F. Getting this pair backwards makes backspace delete
    // forwards, so both directions are pinned to key codes here.
    case kVK_Delete:
        return FcitxKey_BackSpace;
    case kVK_ForwardDelete:
        return FcitxKey_Delete;
    case kVK_Escape:
        return FcitxKey_Escape;
    case kVK_LeftArrow:
        return FcitxKey_Left;
    case kVK_RightArrow:
        return FcitxKey_Right;
    case kVK_DownArrow:
        return FcitxKey_Down;
    case kVK_UpArrow:
        return FcitxKey_Up;
    case kVK_Home:
        return FcitxKey_Home;
    case kVK_End:
        return FcitxKey_End;
    case kVK_PageUp:
        return FcitxKey_Page_Up;
    case kVK_PageDown:
        return FcitxKey_Page_Down;
    // A Mac keypad has no NumLock, so it always produces digits and operators.
    // The core folds these to literal ASCII that never becomes Bopomofo; the
    // twelve KP_ navigation variants it also understands cannot occur here.
    case kVK_ANSI_Keypad0:
        return FcitxKey_KP_0;
    case kVK_ANSI_Keypad1:
        return FcitxKey_KP_1;
    case kVK_ANSI_Keypad2:
        return FcitxKey_KP_2;
    case kVK_ANSI_Keypad3:
        return FcitxKey_KP_3;
    case kVK_ANSI_Keypad4:
        return FcitxKey_KP_4;
    case kVK_ANSI_Keypad5:
        return FcitxKey_KP_5;
    case kVK_ANSI_Keypad6:
        return FcitxKey_KP_6;
    case kVK_ANSI_Keypad7:
        return FcitxKey_KP_7;
    case kVK_ANSI_Keypad8:
        return FcitxKey_KP_8;
    case kVK_ANSI_Keypad9:
        return FcitxKey_KP_9;
    case kVK_ANSI_KeypadDecimal:
        return FcitxKey_KP_Decimal;
    case kVK_ANSI_KeypadDivide:
        return FcitxKey_KP_Divide;
    case kVK_ANSI_KeypadMultiply:
        return FcitxKey_KP_Multiply;
    case kVK_ANSI_KeypadMinus:
        return FcitxKey_KP_Subtract;
    case kVK_ANSI_KeypadPlus:
        return FcitxKey_KP_Add;
    case kVK_ANSI_KeypadEquals:
        return FcitxKey_KP_Equal;
    default:
        return 0;
    }
}

fcitx::KeyStates statesForFlags(NSEventModifierFlags flags) {
    std::uint32_t bits = 0;
    if (flags & NSEventModifierFlagShift) {
        bits |= static_cast<std::uint32_t>(fcitx::KeyState::Shift);
    }
    if (flags & NSEventModifierFlagControl) {
        bits |= static_cast<std::uint32_t>(fcitx::KeyState::Ctrl);
    }
    if (flags & NSEventModifierFlagOption) {
        bits |= static_cast<std::uint32_t>(fcitx::KeyState::Alt);
    }
    if (flags & NSEventModifierFlagCommand) {
        bits |= static_cast<std::uint32_t>(fcitx::KeyState::Super);
    }
    return fcitx::KeyStates(bits);
}

} // namespace

fcitx::Key AriKeyFromParts(unsigned short keyCode, NSString *characters,
                           NSString *charactersIgnoringModifiers,
                           NSEventModifierFlags flags) {
    const fcitx::KeyStates states = statesForFlags(flags);

    if (const fcitx::KeySym sym = symForKeyCode(keyCode); sym != 0) {
        return fcitx::Key(sym, states);
    }

    // `characters` is what the key actually produced, with Shift and Caps Lock
    // already applied and the layout's own shifted symbols resolved — Shift+A
    // as 'A', Shift+9 as '('. That is exactly the core's contract, so it wins
    // whenever it holds a usable printable character.
    unichar c = characters.length > 0 ? [characters characterAtIndex:0] : 0;

    // Control turns a letter into a control code and Option produces an
    // accented symbol, neither of which the core can match. Those are the cases
    // charactersIgnoringModifiers exists for.
    if (c < 33 || c > 126) {
        c = charactersIgnoringModifiers.length > 0
                ? [charactersIgnoringModifiers characterAtIndex:0]
                : 0;
        // That string has the case stripped along with the modifiers, so put it
        // back from the flags. Caps Lock plus Shift yields lowercase on macOS,
        // which makes the two an exclusive or. Only letters are adjusted: on a
        // digit or punctuation key Shift picks a different symbol entirely, and
        // that mapping belongs to the keyboard layout.
        if (c < 0x80 && std::isalpha(static_cast<unsigned char>(c))) {
            const bool shift = (flags & NSEventModifierFlagShift) != 0;
            const bool capsLock = (flags & NSEventModifierFlagCapsLock) != 0;
            c = static_cast<unichar>(
                shift != capsLock ? std::toupper(static_cast<unsigned char>(c))
                                  : std::tolower(static_cast<unsigned char>(c)));
        }
    }

    // The core treats any keysym in 33..126 as its own ASCII character.
    if (c >= 33 && c <= 126) {
        return fcitx::Key(static_cast<fcitx::KeySym>(c), states);
    }
    return fcitx::Key(0, states);
}

fcitx::Key AriKeyFromNSEvent(NSEvent *event) {
    // IMK can hand the controller a nil event (FB11472618). Reading keyCode off
    // nil yields 0, which is a real key code (kVK_ANSI_A), so guard explicitly.
    if (event == nil) {
        return fcitx::Key(0);
    }
    return AriKeyFromParts(event.keyCode, event.characters,
                           event.charactersIgnoringModifiers,
                           event.modifierFlags);
}
