// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#ifndef ARI_IME_USER_DATA_H
#define ARI_IME_USER_DATA_H

#include <filesystem>
#include <string>
#include <system_error>
#include <vector>

namespace ari_ime {

// Directory holding per-user, mutable data for Ari IME. This contains only the
// user's learned/personalized state, not libchewing's built-in dictionary.
std::filesystem::path userDataDir();

// Path to the per-user libchewing dictionary that stores learned phrase and
// homophone preferences for Ari IME.
std::filesystem::path userDictionaryPath();

// Path to Ari's small, portable list of phrases the user explicitly selected,
// imported, or added through Ari's dictionary API. This is deliberately
// separate from libchewing's learned frequency database, whose entries cannot
// be distinguished from deliberate preferences through the old C API.
std::filesystem::path userPreferencePath();

// Whether automatic per-user learning is enabled for this process.
bool autoLearnEnabled();

// Ensure the per-user data directory exists and non-destructively seed
// libchewing 0.12's standard chewing.dat from Ari's legacy userdict.dat when
// needed. Returns false only when setup or migration fails.
bool ensureUserDataDir(std::error_code &ec);

// --- Text templates -------------------------------------------------------
//
// A short code the user types to insert a longer piece of text: an address, a
// signature, an email. Several templates may share one code, in which case they
// are offered as candidates.
struct Template {
    std::string title;   // free-form label, shown beside the code
    std::string code;    // what the user types
    std::string content; // what gets inserted; may contain newlines
};

// Path to the tab-separated template file: title<TAB>code<TAB>content, with a
// literal backslash-n standing for a newline inside the content.
std::filesystem::path templatesPath();

// Templates in file order. A missing file yields an empty list rather than an
// error; malformed lines are skipped so one bad hand-edit cannot lock the user
// out of the rest.
std::vector<Template> loadTemplates();

// Whether a code is usable. Digits are excluded because the candidate window
// numbers its rows, and those numbers have to keep selecting candidates.
bool validTemplateCode(const std::string &code);

// Process-wide template cache. Deliberately not a Buffer member: one Buffer
// exists per client application, and per-client copies would each answer from
// their own stale snapshot after an edit.
class TemplateStore {
public:
    // Re-read the file. Called when the user has edited it.
    void reload();
    // Templates whose code starts with `code`, best (shortest code) first.
    // An empty code matches everything, so the bare prefix key lists them all.
    std::vector<Template> matching(const std::string &code);

private:
    void ensureLoaded();
    std::vector<Template> templates_;
    bool loaded_ = false;
};

TemplateStore &templateStore();

// --- Long phrases ---------------------------------------------------------
//
// Whole sentences the user has typed often enough to be worth completing. The
// count is what makes a phrase eligible; there is no separate pending file,
// so raising a count by hand promotes a phrase and deleting the line forgets it.
struct LongPhrase {
    int count = 0;
    std::string text;
};

std::filesystem::path longPhrasesPath();
std::vector<LongPhrase> loadLongPhrases();

// Replace the stored phrases wholesale. Used by the importer; ordinary learning
// goes through LongPhraseStore::bump().
bool saveLongPhrases(const std::vector<LongPhrase> &phrases);

// Process-wide, for the same reason as TemplateStore: the counts have to be
// shared across client applications or each would overwrite the others'.
class LongPhraseStore {
public:
    // Record one more sighting of a phrase, persisting immediately.
    void bump(const std::string &text);
    // Phrases that begin with `prefix` and have been seen enough times,
    // most-seen first. Returns the remaining text, not the whole phrase.
    std::vector<std::string> suggest(const std::string &prefix, std::size_t limit);
    void reload();

private:
    void ensureLoaded();
    bool savePhrases();
    std::vector<LongPhrase> phrases_;
    bool loaded_ = false;
};

LongPhraseStore &longPhraseStore();

// A phrase needs this many sightings before it is offered.
inline constexpr int kLongPhraseMinCount = 3;
// Shorter runs are ordinary words that the dictionary already handles.
inline constexpr int kLongPhraseMinChars = 7;
// Long enough to cover a sentence; past this it is a paragraph, not a phrase.
inline constexpr int kLongPhraseMaxChars = 30;

// Remove Ari IME's learned user dictionary and explicit-preference sidecar.
// Missing files are treated as success. Built-in/system dictionary resources
// are untouched.
bool resetUserDictionary(std::error_code &ec);

} // namespace ari_ime

#endif // ARI_IME_USER_DATA_H
