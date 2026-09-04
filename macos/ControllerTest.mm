// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
//
// Drives AriInputController with synthetic NSEvents and a stand-in client, so
// the front end can be checked without the system having activated the input
// method (which only happens at login).
//
// What this does NOT cover: IMK's own event routing into handleEvent:, and the
// IMKCandidates panel, which needs a real IMKServer. Those still need a manual
// pass in a real application.
#import <Carbon/Carbon.h>
#import <Cocoa/Cocoa.h>
#import <InputMethodKit/InputMethodKit.h>

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <system_error>

#import "AriInputController.h"

#include "layout.h"
#include "user_data.h"

#pragma mark - Stand-in client

@interface AriTestClient : NSObject
@property(nonatomic, copy) NSString *committed;
@property(nonatomic, copy) NSString *markedText;
@property(nonatomic, strong) NSAttributedString *markedAttributed;
@property(nonatomic) NSRange markedSelection;
@end

@implementation AriTestClient

- (instancetype)init {
    if ((self = [super init])) {
        _committed = @"";
        _markedText = @"";
        _markedSelection = NSMakeRange(0, 0);
    }
    return self;
}

- (void)insertText:(id)string replacementRange:(NSRange)range {
    (void)range;
    NSString *text = [string isKindOfClass:NSAttributedString.class]
                         ? [(NSAttributedString *)string string]
                         : (NSString *)string;
    self.committed = [self.committed stringByAppendingString:text];
}

- (void)setMarkedText:(id)string
       selectionRange:(NSRange)selectionRange
     replacementRange:(NSRange)replacementRange {
    (void)replacementRange;
    if ([string isKindOfClass:NSAttributedString.class]) {
        self.markedAttributed = string;
        self.markedText = [(NSAttributedString *)string string];
    } else {
        self.markedAttributed = nil;
        self.markedText = string ?: @"";
    }
    self.markedSelection = selectionRange;
}

- (NSString *)bundleIdentifier {
    return @"org.kaiyasi.aritest.client";
}

- (NSDictionary *)attributesForCharacterIndex:(NSUInteger)index
                          lineHeightRectangle:(NSRect *)rect {
    (void)index;
    if (rect != NULL) {
        *rect = NSMakeRect(100, 400, 1, 16);
    }
    return @{};
}

@end

// The panel belongs to main.mm, which this test does not link. Returning nil
// also exercises the path where no candidate window exists, which must stay
// harmless rather than crash.
IMKCandidates *AriSharedCandidates(void) { return nil; }

#pragma mark - Helpers

namespace {

AriInputController *gController = nil;
AriTestClient *gClient = nil;

// AppKit reports two strings and they differ in a chord: `characters` has all
// modifiers applied, `charactersIgnoringModifiers` has Control/Option/Command
// removed along with the letter case.
NSEvent *makeKeyDownFrom(NSString *characters, NSString *ignoringModifiers,
                         unsigned short keyCode, NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown
                             location:NSZeroPoint
                        modifierFlags:flags
                            timestamp:0
                         windowNumber:0
                              context:nil
                           characters:characters
          charactersIgnoringModifiers:ignoringModifiers
                            isARepeat:NO
                              keyCode:keyCode];
}

NSEvent *makeKeyDown(NSString *characters, unsigned short keyCode,
                 NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown
                             location:NSZeroPoint
                        modifierFlags:flags
                            timestamp:0
                         windowNumber:0
                              context:nil
                           characters:characters
          charactersIgnoringModifiers:characters
                            isARepeat:NO
                              keyCode:keyCode];
}

NSEvent *makeFlagsChanged(unsigned short keyCode, NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType:NSEventTypeFlagsChanged
                             location:NSZeroPoint
                        modifierFlags:flags
                            timestamp:0
                         windowNumber:0
                              context:nil
                           characters:@""
          charactersIgnoringModifiers:@""
                            isARepeat:NO
                              keyCode:keyCode];
}

// kVK_ANSI_A is not in the physical-key table, so translation falls through to
// the character path, which is what typing plain text exercises.
constexpr unsigned short kCharacterKeyCode = kVK_ANSI_A;

void type(NSString *text) {
    for (NSUInteger i = 0; i < text.length; ++i) {
        NSString *one = [text substringWithRange:NSMakeRange(i, 1)];
        [gController handleEvent:makeKeyDown(one, kCharacterKeyCode, 0) client:gClient];
    }
}

void press(unsigned short keyCode, NSEventModifierFlags flags = 0) {
    [gController handleEvent:makeKeyDown(@"", keyCode, flags) client:gClient];
}

void resetSession(void) {
    [gController deactivateServer:gClient];
    gClient.committed = @"";
    gClient.markedText = @"";
    gClient.markedSelection = NSMakeRange(0, 0);
    [gController activateServer:gClient];
    gClient.committed = @"";
    gClient.markedText = @"";
}

// Candidates come back as attributed strings, because the controller paints
// the core's highlight into them itself.
NSString *plain(id candidate) {
    NSString *text = [candidate isKindOfClass:NSAttributedString.class]
                         ? [(NSAttributedString *)candidate string]
                         : candidate;
    // Rows are labelled "1. 你" so the number keys have something to match on
    // screen; the tests care about the candidate itself.
    NSRange dot = [text rangeOfString:@". "];
    return dot.location != NSNotFound && dot.location <= 1
               ? [text substringFromIndex:NSMaxRange(dot)]
               : text;
}

void expectEqual(NSString *actual, NSString *expected, const char *what) {
    if (![actual isEqualToString:expected]) {
        std::fprintf(stderr, "%s: got \"%s\", want \"%s\"\n", what,
                     actual.UTF8String, expected.UTF8String);
        std::abort();
    }
    std::printf("  ok  %-34s %s\n", what, expected.UTF8String);
}

void expectRangeLocation(NSUInteger actual, NSUInteger expected,
                         const char *what) {
    if (actual != expected) {
        std::fprintf(stderr, "%s: got %lu, want %lu\n", what,
                     (unsigned long)actual, (unsigned long)expected);
        std::abort();
    }
    std::printf("  ok  %-34s %lu\n", what, (unsigned long)expected);
}

} // namespace

#pragma mark - Tests

int main(void) {
    @autoreleasepool {
        // Line-buffered so a crash still shows how far the run got.
        std::setvbuf(stdout, nullptr, _IOLBF, 0);

        [NSApplication sharedApplication];

        // A test binary has no bundle identifier, so -standardUserDefaults
        // resolves to the installed input method's own domain. Writing there
        // would destroy the user's settings, so the controller is pointed at a
        // throwaway suite that is wiped at the end of the run.
        static NSString *const kTestSuite = @"org.kaiyasi.aritest.defaults";
        NSUserDefaults *defaults =
            [[NSUserDefaults alloc] initWithSuiteName:kTestSuite];
        [defaults removePersistentDomainForName:kTestSuite];
        AriSetDefaultsForTesting(defaults);

        // Learning is layered: ARI_IME_DISABLE_AUTOLEARN only silences
        // libchewing's own auto-learn, while Buffer still records deliberate
        // choices in Ari's sidecar. Both shift candidate order, so a leftover
        // dictionary from an earlier run would change which homophone comes
        // first. Start from an empty one.
        [defaults setBool:NO forKey:@"AutoLearn"];
        std::error_code ec;
        ari_ime::resetUserDictionary(ec);

        gClient = [AriTestClient new];
        // IMK's designated initializer rejects anything but its own client
        // proxy, so the controller is built bare and the client is passed to
        // each call instead. -client therefore returns nil here, which the
        // transient message panel already tolerates.
        gController = [[AriInputController alloc] init];
        assert(gController != nil && "controller could not be created");
        [gController activateServer:gClient];

        std::puts("composition");
        type(@"su");
        expectEqual(gClient.markedText, @"su", "untoned stays literal");
        type(@"3");
        expectEqual(gClient.markedText, @"你", "tone converts");
        expectEqual(gClient.committed, @"", "nothing committed before Return");

        press(kVK_Return);
        expectEqual(gClient.committed, @"你", "Return commits");
        expectEqual(gClient.markedText, @"", "marked text cleared on commit");

        std::puts("mixed English and Bopomofo");
        resetSession();
        type(@"linuxy04");
        assert([gClient.markedText hasPrefix:@"linux"] &&
               "English prefix must survive");
        assert(gClient.markedText.length > 5 && "a Han character must follow");
        std::printf("  ok  %-34s %s\n", "mixed pre-edit",
                    gClient.markedText.UTF8String);

        // The caret range is in UTF-16 units. Using the core's byte offset
        // directly would report 6 here instead of 2 and put the caret past the
        // end of the string.
        std::puts("caret is measured in UTF-16 units");
        resetSession();
        type(@"su3cl3");
        expectEqual(gClient.markedText, @"你好", "two syllables");
        expectRangeLocation(gClient.markedSelection.location, 2,
                            "caret at end of 你好");
        press(kVK_LeftArrow);
        expectRangeLocation(gClient.markedSelection.location, 1,
                            "caret after one Left");
        press(kVK_LeftArrow);
        expectRangeLocation(gClient.markedSelection.location, 0,
                            "caret at start");

        std::puts("editing inside the pre-edit");
        resetSession();
        type(@"su3cl3");
        press(kVK_LeftArrow);
        type(@"a");
        expectEqual(gClient.markedText, @"你a好", "insert at caret");
        press(kVK_Return);
        expectEqual(gClient.committed, @"你a好", "commit keeps insertion");

        std::puts("candidate selection");
        resetSession();
        type(@"su3");
        press(kVK_DownArrow);
        NSArray *candidates = [gController candidates:gClient];
        assert(candidates.count > 0 && candidates.count <= 9);
        expectEqual(plain(candidates[0]), @"你", "first candidate matches pre-edit");
        std::printf("  ok  %-34s %lu\n", "candidates on the page",
                    (unsigned long)candidates.count);
        // The candidate strings stay bare; the panel shows the highlight itself.
        press(kVK_DownArrow);
        assert([plain([gController candidates:gClient][0]) isEqualToString:@"你"] &&
               "candidate text must not be decorated");
        std::puts("  ok  candidate text stays undecorated");
        press(kVK_UpArrow);
        // Number keys pick within the visible page.
        type(@"2");
        expectEqual(gClient.markedText, @"妳",
                    "number key picks the bare candidate, not the marker");

        std::puts("mouse candidate activation");
        resetSession();
        type(@"su3");
        press(kVK_DownArrow);
        NSArray *page = [gController candidates:gClient];
        // A click hands back exactly what the panel displayed, numbering and all.
        NSString *clicked = page[2];
        [gController candidateSelected:[[NSAttributedString alloc]
                                           initWithString:clicked]];
        expectEqual(gClient.markedText, plain(clicked),
                    "click picks the same entry");
        // A click carrying text that is no longer on the page must be ignored.
        NSString *before = gClient.markedText;
        [gController candidateSelected:[[NSAttributedString alloc]
                                           initWithString:@"沒有這個候選"]];
        expectEqual(gClient.markedText, before, "stale click is ignored");

        std::puts("Shift alone toggles forced English");
        auto tapShift = [] {
            [gController handleEvent:makeFlagsChanged(kVK_Shift,
                                                      NSEventModifierFlagShift)
                              client:gClient];
            [gController handleEvent:makeFlagsChanged(kVK_Shift, 0) client:gClient];
        };
        // Forced English hands the keys straight back to the application: no
        // pre-edit, no underline, nothing waiting on Return.
        resetSession();
        tapShift();
        assert([gController handleEvent:makeKeyDown(@"h", kCharacterKeyCode, 0)
                                 client:gClient] == NO &&
               "forced English must not consume the key");
        type(@"su3");
        expectEqual(gClient.markedText, @"", "no pre-edit in English mode");

        // The mode is a deliberate user choice, so it survives a focus change
        // exactly as it does on Fcitx5 — Buffer::reset() leaves it alone.
        resetSession();
        type(@"su3");
        expectEqual(gClient.markedText, @"", "mode persists across focus");

        tapShift();
        resetSession();
        type(@"su3");
        expectEqual(gClient.markedText, @"你", "second tap returns to Chinese");

        // Switching into English must not strand what was already composed.
        gClient.committed = @"";
        tapShift(); // into English
        expectEqual(gClient.committed, @"你", "pending text committed on switch");
        expectEqual(gClient.markedText, @"", "pre-edit cleared on switch");
        tapShift(); // leave the session in Chinese

        // Shift used as a modifier must not toggle anything.
        resetSession();
        [gController handleEvent:makeFlagsChanged(kVK_Shift, NSEventModifierFlagShift)
                          client:gClient];
        [gController handleEvent:makeKeyDown(@"A", kCharacterKeyCode,
                                         NSEventModifierFlagShift)
                          client:gClient];
        [gController handleEvent:makeFlagsChanged(kVK_Shift, 0) client:gClient];
        expectEqual(gClient.markedText, @"A", "Shift+A types A");
        type(@"su3");
        expectEqual(gClient.markedText, @"A你", "Shift+A did not toggle mode");

        std::puts("optional English auto-commit");
        [defaults setBool:YES forKey:@"EnglishAutoCommit"];
        resetSession();
        // "linux" settles as English partway through, so it reaches the
        // application without Return — in pieces, but in order.
        type(@"linux");
        expectEqual(gClient.committed, @"linux", "English reaches the client");
        expectEqual(gClient.markedText, @"", "nothing left composing");

        // Chinese must be untouched by the option.
        resetSession();
        type(@"su3");
        expectEqual(gClient.committed, @"", "Chinese still waits for Return");
        expectEqual(gClient.markedText, @"你", "Chinese still composes");

        [defaults setBool:NO forKey:@"EnglishAutoCommit"];
        resetSession();
        type(@"linux");
        expectEqual(gClient.committed, @"", "off by default: English waits");
        expectEqual(gClient.markedText, @"linux", "English stays in the pre-edit");
        [defaults removeObjectForKey:@"EnglishAutoCommit"];
        [gController activateServer:gClient];

        std::puts("mode is remembered per application");
        resetSession();
        assert(!gController.ariIsForcedEnglishForTesting);
        tapShift(); // choose English for this client
        assert(gController.ariIsForcedEnglishForTesting);
        resetSession(); // deactivate + activate, as a focus change would
        assert(gController.ariIsForcedEnglishForTesting &&
               "English must be restored for this application");
        std::puts("  ok  English restored on refocus");
        tapShift(); // back to Chinese, and remember that instead
        resetSession();
        assert(!gController.ariIsForcedEnglishForTesting &&
               "Chinese must be restored once chosen");
        std::puts("  ok  Chinese restored on refocus");
        [defaults removeObjectForKey:@"PerApplicationEnglishMode"];

        // Losing focus while a template code is being typed must discard it.
        // The shared path synthesises a Return to commit the pre-edit, which
        // here would pick whichever template is highlighted and insert it.
        std::puts("template mode is discarded on focus loss");
        {
            std::ofstream out(ari_ime::templatesPath().c_str(),
                              std::ios::binary | std::ios::trunc);
            out << "# Ari IME templates v1\n信箱\ttem\ta@b.com\n";
        }
        ari_ime::templateStore().reload();
        resetSession();
        [gController handleEvent:makeKeyDown(@"`", kVK_ANSI_Grave, 0)
                          client:gClient];
        type(@"tem");
        gClient.committed = @"";
        [gController deactivateServer:gClient];
        expectEqual(gClient.committed, @"", "an unchosen template must not commit");
        [gController activateServer:gClient];

        std::puts("focus loss commits instead of dropping text");
        resetSession();
        type(@"su3");
        [gController deactivateServer:gClient];
        expectEqual(gClient.committed, @"你", "deactivate commits the pre-edit");

        std::puts("keyboard layout setting");
        resetSession();
        // Dvorak: og3 is 你 where the default layout uses su3.
        [defaults setInteger:5 forKey:@"KeyboardLayout"]; // KeyboardLayout::Dvorak
        [gController activateServer:gClient];
        assert(ari_ime::currentKeyboardLayout() == ari_ime::KeyboardLayout::Dvorak);
        gClient.markedText = @"";
        type(@"og3");
        expectEqual(gClient.markedText, @"你", "Dvorak og3");
        [defaults removeObjectForKey:@"KeyboardLayout"];
        [gController activateServer:gClient];

        std::puts("punctuation");
        resetSession();
        type(@",");
        expectEqual(gClient.markedText, @",", "plain comma stays half-width");
        press(kVK_Escape);
        // Control+Shift is the default temporary Chinese punctuation gesture;
        // Shift turns the comma key into '<' before it reaches the core.
        [gController handleEvent:makeKeyDown(@"<", kVK_ANSI_Comma,
                                         NSEventModifierFlagControl |
                                             NSEventModifierFlagShift)
                          client:gClient];
        expectEqual(gClient.markedText, @"，", "Ctrl+Shift+comma is full-width");

        resetSession();
        // Option+[ produces “ in `characters`; the bare bracket has to come
        // from the other string.
        [gController handleEvent:makeKeyDownFrom(@"\u201c", @"[",
                                                 kVK_ANSI_LeftBracket,
                                                 NSEventModifierFlagOption)
                          client:gClient];
        expectEqual(gClient.markedText, @"「」", "Option+[ pairs the quote");
        expectRangeLocation(gClient.markedSelection.location, 1,
                            "caret sits between the halves");

        // Parentheses need Shift already, so the gesture is Control+Shift+9.
        // charactersIgnoringModifiers reports the bare digit here, which is why
        // the shifted symbol has to be read from `characters`.
        resetSession();
        [gController handleEvent:makeKeyDownFrom(@"(", @"9", kVK_ANSI_9,
                                                 NSEventModifierFlagShift |
                                                     NSEventModifierFlagControl)
                          client:gClient];
        expectEqual(gClient.markedText, @"（）", "Ctrl+Shift+9 pairs");
        resetSession();
        [gController handleEvent:makeKeyDownFrom(@")", @"0", kVK_ANSI_0,
                                                 NSEventModifierFlagShift |
                                                     NSEventModifierFlagControl)
                          client:gClient];
        expectEqual(gClient.markedText, @"）", "a lone closing bracket stands alone");

        // Plain Shift+9 stays half-width, as ordinary punctuation should.
        resetSession();
        [gController handleEvent:makeKeyDownFrom(@"(", @"9", kVK_ANSI_9,
                                                 NSEventModifierFlagShift)
                          client:gClient];
        expectEqual(gClient.markedText, @"(", "Shift+9 stays half-width");

        std::puts("uppercase while composing Chinese");
        resetSession();
        type(@"su3");
        [gController handleEvent:makeKeyDownFrom(@"A", @"a", kVK_ANSI_A,
                                                 NSEventModifierFlagShift)
                          client:gClient];
        expectEqual(gClient.markedText, @"你A", "Shift+letter is uppercase");
        [gController handleEvent:makeKeyDownFrom(@"b", @"b", kVK_ANSI_B, 0)
                          client:gClient];
        expectEqual(gClient.markedText, @"你Ab", "unshifted letter stays lower");

        // Shift on its own as the punctuation gesture: Shift+comma yields ，
        // instead of <. Symbols with no Chinese form keep their ASCII value.
        [defaults setInteger:(NSInteger)ari_ime::ChinesePunctuationShortcut::Shift
                      forKey:@"ChinesePunctuationShortcut"];
        resetSession();
        [gController handleEvent:makeKeyDown(@"<", kVK_ANSI_Comma,
                                             NSEventModifierFlagShift)
                          client:gClient];
        expectEqual(gClient.markedText, @"，", "Shift+comma alone is full-width");
        press(kVK_Escape);
        // Unshifted keys must stay untouched by the gesture.
        type(@",");
        expectEqual(gClient.markedText, @",", "plain comma still half-width");
        [defaults removeObjectForKey:@"ChinesePunctuationShortcut"];
        [gController activateServer:gClient];

        [defaults removePersistentDomainForName:kTestSuite];
        std::puts("personal dictionary");
        // rememberPreferredPhrase() honours this at call time, while
        // libchewing's own auto-learn was fixed when the context was built —
        // so clearing it now enables deliberate additions without turning on
        // the implicit learning that would reorder candidates mid-test.
        unsetenv("ARI_IME_DISABLE_AUTOLEARN");

        resetSession();
        type(@"su3cl3");
        // Control+Shift+D: Control turns 'd' into 0x04, so the bare key has to
        // come from charactersIgnoringModifiers and the case from the flags.
        [gController handleEvent:makeKeyDownFrom(@"\x04", @"d", kVK_ANSI_D,
                                                 NSEventModifierFlagControl |
                                                     NSEventModifierFlagShift)
                          client:gClient];
        {
            NSArray<NSDictionary<NSString *, NSString *> *> *entries =
                [gController ariUserPhrases];
            BOOL found = NO;
            for (NSDictionary<NSString *, NSString *> *entry in entries) {
                if ([entry[@"phrase"] isEqualToString:@"你好"]) {
                    found = YES;
                    expectEqual(entry[@"reading"], @"ㄋㄧˇ ㄏㄠˇ",
                                "reading is canonical Bopomofo");
                }
            }
            assert(found && "Ctrl+Shift+D must add the composed word");
            std::printf("  ok  %-34s %s\n", "Ctrl+Shift+D adds the word", "你好");
        }

        // Mixed or English text has no reading for every character, so it is
        // refused rather than stored half-formed.
        resetSession();
        type(@"abc");
        [gController handleEvent:makeKeyDownFrom(@"\x04", @"d", kVK_ANSI_D,
                                                 NSEventModifierFlagControl |
                                                     NSEventModifierFlagShift)
                          client:gClient];
        for (NSDictionary<NSString *, NSString *> *entry in
             [gController ariUserPhrases]) {
            assert(![entry[@"phrase"] isEqualToString:@"abc"] &&
                   "English must not enter the dictionary");
        }
        std::printf("  ok  %-34s\n", "English is refused");

        // The manager window drives these three directly.
        assert([gController ariAddPhrase:@"測試詞" reading:@"ㄘㄜˋ ㄕˋ ㄘˊ"]);
        {
            BOOL found = NO;
            for (NSDictionary<NSString *, NSString *> *entry in
                 [gController ariUserPhrases]) {
                found = found || [entry[@"phrase"] isEqualToString:@"測試詞"];
            }
            assert(found && "added phrase must be listed");
        }
        std::printf("  ok  %-34s\n", "add then list");

        assert([gController ariForgetPhrase:@"測試詞"]);
        for (NSDictionary<NSString *, NSString *> *entry in
             [gController ariUserPhrases]) {
            assert(![entry[@"phrase"] isEqualToString:@"測試詞"] &&
                   "forgotten phrase must be gone");
        }
        std::printf("  ok  %-34s\n", "forget removes it");

        setenv("ARI_IME_DISABLE_AUTOLEARN", "1", 1);

        // The mode badge has to stay readable in both appearances. It used to
        // fill itself from a vibrancy material, which samples the document
        // behind the window, so its background followed the page while the
        // label followed the system appearance: a white page under Dark Mode
        // put white text on a near-white badge. Both colours now come from the
        // one effectiveAppearance, which is what makes this measurable at all.
        for (NSAppearanceName name in @[ NSAppearanceNameAqua,
                                         NSAppearanceNameDarkAqua ]) {
            const double contrast = AriHUDContrastForTesting(
                [NSAppearance appearanceNamed:name]);
            std::printf("  ok  %-34s %.1f:1\n", name.UTF8String, contrast);
            assert(contrast >= 4.5 && "the mode badge must stay readable");
        }

        std::puts("\ncontroller test passed");
    }
    return 0;
}
