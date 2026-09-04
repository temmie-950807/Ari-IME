// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#ifndef ARI_MACOS_INPUT_CONTROLLER_H
#define ARI_MACOS_INPUT_CONTROLLER_H

#import <InputMethodKit/InputMethodKit.h>

// One controller per client application, mirroring the per-InputContext Buffer
// the Fcitx5 front end keeps. IMK instantiates this class by name through the
// InputMethodServerControllerClass key in Info.plist.
@interface AriInputController : IMKInputController
// Test-only window onto the mode the core is in. The mode itself lives in the
// core and is only ever changed through a key event.
@property(nonatomic, readonly) BOOL ariIsForcedEnglishForTesting;

// Personal-dictionary access for the manager window. These deliberately go
// through the controller's composing engine: a second libchewing context would
// race with it over the same dictionary files.
- (NSArray<NSDictionary<NSString *, NSString *> *> *)ariUserPhrases;
- (BOOL)ariAddPhrase:(NSString *)phrase reading:(NSString *)reading;
- (BOOL)ariForgetPhrase:(NSString *)phrase;
@end

// The candidate panel is owned by the process, not by a controller: IMK routes
// its callbacks to whichever controller is current, and one panel per client
// leaves stale windows on screen. Created in main.mm once the server exists;
// nil if the process is running outside a real input session.
IMKCandidates *AriSharedCandidates(void);

// Redirect settings storage away from the shared domain. A test binary has no
// bundle identifier of its own, so -standardUserDefaults would otherwise land
// on the installed input method's preferences and overwrite the user's choices.
void AriSetDefaultsForTesting(NSUserDefaults *defaults);

// Smallest contrast ratio between the mode badge's background and its text,
// measured under `appearance`. Exposed because the badge is the one surface
// Ari paints itself: it used to take its background from a vibrancy material,
// which samples the document behind the window, so the badge tracked the page
// while the label tracked the system appearance and a white page under Dark
// Mode produced white-on-white. A single number is enough to keep that from
// coming back.
double AriHUDContrastForTesting(NSAppearance *appearance);

#endif // ARI_MACOS_INPUT_CONTROLLER_H
