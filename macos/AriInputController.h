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
// Canonical Bopomofo the engine derives for `phrase`, so the manager window
// can add a phrase the user typed in Han characters alone. Empty when no
// reading could be derived for every character.
- (NSString *)ariGuessReadingForPhrase:(NSString *)phrase;
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

// The style dictionary handed to IMKCandidates under `appearance`. IMK defaults
// candidate text to black and lets the document behind the panel show through,
// so both colours and the opacity have to be stated; this is exposed so a test
// can check that they were, rather than waiting for someone to notice black
// text on a black panel.
// The colour painted behind the candidate list under `appearance`. IMK draws
// the panel as translucent glass, so without this its background is the colour
// of the document behind it while its text follows the system appearance — the
// two disagree and the list becomes unreadable. Exposed so a test can check it
// stays paired with the badge, which is what the text colour is chosen against.
NSColor *AriCandidateBackdropColor(NSAppearance *appearance);

// Version and build stamp of the server that is actually running, sampled when
// the executable was loaded rather than when it is asked for.
NSString *AriRunningBuildDescription(void);

#endif // ARI_MACOS_INPUT_CONTROLLER_H
