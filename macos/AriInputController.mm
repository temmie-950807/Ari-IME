// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
//
// macOS InputMethodKit front end. This is the counterpart of src/inputer.cpp:
// it owns the platform, the core owns the input logic. The mapping between the
// two is deliberately one-to-one so behaviour stays comparable across
// platforms; where a Fcitx5 concept has no macOS equivalent it is noted inline.
#import "AriInputController.h"

#import <Carbon/Carbon.h> // kVK_Shift, kVK_RightShift

#import "AriDictionaryWindow.h"
#import "KeyMap.h"

#include <string>
#include <vector>

#include <fcitx-utils/keysym.h>

#include "buffer.h"
#include "layout.h"
#include "unicode.h"
#include "user_data.h"

static NSUserDefaults *gDefaultsOverride = nil;

void AriSetDefaultsForTesting(NSUserDefaults *defaults) {
    gDefaultsOverride = defaults;
}

static NSUserDefaults *AriDefaults(void) {
    return gDefaultsOverride ?: NSUserDefaults.standardUserDefaults;
}

namespace {

NSString *toNSString(const std::string &text) {
    return [[NSString alloc] initWithBytes:text.data()
                                    length:text.size()
                                  encoding:NSUTF8StringEncoding]
               ?: @"";
}

// The core reports positions as grapheme indices, but NSRange counts UTF-16
// code units. A Han character is three bytes and one UTF-16 unit, so using the
// byte offset from graphemeOffset() directly would put the caret far past the
// end of the string.
NSUInteger utf16Offset(const std::string &text, int graphemeIndex) {
    if (graphemeIndex < 0) {
        return toNSString(text).length;
    }
    const std::size_t bytes = ari_ime::unicode::graphemeOffset(text, graphemeIndex);
    return toNSString(text.substr(0, bytes)).length;
}

} // namespace

#pragma mark - Transient message panel

// Fcitx5 pops a short-lived hint through showInputMethodInformation; macOS has
// no equivalent, so the mode toggle and the core's notification strings would
// otherwise have nowhere to go.
// The badge draws its own background rather than using NSVisualEffectView.
// Vibrancy samples whatever is behind the window, so the badge tracked the
// document's colour while the label tracked the system appearance, and the two
// drift apart: a white page under Dark Mode produced white text on a near-white
// badge. Filling a colour here puts both sides on the same effectiveAppearance,
// which is the only way they cannot disagree.
@interface AriHUDBackground : NSView
// The badge's two colours, in one place so the drawing and the contrast check
// can never be measuring different things.
+ (NSColor *)fillColor;
+ (NSColor *)textColor;
@end

@implementation AriHUDBackground

+ (NSColor *)fillColor { return NSColor.windowBackgroundColor; }
+ (NSColor *)textColor { return NSColor.labelColor; }

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath *rounded =
        [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                        xRadius:8
                                        yRadius:8];
    [AriHUDBackground.fillColor setFill];
    [rounded fill];
    // Without an edge the badge dissolves into a window of the same colour.
    [NSColor.separatorColor setStroke];
    [rounded stroke];
}
@end

// WCAG relative luminance, which is what the 4.5:1 readability threshold is
// defined against. Channels have to be linearised first; averaging the raw
// sRGB components would flatter dark backgrounds.
static double AriRelativeLuminance(NSColor *color) {
    NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    const double channel[3] = {rgb.redComponent, rgb.greenComponent,
                               rgb.blueComponent};
    double linear[3];
    for (int i = 0; i < 3; ++i) {
        linear[i] = channel[i] <= 0.03928
                        ? channel[i] / 12.92
                        : pow((channel[i] + 0.055) / 1.055, 2.4);
    }
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

double AriHUDContrastForTesting(NSAppearance *appearance) {
    __block double contrast = 0;
    [appearance performAsCurrentDrawingAppearance:^{
        const double fill = AriRelativeLuminance(AriHUDBackground.fillColor);
        const double text = AriRelativeLuminance(AriHUDBackground.textColor);
        contrast = (MAX(fill, text) + 0.05) / (MIN(fill, text) + 0.05);
    }];
    return contrast;
}

@interface AriHUD : NSObject
+ (void)show:(NSString *)message near:(id<IMKTextInput, NSObject>)client;
@end

@implementation AriHUD

static NSPanel *gHUDPanel = nil;
static NSTextField *gHUDLabel = nil;

+ (void)build {
    gHUDLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    gHUDLabel.bezeled = NO;
    gHUDLabel.editable = NO;
    gHUDLabel.selectable = NO;
    gHUDLabel.drawsBackground = NO;
    gHUDLabel.font = [NSFont systemFontOfSize:16];
    gHUDLabel.textColor = AriHUDBackground.textColor;

    gHUDPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 10, 10)
                                           styleMask:NSWindowStyleMaskBorderless
                                             backing:NSBackingStoreBuffered
                                               defer:YES];
    // NSFloatingWindowLevel only floats within its own application. An input
    // method is a background process, so at that level the panel is drawn
    // behind whatever the user is typing into and is never seen.
    gHUDPanel.level = NSPopUpMenuWindowLevel;
    gHUDPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                   NSWindowCollectionBehaviorStationary |
                                   NSWindowCollectionBehaviorFullScreenAuxiliary |
                                   NSWindowCollectionBehaviorIgnoresCycle;
    gHUDPanel.opaque = NO;
    gHUDPanel.backgroundColor = NSColor.clearColor;
    gHUDPanel.hasShadow = YES;
    gHUDPanel.ignoresMouseEvents = YES;
    // Showing the hint must never steal focus from the application being typed
    // into, or the composition it is describing would be torn down.
    gHUDPanel.becomesKeyOnlyIfNeeded = YES;
    gHUDPanel.hidesOnDeactivate = NO;

    AriHUDBackground *background =
        [[AriHUDBackground alloc] initWithFrame:NSZeroRect];
    [background addSubview:gHUDLabel];
    gHUDPanel.contentView = background;
}

+ (void)show:(NSString *)message near:(id<IMKTextInput, NSObject>)client {
    if (message.length == 0) {
        return;
    }
    if (gHUDPanel == nil) {
        [self build];
    }

    gHUDLabel.stringValue = message;
    [gHUDLabel sizeToFit];

    const NSSize text = gHUDLabel.frame.size;
    const CGFloat padX = 14;
    const CGFloat padY = 9;
    // The mode hint is a single glyph, which would otherwise render as a thin
    // sliver. A floor keeps it reading as a badge, with the text centred.
    const CGFloat width = MAX(text.width, 26);
    gHUDLabel.frame =
        NSMakeRect(padX + (width - text.width) / 2, padY, text.width, text.height);

    NSRect caret = NSZeroRect;
    if ([client respondsToSelector:@selector(attributesForCharacterIndex:
                                                 lineHeightRectangle:)]) {
        [client attributesForCharacterIndex:0 lineHeightRectangle:&caret];
    }
    const NSSize panel = NSMakeSize(width + 2 * padX, text.height + 2 * padY);
    const NSRect screen = NSScreen.mainScreen.visibleFrame;

    // Below the caret when the client reports one, otherwise centred. Clients
    // that do not implement the query leave the rect empty.
    NSPoint origin = NSMakePoint(NSMidX(screen) - panel.width / 2,
                                 NSMidY(screen) - panel.height / 2);
    if (!NSIsEmptyRect(caret)) {
        origin = NSMakePoint(NSMinX(caret), NSMinY(caret) - panel.height - 8);
    }
    // Keep it on screen even when the caret sits at an edge.
    origin.x = fmax(NSMinX(screen), fmin(origin.x, NSMaxX(screen) - panel.width));
    origin.y = fmax(NSMinY(screen), fmin(origin.y, NSMaxY(screen) - panel.height));

    [gHUDPanel setFrame:NSMakeRect(origin.x, origin.y, panel.width, panel.height)
                display:YES];
    // The window is transparent, so its shadow is derived from what the content
    // view draws. Without this it keeps the previous message's outline.
    [gHUDPanel invalidateShadow];
    gHUDPanel.alphaValue = 1.0;
    [gHUDPanel orderFrontRegardless];

    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(fadeOut)
                                               object:nil];
    [self performSelector:@selector(fadeOut) withObject:nil afterDelay:0.9];
}

+ (void)fadeOut {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
      context.duration = 0.25;
      gHUDPanel.animator.alphaValue = 0.0;
    }
        completionHandler:^{
          [gHUDPanel orderOut:nil];
        }];
}

@end

#pragma mark - Input controller

@implementation AriInputController {
    Buffer _buffer;
    BOOL _engineErrorLogged;
    // Set while Shift is held alone; any other key or modifier clears it. See
    // -handleFlagsChanged:client:.
    BOOL _shiftAlonePending;
    BOOL _englishAutoCommit;
    // Callbacks that carry no sender — candidateSelected: and the menu actions —
    // still have to reach the right client. -client is not usable for that: it
    // depends on IMK having built this controller through its own initialiser.
    __weak id _currentClient;
}

- (BOOL)ariIsForcedEnglishForTesting {
    return _buffer.isForcedEnglish();
}

#pragma mark Event routing

- (NSUInteger)recognizedEvents:(id)sender {
    (void)sender;
    // Flags-changed events are needed for the Shift-alone mode toggle. Asking
    // for more than key-down also means IMK stops handling mouse-down for us,
    // which -commitComposition: covers.
    return NSEventMaskKeyDown | NSEventMaskFlagsChanged;
}

- (BOOL)handleEvent:(NSEvent *)event client:(id)sender {
    // IMK can hand over a nil event (FB11472618); treat it as a focus loss.
    if (event == nil) {
        [self commitComposition:sender];
        return NO;
    }
    _currentClient = sender;
    if (event.type == NSEventTypeFlagsChanged) {
        return [self handleFlagsChanged:event client:sender];
    }
    if (event.type != NSEventTypeKeyDown) {
        return NO;
    }

    // A real keystroke ends any pending Shift-alone gesture.
    _shiftAlonePending = NO;

    if (!_buffer.engineReady() && !_engineErrorLogged) {
        _engineErrorLogged = YES;
        NSLog(@"[Ari] 注音引擎載入失敗，暫以英文輸入");
        [AriHUD show:@"注音引擎載入失敗，暫以英文輸入" near:_currentClient];
    }

    // Forced English is a request for the keyboard to behave as if no input
    // method were installed, so the keys go straight to the application. The
    // Fcitx5 build still holds them in a pre-edit until Return, but on macOS an
    // underlined, uncommitted run of English is exactly what the mode is meant
    // to get rid of. Ari keeps only the Shift gesture that turns it back off.
    if (_buffer.isForcedEnglish()) {
        return NO;
    }

    const fcitx::Key key = AriKeyFromNSEvent(event);
    if (key.sym() == 0) {
        return NO;
    }
    // Teach the composed word to the personal dictionary. The core hands any
    // Control chord straight back to the application, so this is intercepted
    // here rather than in the state machine.
    if (key.sym() == 'D' && key.states().test(fcitx::KeyState::Ctrl) &&
        key.states().test(fcitx::KeyState::Shift)) {
        return [self applyResult:_buffer.addPreeditToUserDictionary()
                          client:sender];
    }
    const BOOL handled = [self applyResult:_buffer.handleKey(key) client:sender];

    // Optional: release English the moment the state machine has ruled out
    // 注音, so an application's completion can see it without waiting for
    // Return. This costs the tone-peeling that produces acer螢 from aceru/6,
    // and it cannot help words like "ls" or "npm", which stay valid 注音 key
    // sequences to the end and never settle.
    if (handled && _englishAutoCommit && _buffer.isSettledEnglish()) {
        [self flushComposition:sender clearMarkedText:YES];
    }
    return handled;
}

// macOS reserves Control+Space for "select the previous input source" before
// the event reaches an input method, so the core's mode toggle needs a
// different gesture. Tapping Shift on its own is the platform convention; it is
// translated back into the Control+Space the core already understands.
- (BOOL)handleFlagsChanged:(NSEvent *)event client:(id)sender {
    const unsigned short code = event.keyCode;
    const NSEventModifierFlags flags = event.modifierFlags;
    const BOOL isShiftKey = (code == kVK_Shift || code == kVK_RightShift);
    const NSEventModifierFlags companions =
        flags & (NSEventModifierFlagControl | NSEventModifierFlagOption |
                 NSEventModifierFlagCommand | NSEventModifierFlagFunction);

    if (!isShiftKey || companions != 0) {
        _shiftAlonePending = NO;
    } else if (flags & NSEventModifierFlagShift) {
        _shiftAlonePending = YES; // pressed
    } else if (_shiftAlonePending) {
        _shiftAlonePending = NO; // released with nothing in between
        [self applyResult:_buffer.handleKey(fcitx::Key(
                              FcitxKey_space,
                              fcitx::KeyStates{fcitx::KeyState::Ctrl}))
                   client:sender];
        // Switching into English stops routing keys through the core, so
        // whatever was composed has to be committed now or it would be
        // stranded in a pre-edit nothing can reach.
        if (_buffer.isForcedEnglish()) {
            [self commitComposition:sender];
        }
        [self rememberModeForClient:sender];
    }
    // Never swallow a modifier event: the application needs to see it.
    return NO;
}

// The result must be applied before `handled` is consulted: the core can return
// handled=false together with updateUI=true when it closes the candidate window
// and hands the key back to the application.
- (BOOL)applyResult:(const KeyResult &)result client:(id)sender {
    if (result.hasCommit && !result.commitText.empty()) {
        [self commitText:result.commitText client:sender];
    }
    if (result.notifyMode) {
        [AriHUD show:(_buffer.isForcedEnglish() ? @"En" : @"中")
                near:_currentClient];
    }
    if (!result.notification.empty()) {
        [AriHUD show:toNSString(result.notification) near:_currentClient];
    }
    if (result.updateUI) {
        [self refreshComposition:sender];
    }
    return result.handled;
}

#pragma mark Composition

- (void)refreshComposition:(id)sender {
    const std::string preedit = _buffer.preeditText();
    NSString *text = toNSString(preedit);

    if (text.length == 0) {
        [self clearMarkedText:sender];
        [self refreshCandidateWindow];
        return;
    }

    NSMutableAttributedString *marked =
        [[NSMutableAttributedString alloc] initWithString:text];
    [marked addAttribute:NSUnderlineStyleAttributeName
                   value:@(NSUnderlineStyleSingle)
                   range:NSMakeRange(0, text.length)];

    // A thick underline on the focused cell is the platform convention for
    // "this is the segment being edited". It partially replaces the auxiliary
    // line the Fcitx5 front end draws, which IMK has no equivalent for.
    const int selected = _buffer.selectionChar();
    if (selected >= 0) {
        const NSUInteger start = utf16Offset(preedit, selected);
        const NSUInteger end = utf16Offset(preedit, selected + 1);
        if (end > start && end <= text.length) {
            [marked addAttribute:NSUnderlineStyleAttributeName
                           value:@(NSUnderlineStyleThick)
                           range:NSMakeRange(start, end - start)];
        }
    }

    const NSUInteger caret = utf16Offset(preedit, _buffer.caretChar());
    [sender setMarkedText:marked
           selectionRange:NSMakeRange(caret, 0)
         replacementRange:NSMakeRange(NSNotFound, 0)];

    [self refreshCandidateWindow];
}

- (void)commitText:(const std::string &)text client:(id)sender {
    [sender insertText:toNSString(text)
      replacementRange:NSMakeRange(NSNotFound, 0)];
    [self clearMarkedText:sender];
}

- (void)clearMarkedText:(id)sender {
    [sender setMarkedText:@""
           selectionRange:NSMakeRange(0, 0)
         replacementRange:NSMakeRange(NSNotFound, 0)];
}

// IMK calls this when focus moves, the user clicks elsewhere, or the input
// source changes. Committing through a synthesised Return keeps the core's
// single commit path — including its learning pass — instead of splicing the
// pre-edit text out from under it.
- (void)commitComposition:(id)sender {
    [self flushComposition:sender clearMarkedText:YES];
}

// clearMarkedText is skipped on the way out of a session: by then the client
// can no longer act on it, and the request would only discard the text that
// was just committed.
- (void)flushComposition:(id)sender clearMarkedText:(BOOL)clearMarked {
    // In template mode the pre-edit is a code being typed, not text on its way
    // to the application. Synthesising a Return here would pick whichever
    // template happens to be highlighted and insert it on focus loss.
    if (_buffer.isTemplateMode()) {
        _buffer.reset();
        if (clearMarked) {
            [self clearMarkedText:sender];
        }
        [self refreshCandidateWindow];
        return;
    }
    if (_buffer.preeditText().empty()) {
        return;
    }
    const KeyResult result = _buffer.handleKey(fcitx::Key(FcitxKey_Return));
    if (result.hasCommit && !result.commitText.empty()) {
        [sender insertText:toNSString(result.commitText)
          replacementRange:NSMakeRange(NSNotFound, 0)];
    }
    if (clearMarked) {
        [self clearMarkedText:sender];
    }
    _buffer.reset();
    [self refreshCandidateWindow];
}

#pragma mark Candidates

- (NSArray *)candidates:(id)sender {
    (void)sender;
    // IMKCandidates raises CandidateWindowNoCandidatesException if this returns
    // nothing while the panel is being shown, so it must stay in step with what
    // -refreshCandidateWindow feeds to setCandidateData:.
    return [self numberedCandidates];
}

// The core selects by number key, so the numbers have to be on screen. The
// panel will not put them there: its own numbering is tied to the identifier
// machinery that already proved unreliable here, so they are drawn into the
// text where they cannot be lost.
- (NSArray<NSString *> *)numberedCandidates {
    NSArray<NSString *> *page = [self currentCandidateStrings];
    NSMutableArray<NSString *> *numbered =
        [NSMutableArray arrayWithCapacity:page.count];
    for (NSUInteger i = 0; i < page.count; ++i) {
        // Only the first nine are reachable by key; a longer page would be a
        // core change, but the labels should not promise what does not work.
        if (i < 9) {
            [numbered addObject:[NSString stringWithFormat:@"%lu. %@",
                                                           (unsigned long)i + 1,
                                                           page[i]]];
        } else {
            [numbered addObject:[@"   " stringByAppendingString:page[i]]];
        }
    }
    return numbered;
}

- (NSArray<NSString *> *)currentCandidateStrings {
    const std::vector<std::string> page = _buffer.candidates();
    NSMutableArray<NSString *> *strings =
        [NSMutableArray arrayWithCapacity:page.size()];
    for (const std::string &candidate : page) {
        [strings addObject:toNSString(candidate)];
    }
    return strings;
}

- (void)refreshCandidateWindow {
    IMKCandidates *panel = AriSharedCandidates();
    const std::size_t count = _buffer.candidates().size();

    if (panel == nil) {
        return;
    }
    if (count == 0) {
        [panel hide];
        return;
    }

    // The core owns paging: candidates() only ever returns the current page, so
    // PageUp/PageDown simply replace the whole array.
    [panel setCandidateData:[self numberedCandidates]];
    [panel updateCandidates];
    if (!panel.isVisible) {
        [panel showCandidates];
    }
    [self syncHighlight:panel];
}

// IMK's identifier-based selection does not work: -candidateIdentifierAtLineNumber:
// answers 0 for every row, so -selectCandidateWithIdentifier: returns YES while
// -selectedCandidate never moves. What does work is -moveDown:, the NSResponder
// action the panel uses for its own arrow handling.
//
// -selectFirstCandidate looks like the natural way to establish a starting
// point, but it throws NSInvalidArgumentException and leaves nothing selected —
// which is why the first candidate alone used to come up unhighlighted. Feeding
// the panel a fresh array already leaves it on the first row, so the highlight
// only ever has to walk down from there.
- (void)syncHighlight:(IMKCandidates *)panel {
    const int highlight = _buffer.highlight();
    for (int i = 0; i < highlight; ++i) {
        [panel moveDown:nil];
    }
}

// Mouse or trackpad activation. IMK gives only the string, so the index is
// recovered from the page the core currently exposes; a click that arrives
// after the page changed simply finds no match and is ignored, which is the
// same protection the Fcitx5 front end gets from selectCandidate's expected-text
// overload.
- (void)candidateSelected:(NSAttributedString *)candidateString {
    // Compare against the numbered forms that were handed to the panel, so the
    // label never has to be parsed back off.
    const NSUInteger index =
        [[self numberedCandidates] indexOfObject:candidateString.string];
    if (index == NSNotFound) {
        return;
    }
    NSArray<NSString *> *page = [self currentCandidateStrings];
    if (index >= page.count) {
        return;
    }
    const std::string expected = page[index].UTF8String;
    [self applyResult:_buffer.selectCandidate(static_cast<int>(index), expected)
               client:_currentClient];
}

#pragma mark Personal dictionary

- (NSArray<NSDictionary<NSString *, NSString *> *> *)ariUserPhrases {
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *entries =
        [NSMutableArray array];
    for (const UserPhrase &entry : _buffer.userPhrases()) {
        [entries addObject:@{
            @"phrase" : toNSString(entry.phrase),
            @"reading" : toNSString(entry.reading)
        }];
    }
    return entries;
}

- (BOOL)ariAddPhrase:(NSString *)phrase reading:(NSString *)reading {
    if (phrase.length == 0 || reading.length == 0) {
        return NO;
    }
    return _buffer.addUserPhrase(phrase.UTF8String, reading.UTF8String);
}

- (BOOL)ariForgetPhrase:(NSString *)phrase {
    return phrase.length > 0 && _buffer.forgetUserPhrase(phrase.UTF8String);
}

#pragma mark Settings

// The Fcitx5 build gets a configuration page from fcitx5-configtool. macOS has
// no equivalent host, so the input-source menu plus NSUserDefaults stands in
// for it. The settings themselves are the core's, not new ones.
namespace {

NSString *const kLayoutKey = @"KeyboardLayout";
NSString *const kFullWidthKey = @"FullWidthPunctuation";
NSString *const kPunctuationShortcutKey = @"ChinesePunctuationShortcut";
NSString *const kSpaceCandidateKey = @"SpaceCandidateMode";
NSString *const kAutoLearnKey = @"AutoLearn";
NSString *const kPerAppModeKey = @"PerApplicationEnglishMode";
NSString *const kEnglishAutoCommitKey = @"EnglishAutoCommit";

constexpr ari_ime::KeyboardLayout kLayouts[] = {
    ari_ime::KeyboardLayout::Default,       ari_ime::KeyboardLayout::Eten,
    ari_ime::KeyboardLayout::Hsu,           ari_ime::KeyboardLayout::Ibm,
    ari_ime::KeyboardLayout::GinYieh,       ari_ime::KeyboardLayout::Dvorak,
    ari_ime::KeyboardLayout::Carpalx,       ari_ime::KeyboardLayout::ColemakDhAnsi,
    ari_ime::KeyboardLayout::ColemakDhOrth, ari_ime::KeyboardLayout::Workman,
    ari_ime::KeyboardLayout::Colemak,
};

// The Fcitx5 build reads these from layout.h's i18n annotations, which the
// headless header shim compiles away, so the display names live here.
NSString *const kPunctuationShortcutNames[] = {
    @"Ctrl+Shift", @"Alt+Shift", @"Ctrl", @"Alt", @"Shift", @"停用"};

// IMKTextInput answers -bundleIdentifier, but it is not in the public header,
// so ask before calling and fall back to whatever is frontmost.
NSString *clientBundleIdentifier(id client) {
    if ([client respondsToSelector:@selector(bundleIdentifier)]) {
        NSString *identifier = [client performSelector:@selector(bundleIdentifier)];
        if (identifier.length > 0) {
            return identifier;
        }
    }
    return NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;
}

// A menu action reaches the controller either straight from AppKit (sender is
// the item) or routed by IMK. Which of those happens is not something to guess
// at: an action that cannot find its item silently drops the user's choice,
// which is how the layout and punctuation settings were being lost while the
// plain on/off items saved correctly.
NSMenuItem *menuItemFrom(id sender) {
    if ([sender isKindOfClass:NSMenuItem.class]) {
        return sender;
    }
    if ([sender isKindOfClass:NSDictionary.class]) {
        NSDictionary *info = sender;
        id item = info[kIMKCommandMenuItemName];
        if ([item isKindOfClass:NSMenuItem.class]) {
            return item;
        }
        for (id value in info.allValues) {
            if ([value isKindOfClass:NSMenuItem.class]) {
                return value;
            }
        }
        NSLog(@"[Ari] menu action: no NSMenuItem in %@", info.allKeys);
    } else {
        NSLog(@"[Ari] menu action: unexpected sender %@", [sender class]);
    }
    return nil;
}

} // namespace

- (void)applySettings {
    NSUserDefaults *defaults = AriDefaults();
    [defaults registerDefaults:@{kAutoLearnKey : @YES}];

    const NSInteger layoutIndex = [defaults integerForKey:kLayoutKey];
    ari_ime::KeyboardLayout layout =
        (layoutIndex >= 0 && layoutIndex < (NSInteger)std::size(kLayouts))
            ? kLayouts[layoutIndex]
            : ari_ime::KeyboardLayout::Default;
    if (!ari_ime::keyboardLayoutAvailable(layout)) {
        layout = ari_ime::KeyboardLayout::Default;
    }
    // Note this resets the pre-edit and writes process-global state, so every
    // controller reapplies it when it becomes active.
    _buffer.setKeyboardLayout(layout);

    _buffer.setFullWidthPunct([defaults boolForKey:kFullWidthKey]);
    _buffer.setSpaceCandidateMode([defaults boolForKey:kSpaceCandidateKey]);
    _buffer.setLearningAllowed([defaults boolForKey:kAutoLearnKey]);
    _englishAutoCommit = [defaults boolForKey:kEnglishAutoCommitKey];

    const NSInteger shortcutIndex =
        [defaults integerForKey:kPunctuationShortcutKey];
    _buffer.setChinesePunctuationShortcut(
        (shortcutIndex >= 0 &&
         shortcutIndex <= (NSInteger)ari_ime::ChinesePunctuationShortcut::Disabled)
            ? static_cast<ari_ime::ChinesePunctuationShortcut>(shortcutIndex)
            : ari_ime::ChinesePunctuationShortcut::ControlShift);
}

// Typing into a terminal is the case this exists for: a shell command held in
// a pre-edit is invisible to the application, so its completion never fires.
// Rather than give up mixed input everywhere, Ari remembers the mode each
// application was last left in — switch a terminal to English once and it stays
// English, while a browser or editor stays Chinese.
- (void)restoreModeForClient:(id)sender {
    NSString *bundle = clientBundleIdentifier(sender);
    if (bundle.length == 0) {
        return;
    }
    NSDictionary *modes =
        [AriDefaults() dictionaryForKey:kPerAppModeKey];
    NSNumber *remembered = modes[bundle];
    if (remembered == nil) {
        return;
    }
    [self setForcedEnglish:remembered.boolValue client:sender];
}

- (void)rememberModeForClient:(id)sender {
    NSString *bundle = clientBundleIdentifier(sender);
    if (bundle.length == 0) {
        return;
    }
    NSUserDefaults *defaults = AriDefaults();
    NSMutableDictionary *modes =
        [([defaults dictionaryForKey:kPerAppModeKey] ?: @{}) mutableCopy];
    modes[bundle] = @(_buffer.isForcedEnglish());
    [defaults setObject:modes forKey:kPerAppModeKey];
}

// The core owns the mode and only flips it through Control+Space, so reaching a
// specific state means synthesising that key rather than writing a flag.
- (void)setForcedEnglish:(BOOL)english client:(id)sender {
    if (_buffer.isForcedEnglish() == english) {
        return;
    }
    [self flushComposition:sender clearMarkedText:YES];
    _buffer.handleKey(
        fcitx::Key(FcitxKey_space, fcitx::KeyStates{fcitx::KeyState::Ctrl}));
}

- (void)doCommandBySelector:(SEL)aSelector
          commandDictionary:(NSDictionary *)infoDictionary {
    NSMenuItem *item = menuItemFrom(infoDictionary);
    if (item != nil && [self respondsToSelector:aSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:aSelector withObject:item];
#pragma clang diagnostic pop
        return;
    }
    [super doCommandBySelector:aSelector commandDictionary:infoDictionary];
}

- (NSMenu *)menu {
    NSUserDefaults *defaults = AriDefaults();
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Ari IME"];

    NSMenu *layouts = [[NSMenu alloc] initWithTitle:@"鍵盤配置"];
    const NSInteger current = [defaults integerForKey:kLayoutKey];
    for (NSInteger i = 0; i < (NSInteger)std::size(kLayouts); ++i) {
        if (!ari_ime::keyboardLayoutAvailable(kLayouts[i])) {
            continue;
        }
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:@(ari_ime::keyboardLayoutName(kLayouts[i]))
                   action:@selector(ariSelectKeyboardLayout:)
            keyEquivalent:@""];
        item.tag = i;
        item.target = self;
        item.state = (i == current) ? NSControlStateValueOn : NSControlStateValueOff;
        [layouts addItem:item];
    }
    NSMenuItem *layoutRoot = [[NSMenuItem alloc] initWithTitle:@"鍵盤配置"
                                                       action:nil
                                                keyEquivalent:@""];
    layoutRoot.submenu = layouts;
    [menu addItem:layoutRoot];

    NSMenu *shortcuts = [[NSMenu alloc] initWithTitle:@"中文標點快捷鍵"];
    const NSInteger currentShortcut = [defaults integerForKey:kPunctuationShortcutKey];
    for (NSInteger i = 0; i < (NSInteger)std::size(kPunctuationShortcutNames); ++i) {
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:kPunctuationShortcutNames[i]
                   action:@selector(ariSelectPunctuationShortcut:)
            keyEquivalent:@""];
        item.tag = i;
        item.target = self;
        item.state =
            (i == currentShortcut) ? NSControlStateValueOn : NSControlStateValueOff;
        [shortcuts addItem:item];
    }
    NSMenuItem *shortcutRoot = [[NSMenuItem alloc] initWithTitle:@"中文標點快捷鍵"
                                                         action:nil
                                                  keyEquivalent:@""];
    shortcutRoot.submenu = shortcuts;
    [menu addItem:shortcutRoot];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *(^toggle)(NSString *, SEL, NSString *) =
        ^NSMenuItem *(NSString *title, SEL action, NSString *key) {
      NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                    action:action
                                             keyEquivalent:@""];
      item.target = self;
      item.state = [defaults boolForKey:key] ? NSControlStateValueOn
                                             : NSControlStateValueOff;
      return item;
    };
    [menu addItem:toggle(@"標點一律全形（免按 Shift）",
                         @selector(ariToggleFullWidthPunctuation:),
                         kFullWidthKey)];
    [menu addItem:toggle(@"Space 開啟候選", @selector(ariToggleSpaceCandidateMode:),
                         kSpaceCandidateKey)];
    [menu addItem:toggle(@"本機學習", @selector(ariToggleAutoLearn:), kAutoLearnKey)];

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *dictionary =
        [[NSMenuItem alloc] initWithTitle:@"個人詞庫…"
                                   action:@selector(ariShowDictionary:)
                            keyEquivalent:@""];
    dictionary.target = self;
    [menu addItem:dictionary];

    // Templates are edited as a plain text file. A table view would be a lot of
    // window code for something that is three tab-separated columns; opening it
    // in the user's editor covers the whole feature and reloads on demand.
    NSMenuItem *templates =
        [[NSMenuItem alloc] initWithTitle:@"文字範本…"
                                   action:@selector(ariEditTemplates:)
                            keyEquivalent:@""];
    templates.target = self;
    [menu addItem:templates];
    [menu addItem:toggle(@"英文自動送出", @selector(ariToggleEnglishAutoCommit:),
                         kEnglishAutoCommitKey)];

    return menu;
}

- (void)ariSelectKeyboardLayout:(id)sender {
    NSMenuItem *item = menuItemFrom(sender);
    if (item == nil) {
        return;
    }
    [AriDefaults() setInteger:item.tag forKey:kLayoutKey];
    [self applySettings];
    [self refreshComposition:_currentClient];
    [AriHUD show:[NSString stringWithFormat:@"鍵盤 %@", item.title]
            near:_currentClient];
}

- (void)ariSelectPunctuationShortcut:(id)sender {
    NSMenuItem *item = menuItemFrom(sender);
    if (item == nil) {
        return;
    }
    [AriDefaults() setInteger:item.tag forKey:kPunctuationShortcutKey];
    [self applySettings];
    [AriHUD show:[NSString stringWithFormat:@"中文標點 %@", item.title]
            near:_currentClient];
}

- (void)ariToggleSetting:(NSString *)key label:(NSString *)label {
    NSUserDefaults *defaults = AriDefaults();
    const BOOL enabled = ![defaults boolForKey:key];
    [defaults setBool:enabled forKey:key];
    [self applySettings];
    [AriHUD show:[NSString stringWithFormat:@"%@ %@", label,
                                            enabled ? @"開啟" : @"關閉"]
            near:_currentClient];
}

- (void)ariToggleFullWidthPunctuation:(id)sender {
    (void)sender;
    [self ariToggleSetting:kFullWidthKey label:@"標點一律全形"];
}

- (void)ariToggleSpaceCandidateMode:(id)sender {
    (void)sender;
    [self ariToggleSetting:kSpaceCandidateKey label:@"Space 開啟候選"];
}

- (void)ariShowDictionary:(id)sender {
    (void)sender;
    [AriDictionaryWindow showForController:self];
}

- (void)ariEditTemplates:(id)sender {
    (void)sender;
    NSString *path = @(ari_ime::templatesPath().c_str());
    if (path.length == 0) {
        return;
    }
    // Seed a commented example on first use, so the format is discoverable
    // without documentation.
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        NSString *seed = @"# Ari IME templates v1\n"
                         @"# 一行一筆：標題<TAB>代碼<TAB>內容\n"
                         @"# 內容裡的換行寫成兩個字元 \\n，反斜線寫成 \\\\\n"
                         @"# 代碼只能用英文字母與 _ . -（數字要留給候選視窗選字）\n";
        [seed writeToFile:path
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
    }
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:path]];
    [AriHUD show:@"存檔後會自動重新載入" near:_currentClient];
}

- (void)ariToggleAutoLearn:(id)sender {
    (void)sender;
    [self ariToggleSetting:kAutoLearnKey label:@"本機學習"];
}

- (void)ariToggleEnglishAutoCommit:(id)sender {
    (void)sender;
    [self ariToggleSetting:kEnglishAutoCommitKey label:@"英文自動送出"];
}

#pragma mark Lifecycle

- (void)activateServer:(id)sender {
    _currentClient = sender;
    // setKeyboardLayout writes process-global state shared by every controller,
    // so the active one has to claim it back each time focus arrives.
    [self applySettings];
    _buffer.reset();
    _shiftAlonePending = NO;
    [self restoreModeForClient:sender];
}

- (void)deactivateServer:(id)sender {
    [self flushComposition:sender clearMarkedText:NO];
    _buffer.reset();
    _shiftAlonePending = NO;
    [AriSharedCandidates() hide];
}

@end
