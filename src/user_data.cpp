// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
#include "user_data.h"

#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <stdexcept>
#include <string>

namespace inputer {

namespace {

std::filesystem::path configuredUserDataDir() {
    if (const char *overrideDir = std::getenv("INPUTER_USER_DATA_DIR");
        overrideDir && *overrideDir) {
        return std::filesystem::path(overrideDir);
    }
#if defined(__APPLE__)
    // macOS keeps per-user application state here rather than under XDG paths.
    // Deciding it in this layer keeps the input method and ari-ime-dict on the
    // same directory without either of them having to pass it in.
    if (const char *home = std::getenv("HOME"); home && *home) {
        return std::filesystem::path(home) / "Library" / "Application Support" /
               "Ari IME";
    }
#endif
    if (const char *xdg = std::getenv("XDG_CONFIG_HOME"); xdg && *xdg) {
        return std::filesystem::path(xdg) / "inputer";
    }
    if (const char *home = std::getenv("HOME"); home && *home) {
        return std::filesystem::path(home) / ".config" / "inputer";
    }
    return {};
}

// --- Escaping -------------------------------------------------------------
//
// Content is stored on one line so the file stays greppable and hand-editable
// with no multi-line record parser. Only two sequences are special.
std::string escapeContent(const std::string &text) {
    std::string out;
    out.reserve(text.size());
    for (const char c : text) {
        if (c == '\\') {
            out += "\\\\";
        } else if (c == '\n') {
            out += "\\n";
        } else if (c == '\t' || c == '\r') {
            out += ' '; // would break the field split; a space is close enough
        } else {
            out += c;
        }
    }
    return out;
}

std::string unescapeContent(const std::string &text) {
    std::string out;
    out.reserve(text.size());
    for (std::size_t i = 0; i < text.size(); ++i) {
        if (text[i] != '\\' || i + 1 >= text.size()) {
            out += text[i];
            continue;
        }
        switch (text[++i]) {
        case 'n': out += '\n'; break;
        case '\\': out += '\\'; break;
        // An unknown escape keeps both characters: a hand-written Windows path
        // should survive rather than silently lose its separators.
        default: out += '\\'; out += text[i]; break;
        }
    }
    return out;
}

// Lines are read whole; a trailing CR from a file edited on Windows would
// otherwise end up inside the last field.
std::string stripCarriageReturn(std::string line) {
    if (!line.empty() && line.back() == '\r') {
        line.pop_back();
    }
    return line;
}

// Replace a file in one step, so a crash mid-write cannot leave a half-written
// dictionary behind. Same approach as the preference sidecar in zhuyin.cpp.
bool writeAtomically(const std::filesystem::path &path, const std::string &body) {
    if (path.empty()) {
        return false;
    }
    std::error_code ec;
    ensureUserDataDir(ec);

    const std::filesystem::path temp = path.string() + ".tmp";
    {
        std::ofstream out(temp, std::ios::binary | std::ios::trunc);
        if (!out) {
            return false;
        }
        out << body;
        if (!out) {
            std::filesystem::remove(temp, ec);
            return false;
        }
    }
    std::filesystem::rename(temp, path, ec);
    if (ec) {
        std::error_code ignored;
        std::filesystem::remove(temp, ignored);
        return false;
    }
    return true;
}

// Counting characters rather than bytes keeps the limits meaningful for Han
// text. This does not need grapheme clustering: the limits are generous and
// only exist to stop a runaway paste from becoming a "template".
std::size_t utf8Length(const std::string &text) {
    std::size_t count = 0;
    for (const unsigned char c : text) {
        if ((c & 0xC0) != 0x80) {
            ++count;
        }
    }
    return count;
}

constexpr std::size_t kMaxTemplateContent = 2000;
constexpr std::size_t kMaxLongPhrases = 2000;
constexpr const char *kLongPhraseHeader = "# Ari IME long phrases v1";

} // namespace

std::filesystem::path templatesPath() {
    const std::filesystem::path dir = userDataDir();
    return dir.empty() ? std::filesystem::path{} : dir / "templates.tsv";
}

std::filesystem::path longPhrasesPath() {
    const std::filesystem::path dir = userDataDir();
    return dir.empty() ? std::filesystem::path{} : dir / "phrases.tsv";
}

bool validTemplateCode(const std::string &code) {
    if (code.empty() || code.size() > 32) {
        return false;
    }
    for (const char c : code) {
        const bool letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        if (!letter && c != '_' && c != '.' && c != '-') {
            return false;
        }
    }
    return true;
}

std::vector<Template> loadTemplates() {
    std::vector<Template> out;
    const std::filesystem::path path = templatesPath();
    if (path.empty()) {
        return out;
    }
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return out; // no templates yet is the normal first-run state
    }

    std::string line;
    while (std::getline(in, line)) {
        line = stripCarriageReturn(line);
        if (line.empty() || line[0] == '#') {
            continue;
        }
        const std::size_t first = line.find('\t');
        if (first == std::string::npos) {
            continue;
        }
        const std::size_t second = line.find('\t', first + 1);
        if (second == std::string::npos) {
            continue;
        }
        Template entry{line.substr(0, first),
                       line.substr(first + 1, second - first - 1),
                       unescapeContent(line.substr(second + 1))};
        // A bad line is dropped rather than rejected wholesale, so one typo in
        // a hand-edited file does not disable every other template.
        if (!validTemplateCode(entry.code) || entry.content.empty() ||
            utf8Length(entry.content) > kMaxTemplateContent) {
            continue;
        }
        out.push_back(std::move(entry));
    }
    return out;
}

void TemplateStore::ensureLoaded() {
    if (!loaded_) {
        reload();
    }
}

void TemplateStore::reload() {
    templates_ = loadTemplates();
    loaded_ = true;
}

std::vector<Template> TemplateStore::matching(const std::string &code) {
    ensureLoaded();
    std::vector<Template> out;
    for (const Template &entry : templates_) {
        if (entry.code.compare(0, code.size(), code) == 0) {
            out.push_back(entry);
        }
    }
    // An exact code should not sit below a longer one that merely starts the
    // same way; within one code length the file order is the user's own.
    std::stable_sort(out.begin(), out.end(),
                     [](const Template &a, const Template &b) {
                         return a.code.size() < b.code.size();
                     });
    return out;
}

TemplateStore &templateStore() {
    static TemplateStore store;
    return store;
}

std::vector<LongPhrase> loadLongPhrases() {
    std::vector<LongPhrase> out;
    const std::filesystem::path path = longPhrasesPath();
    if (path.empty()) {
        return out;
    }
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return out;
    }

    std::string line;
    while (std::getline(in, line)) {
        line = stripCarriageReturn(line);
        if (line.empty() || line[0] == '#') {
            continue;
        }
        const std::size_t tab = line.find('\t');
        if (tab == std::string::npos || tab == 0) {
            continue;
        }
        LongPhrase entry;
        try {
            entry.count = std::stoi(line.substr(0, tab));
        } catch (const std::exception &) {
            continue;
        }
        entry.text = unescapeContent(line.substr(tab + 1));
        if (entry.count <= 0 || entry.text.empty()) {
            continue;
        }
        out.push_back(std::move(entry));
    }
    return out;
}

bool saveLongPhrases(const std::vector<LongPhrase> &phrases) {
    std::string body = std::string(kLongPhraseHeader) + "\n";
    for (const LongPhrase &entry : phrases) {
        body += std::to_string(entry.count);
        body += '\t';
        body += escapeContent(entry.text);
        body += '\n';
    }
    return writeAtomically(longPhrasesPath(), body);
}

void LongPhraseStore::ensureLoaded() {
    if (!loaded_) {
        reload();
    }
}

void LongPhraseStore::reload() {
    phrases_ = loadLongPhrases();
    loaded_ = true;
}

void LongPhraseStore::bump(const std::string &text) {
    if (text.empty()) {
        return;
    }
    const std::size_t length = utf8Length(text);
    if (length < static_cast<std::size_t>(kLongPhraseMinChars) ||
        length > static_cast<std::size_t>(kLongPhraseMaxChars)) {
        return;
    }
    ensureLoaded();

    for (LongPhrase &entry : phrases_) {
        if (entry.text == text) {
            ++entry.count;
            savePhrases();
            return;
        }
    }

    if (phrases_.size() >= kMaxLongPhrases) {
        // No timestamps are kept, so the least-seen entry is the one to drop.
        const auto weakest = std::min_element(
            phrases_.begin(), phrases_.end(),
            [](const LongPhrase &a, const LongPhrase &b) { return a.count < b.count; });
        if (weakest != phrases_.end() && weakest->count > 1) {
            return; // everything left is better established than a new entry
        }
        if (weakest != phrases_.end()) {
            phrases_.erase(weakest);
        }
    }
    phrases_.push_back({1, text});
    savePhrases();
}

bool LongPhraseStore::savePhrases() { return saveLongPhrases(phrases_); }

std::vector<std::string> LongPhraseStore::suggest(const std::string &prefix,
                                                  std::size_t limit) {
    std::vector<std::string> out;
    if (prefix.empty() || limit == 0) {
        return out;
    }
    ensureLoaded();

    std::vector<const LongPhrase *> hits;
    for (const LongPhrase &entry : phrases_) {
        if (entry.count < kLongPhraseMinCount) {
            continue;
        }
        // The whole phrase must extend the prefix; an exact match has nothing
        // left to suggest.
        if (entry.text.size() <= prefix.size() ||
            entry.text.compare(0, prefix.size(), prefix) != 0) {
            continue;
        }
        hits.push_back(&entry);
    }
    std::stable_sort(hits.begin(), hits.end(),
                     [](const LongPhrase *a, const LongPhrase *b) {
                         return a->count > b->count;
                     });
    for (const LongPhrase *entry : hits) {
        if (out.size() >= limit) {
            break;
        }
        out.push_back(entry->text.substr(prefix.size()));
    }
    return out;
}

LongPhraseStore &longPhraseStore() {
    static LongPhraseStore store;
    return store;
}


std::filesystem::path userDataDir() { return configuredUserDataDir(); }

std::filesystem::path userDictionaryPath() {
    const std::filesystem::path dir = userDataDir();
    if (dir.empty()) {
        return {};
    }
    return dir / "userdict.dat";
}

std::filesystem::path userPreferencePath() {
    const std::filesystem::path dir = userDataDir();
    if (dir.empty()) {
        return {};
    }
    return dir / "preferences.tsv";
}

bool autoLearnEnabled() {
    return std::getenv("INPUTER_DISABLE_AUTOLEARN") == nullptr;
}

bool ensureUserDataDir(std::error_code &ec) {
    const std::filesystem::path dir = userDataDir();
    if (dir.empty()) {
        ec = std::make_error_code(std::errc::no_such_file_or_directory);
        return false;
    }
    std::filesystem::create_directories(dir, ec);
    if (ec) {
        return false;
    }

    // libchewing 0.12 consults CHEWING_USER_PATH/chewing.dat even when Ari
    // supplies its historical userdict.dat explicitly. Preserve the old file
    // and seed the standard name on upgrade so existing learning is retained
    // without a noisy "Dictionary file not found" diagnostic.
    const std::filesystem::path legacy = dir / "userdict.dat";
    const std::filesystem::path standard = dir / "chewing.dat";
    std::error_code inspectEc;
    if (!std::filesystem::exists(standard, inspectEc) && !inspectEc &&
        std::filesystem::exists(legacy, inspectEc) && !inspectEc) {
        std::filesystem::copy_file(legacy, standard,
                                   std::filesystem::copy_options::none, ec);
        if (ec == std::errc::file_exists) {
            ec.clear(); // another context completed the same migration
        }
    }
    return !ec;
}

bool resetUserDictionary(std::error_code &ec) {
    const std::filesystem::path dir = userDataDir();
    if (dir.empty()) {
        ec = std::make_error_code(std::errc::no_such_file_or_directory);
        return false;
    }

    const std::filesystem::path paths[] = {
        dir / "userdict.dat",
        dir / "chewing.dat",
        dir / "chewing-deleted.dat",
        dir / "preferences.tsv",
        // Every sentence the user has typed often enough to be completed —
        // more revealing than the preference list, so resetting must clear it.
        dir / "phrases.tsv",
        dir / "templates.tsv",
    };
    ec.clear();
    for (const auto &path : paths) {
        std::filesystem::remove(path, ec);
        if (ec) {
            return false;
        }
    }
    return !ec;
}

} // namespace inputer
