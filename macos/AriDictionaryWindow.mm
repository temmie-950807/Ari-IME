// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
//
// The Fcitx5 build manages the personal dictionary with the ari-ime-dict
// command. That tool ships here too, but a window is the expected way to look
// something up or delete a mistake on macOS, so this is the same operations
// with a table in front of them.
#import "AriDictionaryWindow.h"

#import "AriInputController.h"

@interface AriDictionaryWindow () <NSTableViewDataSource, NSTableViewDelegate,
                                   NSTextFieldDelegate, NSWindowDelegate>
@end

@implementation AriDictionaryWindow {
    NSWindow *_window;
    NSTableView *_table;
    NSSearchField *_search;
    NSTextField *_phraseField;
    NSTextField *_readingField;
    NSButton *_removeButton;
    NSTextField *_status;
    NSArray<NSDictionary<NSString *, NSString *> *> *_all;
    NSArray<NSDictionary<NSString *, NSString *> *> *_visible;
    // The controller owns the engine every dictionary call goes through. Weak,
    // because IMK disposes of controllers as clients come and go; the window
    // closes itself if that happens.
    __weak AriInputController *_controller;
}

static AriDictionaryWindow *gShared = nil;

+ (void)showForController:(AriInputController *)controller {
    if (gShared == nil) {
        gShared = [[AriDictionaryWindow alloc] init];
        [gShared build];
    }
    [gShared attachToController:controller];
}

#pragma mark Construction

- (void)build {
    const NSRect frame = NSMakeRect(0, 0, 520, 420);
    _window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:YES];
    _window.title = @"Ari IME 個人詞庫";
    _window.releasedWhenClosed = NO;
    _window.delegate = self;
    [_window center];

    NSView *content = _window.contentView;
    content.autoresizesSubviews = YES;

    _search = [[NSSearchField alloc] initWithFrame:NSMakeRect(16, 376, 488, 24)];
    _search.placeholderString = @"搜尋詞或注音";
    _search.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    _search.target = self;
    _search.action = @selector(searchChanged:);
    [content addSubview:_search];

    NSScrollView *scroll =
        [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 96, 488, 268)];
    scroll.hasVerticalScroller = YES;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.borderType = NSBezelBorder;

    _table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    _table.usesAlternatingRowBackgroundColors = YES;
    _table.allowsMultipleSelection = YES;
    // Cell-based: the two columns are plain text and need no custom views.
    _table.dataSource = self;
    _table.delegate = self;

    NSTableColumn *phrase =
        [[NSTableColumn alloc] initWithIdentifier:@"phrase"];
    phrase.title = @"詞";
    phrase.width = 180;
    [_table addTableColumn:phrase];

    NSTableColumn *reading =
        [[NSTableColumn alloc] initWithIdentifier:@"reading"];
    reading.title = @"注音";
    reading.width = 280;
    [_table addTableColumn:reading];

    scroll.documentView = _table;
    [content addSubview:scroll];

    _phraseField = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 56, 150, 24)];
    _phraseField.placeholderString = @"詞";
    _phraseField.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    // Filling the reading in as soon as the phrase is finished lets a wrong
    // guess be corrected before it is stored. Deriving it costs a sweep over
    // every syllable the layout can spell on the first call, so it happens
    // once the field is done rather than on every keystroke.
    _phraseField.delegate = self;
    [content addSubview:_phraseField];

    _readingField =
        [[NSTextField alloc] initWithFrame:NSMakeRect(174, 56, 220, 24)];
    _readingField.placeholderString = @"注音（留空自動推測）";
    _readingField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [content addSubview:_readingField];

    NSButton *add = [[NSButton alloc] initWithFrame:NSMakeRect(402, 52, 102, 32)];
    add.title = @"新增";
    add.bezelStyle = NSBezelStyleRounded;
    add.target = self;
    add.action = @selector(addEntry:);
    add.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:add];

    _removeButton =
        [[NSButton alloc] initWithFrame:NSMakeRect(402, 14, 102, 32)];
    _removeButton.title = @"刪除";
    _removeButton.bezelStyle = NSBezelStyleRounded;
    _removeButton.target = self;
    _removeButton.action = @selector(removeSelected:);
    _removeButton.enabled = NO;
    _removeButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:_removeButton];

    _status = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 20, 378, 20)];
    _status.bezeled = NO;
    _status.editable = NO;
    _status.drawsBackground = NO;
    _status.textColor = NSColor.secondaryLabelColor;
    _status.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [content addSubview:_status];
}

- (void)attachToController:(AriInputController *)controller {
    _controller = controller;
    [self reload];
    // An input method is a background application, so it has to ask for the
    // foreground before its window can take keystrokes.
    [NSApp activateIgnoringOtherApps:YES];
    [_window makeKeyAndOrderFront:nil];
}

#pragma mark Data

- (void)reload {
    _all = [_controller ariUserPhrases] ?: @[];
    [self applyFilter];
}

- (void)applyFilter {
    NSString *needle = _search.stringValue;
    if (needle.length == 0) {
        _visible = _all;
    } else {
        NSMutableArray *matches = [NSMutableArray array];
        for (NSDictionary<NSString *, NSString *> *entry in _all) {
            if ([entry[@"phrase"] localizedStandardContainsString:needle] ||
                [entry[@"reading"] localizedStandardContainsString:needle]) {
                [matches addObject:entry];
            }
        }
        _visible = matches;
    }
    [_table reloadData];
    [self updateStatus];
}

- (void)updateStatus {
    _status.stringValue =
        _all.count == _visible.count
            ? [NSString stringWithFormat:@"%lu 個詞", (unsigned long)_all.count]
            : [NSString stringWithFormat:@"%lu / %lu 個詞",
                                         (unsigned long)_visible.count,
                                         (unsigned long)_all.count];
    _removeButton.enabled = _table.selectedRowIndexes.count > 0;
}

#pragma mark Actions

- (void)searchChanged:(id)sender {
    (void)sender;
    [self applyFilter];
}

// The engine derives the reading from the characters themselves, so the field
// is a correction, not an entry requirement.
- (NSString *)guessReadingFor:(NSString *)phrase {
    return [_controller ariGuessReadingForPhrase:phrase] ?: @"";
}

- (void)addEntry:(id)sender {
    (void)sender;
    NSString *phrase = [_phraseField.stringValue
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *reading = [_readingField.stringValue
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (phrase.length == 0) {
        _status.stringValue = @"請填寫詞";
        return;
    }
    // An empty field is the normal case now: derive rather than refuse. The
    // guess is all-or-nothing, so a failure names the phrase instead of
    // storing a mapping that is right for only some of its characters.
    const BOOL guessed = reading.length == 0;
    if (guessed) {
        reading = [self guessReadingFor:phrase];
        if (reading.length == 0) {
            _status.stringValue =
                [NSString stringWithFormat:@"推不出「%@」的注音，請自己填", phrase];
            return;
        }
    }
    if (![_controller ariAddPhrase:phrase reading:reading]) {
        _status.stringValue = [NSString stringWithFormat:@"無法加入「%@」", phrase];
        return;
    }
    _phraseField.stringValue = @"";
    _readingField.stringValue = @"";
    [self reload];
    _status.stringValue =
        guessed ? [NSString stringWithFormat:@"已加入「%@」%@（自動推測）", phrase,
                                             reading]
                : [NSString stringWithFormat:@"已加入「%@」", phrase];
}

#pragma mark NSTextFieldDelegate

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    if (notification.object != _phraseField) {
        return;
    }
    NSString *phrase = [_phraseField.stringValue
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    // Never overwrite a reading that was typed: the field exists precisely so
    // a 多音字 the guess gets wrong can be corrected.
    if (phrase.length == 0 || _readingField.stringValue.length > 0) {
        return;
    }
    NSString *guess = [self guessReadingFor:phrase];
    if (guess.length == 0) {
        _status.stringValue =
            [NSString stringWithFormat:@"推不出「%@」的注音，請自己填", phrase];
        return;
    }
    _readingField.stringValue = guess;
    _status.stringValue = @"注音為自動推測，多音字請先確認";
}

- (void)removeSelected:(id)sender {
    (void)sender;
    NSIndexSet *rows = _table.selectedRowIndexes;
    if (rows.count == 0) {
        return;
    }
    // Snapshot first: removing entries invalidates the visible array.
    NSMutableArray<NSString *> *targets = [NSMutableArray array];
    [rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
      (void)stop;
      if (row < self->_visible.count) {
          [targets addObject:self->_visible[row][@"phrase"]];
      }
    }];

    NSUInteger removed = 0;
    for (NSString *phrase in targets) {
        if ([_controller ariForgetPhrase:phrase]) {
            ++removed;
        }
    }
    [self reload];
    _status.stringValue =
        removed == 0 ? @"沒有可移除的個人學習紀錄"
                     : [NSString stringWithFormat:@"已移除 %lu 個詞",
                                                  (unsigned long)removed];
}

#pragma mark NSTableView

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)_visible.count;
}

- (id)tableView:(NSTableView *)tableView
    objectValueForTableColumn:(NSTableColumn *)column
                          row:(NSInteger)row {
    (void)tableView;
    if (row < 0 || (NSUInteger)row >= _visible.count) {
        return nil;
    }
    return _visible[(NSUInteger)row][column.identifier];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    [self updateStatus];
}

#pragma mark NSWindowDelegate

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    _controller = nil;
}

@end
