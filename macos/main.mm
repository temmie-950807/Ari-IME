// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <InputMethodKit/InputMethodKit.h>

#import "AriInputController.h"

#include <cstdio>
#include <cstring>
#include <string>

#include <fcitx-utils/keysym.h>

#include "buffer.h"
#include "layout.h"
#include "user_data.h"

// Held for the process lifetime; IMK uses it to vend controllers to clients.
static IMKServer *gServer = nil;
static IMKCandidates *gCandidates = nil;

IMKCandidates *AriSharedCandidates(void) { return gCandidates; }

// libchewing and Ari's user-data layer are both configured through the
// environment, which is why the shared core needs no macOS-specific code:
//
//   CHEWING_PATH           libchewing's documented system-dictionary override,
//                          consulted by chewing_new2(NULL, ...). Points at the
//                          copy bundled in Resources so nothing is installed.
//   ARI_IME_USER_DATA_DIR  first-choice override in src/user_data.cpp, ahead of
//                          the XDG paths that do not belong on macOS.
//
// Setting them process-wide is safe here in a way it would not be inside a
// Fcitx5 addon: an input method server is its own process and shares libchewing
// with nobody.
static void ConfigureEnvironment(void) {
    NSBundle *bundle = NSBundle.mainBundle;

    NSString *dictionary =
        [bundle.resourcePath stringByAppendingPathComponent:@"chewing-data"];
    setenv("CHEWING_PATH", dictionary.fileSystemRepresentation, 1);

    // The user-data directory needs no override: src/user_data.cpp resolves it
    // to ~/Library/Application Support/Ari IME on macOS, which keeps the input
    // method and ari-ime-dict on the same directory without either passing it.
}

// Checks everything about an installed bundle that does not require the system
// to have activated the input method. Logging out to find that a path or a
// class name in Info.plist was wrong is expensive, so `AriIME --selftest` makes
// those failures visible immediately after install.
static int RunSelfTest(void) {
    int failures = 0;
    NSBundle *bundle = NSBundle.mainBundle;

    const char *dictionary = getenv("CHEWING_PATH");
    const std::string userData = ari_ime::userDataDir().string();
    printf("bundle          : %s\n", bundle.bundlePath.UTF8String);
    printf("CHEWING_PATH    : %s\n", dictionary ?: "(unset)");
    printf("user data dir   : %s\n", userData.c_str());

    NSString *dictionaryFile =
        [@(dictionary ?: "") stringByAppendingPathComponent:@"dictionary.dat"];
    const BOOL haveDictionary =
        [NSFileManager.defaultManager fileExistsAtPath:dictionaryFile];
    printf("dictionary.dat  : %s\n", haveDictionary ? "found" : "MISSING");
    failures += haveDictionary ? 0 : 1;

    // A typo here means the system loads the bundle and then silently does
    // nothing, because IMK cannot instantiate the named controller.
    NSString *controllerName =
        [bundle objectForInfoDictionaryKey:@"InputMethodServerControllerClass"];
    const BOOL haveController = NSClassFromString(controllerName) != nil;
    printf("controller class: %s (%s)\n", controllerName.UTF8String,
           haveController ? "resolvable" : "NOT FOUND");
    failures += haveController ? 0 : 1;

    Buffer buffer;
    printf("engine ready    : %s\n", buffer.engineReady() ? "yes" : "no");
    failures += buffer.engineReady() ? 0 : 1;

    // How many layouts work depends on the bundled libchewing, so report it
    // rather than assuming all eleven are offered.
    NSMutableArray<NSString *> *layouts = [NSMutableArray array];
    for (int i = 0; i <= (int)ari_ime::KeyboardLayout::Colemak; ++i) {
        const auto layout = static_cast<ari_ime::KeyboardLayout>(i);
        if (ari_ime::keyboardLayoutAvailable(layout)) {
            [layouts addObject:@(ari_ime::keyboardLayoutName(layout))];
        }
    }
    printf("layouts (%2lu/11) : %s\n", (unsigned long)layouts.count,
           [layouts componentsJoinedByString:@", "].UTF8String);

    // Without a localised name the input-source menu shows the mode identifier
    // and the literal string "CFBundleName"; without the icon it shows an empty
    // tile. Both are only visible once the system loads the bundle, so they are
    // easy to ship broken.
    NSString *modeID =
        [bundle.bundleIdentifier stringByAppendingString:@".Zhuyin"];
    // table:nil would look in Localizable.strings; the keys here come from
    // Info.plist, so they live in InfoPlist.strings.
    NSString *localised = [bundle localizedStringForKey:modeID
                                                  value:@""
                                                  table:@"InfoPlist"];
    const BOOL named = localised.length > 0 && ![localised isEqualToString:modeID];
    printf("menu name       : %s%s\n",
           named ? localised.UTF8String : modeID.UTF8String,
           named ? "" : "   (NOT LOCALISED)");
    failures += named ? 0 : 1;

    NSString *iconName =
        [bundle objectForInfoDictionaryKey:@"ComponentInputModeDict"]
            ? @"ari.pdf"
            : nil;
    const BOOL haveIcon =
        iconName != nil &&
        [NSFileManager.defaultManager
            fileExistsAtPath:[bundle.resourcePath
                                 stringByAppendingPathComponent:iconName]];
    printf("menu icon       : %s\n", haveIcon ? "found" : "MISSING");
    failures += haveIcon ? 0 : 1;

    for (const unsigned char c : std::string("su3")) {
        buffer.handleKey(fcitx::Key(static_cast<fcitx::KeySym>(c)));
    }
    // Which character comes first depends on the user's own dictionary, so this
    // only checks that a syllable converted at all. Pinning it to 你 would fail
    // for anyone who has ever picked a different homophone — which is exactly
    // the behaviour that is supposed to work.
    const std::string preedit = buffer.preeditText();
    const bool converted =
        !preedit.empty() && static_cast<unsigned char>(preedit[0]) >= 0x80;
    printf("su3 composes to : %s%s\n", preedit.c_str(),
           converted ? "" : "   (expected a Chinese character)");
    failures += converted ? 0 : 1;

    printf("%s\n", failures == 0 ? "selftest passed" : "SELFTEST FAILED");
    return failures == 0 ? 0 : 1;
}

// Ask Text Input Sources to pick the bundle up now instead of at the next
// login, then enable and select its Bopomofo mode. Whether this fully takes
// effect without logging out varies by macOS release, so the caller still has
// to verify; the return value only reports what the API said.
static int RegisterInputSource(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    const OSStatus status =
        TISRegisterInputSource((__bridge CFURLRef)bundle.bundleURL);
    // paramErr means it is already registered, which is not a failure here.
    if (status != noErr && status != paramErr) {
        printf("TISRegisterInputSource failed: %d\n", (int)status);
        return 1;
    }

    NSDictionary *filter = @{
        (__bridge NSString *)kTISPropertyBundleID : bundle.bundleIdentifier
    };
    CFArrayRef sources =
        TISCreateInputSourceList((__bridge CFDictionaryRef)filter, true);
    if (sources == NULL || CFArrayGetCount(sources) == 0) {
        printf("no input source found for %s\n",
               bundle.bundleIdentifier.UTF8String);
        if (sources != NULL) {
            CFRelease(sources);
        }
        return 1;
    }

    int failures = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(sources); ++i) {
        TISInputSourceRef source =
            (TISInputSourceRef)CFArrayGetValueAtIndex(sources, i);
        NSString *identifier = (__bridge NSString *)(CFStringRef)
            TISGetInputSourceProperty(source, kTISPropertyInputSourceID);
        const OSStatus enabled = TISEnableInputSource(source);
        printf("%-48s enable=%d\n", identifier.UTF8String, (int)enabled);
        failures += (enabled == noErr) ? 0 : 1;
        if (enabled == noErr) {
            TISSelectInputSource(source);
        }
    }
    CFRelease(sources);

    printf("%s\n", failures == 0 ? "registered" : "REGISTRATION INCOMPLETE");
    return failures == 0 ? 0 : 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        ConfigureEnvironment();

        if (argc > 1 && strcmp(argv[1], "--selftest") == 0) {
            return RunSelfTest();
        }
        if (argc > 1 && strcmp(argv[1], "--register") == 0) {
            return RegisterInputSource();
        }

        NSBundle *bundle = NSBundle.mainBundle;
        NSString *connection =
            [bundle objectForInfoDictionaryKey:@"InputMethodConnectionName"];
        if (connection.length == 0) {
            NSLog(@"[Ari] Info.plist is missing InputMethodConnectionName");
            return 1;
        }

        [NSApplication sharedApplication];
        gServer = [[IMKServer alloc] initWithName:connection
                                 bundleIdentifier:bundle.bundleIdentifier];
        if (gServer == nil) {
            NSLog(@"[Ari] failed to create IMKServer for %@", connection);
            return 1;
        }

        // A single column of nine rows matches ari_ime::kCandPerPage, and the
        // core hands out exactly one page at a time, so the panel never needs
        // to scroll or paginate on its own.
        gCandidates = [[IMKCandidates alloc]
            initWithServer:gServer
                 panelType:kIMKSingleColumnScrollingCandidatePanel];
        // Ari decides when the panel closes; letting IMK dismiss it on its own
        // desynchronises it from the core's selection state.
        [gCandidates setDismissesAutomatically:NO];
        // Without this the panel labels its rows with whatever it defaults to;
        // the core only ever interprets 1-9 as a selection. These are virtual
        // key codes, and the ANSI layout does not order them contiguously.
        [gCandidates setSelectionKeys:@[
            @(kVK_ANSI_1), @(kVK_ANSI_2), @(kVK_ANSI_3), @(kVK_ANSI_4),
            @(kVK_ANSI_5), @(kVK_ANSI_6), @(kVK_ANSI_7), @(kVK_ANSI_8),
            @(kVK_ANSI_9)
        ]];
        NSLog(@"[Ari] candidate panel: %@", gCandidates ? @"created" : @"FAILED");

        NSLog(@"[Ari] server ready (%@)", connection);
        [NSApp run];
    }
    return 0;
}
