// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#ifndef ARI_MACOS_DICTIONARY_WINDOW_H
#define ARI_MACOS_DICTIONARY_WINDOW_H

#import <Cocoa/Cocoa.h>

@class AriInputController;

// Browse, add and remove personal phrases. There is one window for the whole
// process, and it works through whichever controller opened it so that all
// dictionary access shares a single libchewing context.
@interface AriDictionaryWindow : NSObject
+ (void)showForController:(AriInputController *)controller;
@end

#endif // ARI_MACOS_DICTIONARY_WINDOW_H
