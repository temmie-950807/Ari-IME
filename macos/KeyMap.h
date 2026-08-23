// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#ifndef ARI_MACOS_KEYMAP_H
#define ARI_MACOS_KEYMAP_H

#import <Cocoa/Cocoa.h>

#include <fcitx-utils/key.h>

// Translate one NSEvent into the (keysym, modifiers) pair the core state
// machine expects. Returns a key whose sym() is 0 when the event carries
// nothing the core can act on; callers should pass such events through to the
// application untouched.
fcitx::Key AriKeyFromNSEvent(NSEvent *event);

// Same translation from raw parts. Exposed so the tests can build synthetic
// events without going through AppKit's event constructors.
//
// Both character strings are needed. `characters` already has Shift and Caps
// Lock applied, which is what the core wants, but for a Control or Option chord
// it holds a control code or an accented symbol. `charactersIgnoringModifiers`
// gives the bare key in those cases, at the cost of dropping the case.
fcitx::Key AriKeyFromParts(unsigned short keyCode, NSString *characters,
                           NSString *charactersIgnoringModifiers,
                           NSEventModifierFlags flags);

#endif // ARI_MACOS_KEYMAP_H
