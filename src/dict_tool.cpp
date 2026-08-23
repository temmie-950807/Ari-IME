// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <iostream>
#include <string>
#include <string_view>
#include <system_error>
#include <unordered_set>
#include <utility>
#include <vector>

#include "unicode.h"
#include "user_data.h"
#include "unicode.h"
#include "zhuyin.h"

namespace {

constexpr std::string_view kHeader = "# Ari IME user dictionary v1";

// libchewing stops accepting user phrases past this length — measured against
// the bundled 0.8.5, where the twelfth character makes chewing_userphrase_add()
// return 0 with no error. Anything longer belongs in the long-phrase store.
constexpr int kMaxChewingPhrase = 11;

#ifndef ARI_IME_CHEWING_VERSION
#define ARI_IME_CHEWING_VERSION "unknown"
#endif

struct Entry {
    std::string phrase;
    std::string reading;
    int line = 0;
};

std::string entryKey(std::string_view phrase, std::string_view reading) {
    std::string key(phrase);
    key.push_back('\t');
    key.append(reading);
    return key;
}

void usage(std::ostream &out) {
    out << "Usage:\n"
        << "  ari-ime-dict info\n"
        << "  ari-ime-dict list\n"
        << "  ari-ime-dict export [FILE|-]\n"
        << "  ari-ime-dict import [--dry-run] FILE|-\n"
        << "  ari-ime-dict backup\n"
        << "  ari-ime-dict candidates KEYS\n\n"
        << "Export/import uses a readable UTF-8 format with canonical Bopomofo\n"
        << "readings (for example ㄋㄧˇ, not layout-specific keys such as su3).\n"
        << "Import merges entries\n"
        << "and creates a timestamped backup before changing Ari's data.\n";
}

bool hasTabOrNewline(std::string_view value) {
    return value.find('\t') != std::string_view::npos ||
           value.find('\n') != std::string_view::npos ||
           value.find('\r') != std::string_view::npos;
}

// Canonical readings contain only Bopomofo letters (U+3105–U+3129) plus one of
// the tone marks the format uses. Layout keys such as "su3", ASCII, and
// punctuation fail here with a per-line error before anything touches the
// dictionary; libchewing's own rejection stays as a belt-and-braces branch.

bool readEntries(std::istream &in, std::vector<Entry> &entries,
                 std::string &error) {
    std::string line;
    std::size_t lineNumber = 0;
    bool headerSeen = false;
    std::unordered_set<std::string> seen;

    while (std::getline(in, line)) {
        ++lineNumber;
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        if (lineNumber == 1) {
            // Tolerate the UTF-8 BOM that common editors (notably on Windows)
            // prepend; without this the header check reports a misleading
            // syntax error for three invisible bytes.
            constexpr std::string_view kBom = "\xEF\xBB\xBF";
            if (line.compare(0, kBom.size(), kBom) == 0) {
                line.erase(0, kBom.size());
            }
        }
        if (line.empty()) {
            continue;
        }
        if (line[0] == '#') {
            if (line == kHeader) {
                headerSeen = true;
            }
            continue;
        }
        if (!headerSeen) {
            error = "missing Ari IME dictionary header before line " +
                    std::to_string(lineNumber);
            return false;
        }

        const std::size_t tab = line.find('\t');
        if (tab == std::string::npos || tab == 0 || tab + 1 >= line.size() ||
            line.find('\t', tab + 1) != std::string::npos) {
            error = "expected phrase<TAB>reading on line " +
                    std::to_string(lineNumber);
            return false;
        }
        const std::string phrase = line.substr(0, tab);
        const std::string reading = line.substr(tab + 1);
        if (hasTabOrNewline(phrase) || hasTabOrNewline(reading)) {
            error = "tab/newline is not allowed inside an entry on line " +
                    std::to_string(lineNumber);
            return false;
        }
        if (!ari_ime::isCanonicalReadingForTesting(reading)) {
            error = "reading must be canonical Bopomofo (for example ㄋㄧˇ), "
                    "got \"" +
                    reading + "\" on line " + std::to_string(lineNumber);
            return false;
        }

        // Deduplicate before touching the live dictionary. The separator is
        // not valid inside either field, so this key is unambiguous.
        if (seen.insert(entryKey(phrase, reading)).second) {
            entries.push_back({phrase, reading, static_cast<int>(lineNumber)});
        }
    }
    if (!in.eof()) {
        error = "could not read the dictionary file";
        return false;
    }
    if (!headerSeen) {
        error = "missing Ari IME dictionary header";
        return false;
    }
    return true;
}

bool writeEntries(std::ostream &out, std::vector<UserPhrase> entries) {
    std::sort(entries.begin(), entries.end(),
              [](const UserPhrase &a, const UserPhrase &b) {
                  if (a.phrase != b.phrase) {
                      return a.phrase < b.phrase;
                  }
                  return a.reading < b.reading;
              });

    out << kHeader << '\n'
        << "# One entry per line: phrase<TAB>canonical Bopomofo reading\n";
    for (const auto &entry : entries) {
        if (entry.phrase.empty() || entry.reading.empty() ||
            hasTabOrNewline(entry.phrase) || hasTabOrNewline(entry.reading)) {
            return false;
        }
        out << entry.phrase << '\t' << entry.reading << '\n';
    }
    return static_cast<bool>(out);
}

std::vector<std::filesystem::path> dictionaryFiles() {
    const auto dir = ari_ime::userDataDir();
    return {dir / "userdict.dat", dir / "chewing.dat",
            dir / "chewing-deleted.dat", dir / "preferences.tsv"};
}

std::filesystem::path makeBackup(std::error_code &ec) {
    ec.clear();
    const auto dir = ari_ime::userDataDir();
    if (dir.empty()) {
        ec = std::make_error_code(std::errc::no_such_file_or_directory);
        return {};
    }

    std::vector<std::filesystem::path> existing;
    for (const auto &file : dictionaryFiles()) {
        std::error_code inspectEc;
        if (std::filesystem::is_regular_file(file, inspectEc) && !inspectEc) {
            existing.push_back(file);
        }
    }
    if (existing.empty()) {
        return {};
    }

    const auto stamp = std::chrono::duration_cast<std::chrono::milliseconds>(
                           std::chrono::system_clock::now().time_since_epoch())
                           .count();
    std::filesystem::path backup;
    for (int attempt = 0; attempt < 100; ++attempt) {
        backup = dir / (".backup." + std::to_string(stamp) + "." +
                        std::to_string(attempt));
        if (std::filesystem::create_directory(backup, ec)) {
            break;
        }
        if (ec != std::errc::file_exists) {
            return {};
        }
        ec.clear();
        backup.clear();
    }
    if (backup.empty()) {
        ec = std::make_error_code(std::errc::file_exists);
        return {};
    }

    for (const auto &file : existing) {
        std::filesystem::copy_file(file, backup / file.filename(),
                                   std::filesystem::copy_options::none, ec);
        if (ec) {
            std::error_code cleanupEc;
            std::filesystem::remove_all(backup, cleanupEc);
            return {};
        }
    }
    return backup;
}

bool ensureDataDirectory() {
    std::error_code ec;
    if (ari_ime::ensureUserDataDir(ec)) {
        return true;
    }
    std::cerr << "ari-ime-dict: cannot prepare user data directory: "
              << ec.message() << '\n';
    return false;
}

bool openEngine(Zhuyin &engine) {
    if (engine.ok()) {
        return true;
    }
    std::cerr << "ari-ime-dict: libchewing could not be initialized\n";
    return false;
}

int commandInfo() {
    if (!ensureDataDirectory()) {
        return 1;
    }
    Zhuyin engine;
    if (!openEngine(engine)) {
        return 1;
    }
    const auto entries = engine.userPhrases();
    std::cout << "format\tAri IME user dictionary v1\n"
              << "data_dir\t" << ari_ime::userDataDir().string() << '\n'
              << "libchewing\t" << ARI_IME_CHEWING_VERSION << '\n'
              << "entries\t" << entries.size() << '\n';
    return 0;
}

int commandList() {
    if (!ensureDataDirectory()) {
        return 1;
    }
    Zhuyin engine;
    if (!openEngine(engine)) {
        return 1;
    }
    return writeEntries(std::cout, engine.userPhrases()) ? 0 : 1;
}

int commandExport(const std::string &filename) {
    if (!ensureDataDirectory()) {
        return 1;
    }
    Zhuyin engine;
    if (!openEngine(engine)) {
        return 1;
    }

    if (filename == "-" || filename.empty()) {
        return writeEntries(std::cout, engine.userPhrases()) ? 0 : 1;
    }
    // Write to a sibling temporary file and move it into place so a failed or
    // malformed export cannot truncate a previously good destination.
    const std::filesystem::path destination(filename);
    std::filesystem::path temporary = destination;
    temporary += ".tmp";
    {
        std::ofstream out(temporary, std::ios::binary | std::ios::trunc);
        if (!out) {
            std::cerr << "ari-ime-dict: cannot open export file: " << filename
                      << '\n';
            return 1;
        }
        if (!writeEntries(out, engine.userPhrases())) {
            std::cerr << "ari-ime-dict: cannot write export file: " << filename
                      << '\n';
            std::error_code cleanupEc;
            std::filesystem::remove(temporary, cleanupEc);
            return 1;
        }
    }
    std::error_code renameEc;
    std::filesystem::rename(temporary, destination, renameEc);
    if (renameEc) {
        // Cross-device destinations cannot be renamed; copy then clean up.
        std::error_code copyEc;
        std::filesystem::copy_file(temporary, destination,
                                   std::filesystem::copy_options::overwrite_existing,
                                   copyEc);
        std::error_code cleanupEc;
        std::filesystem::remove(temporary, cleanupEc);
        if (copyEc) {
            std::cerr << "ari-ime-dict: cannot write export file: " << filename
                      << ": " << copyEc.message() << '\n';
            return 1;
        }
    }
    return 0;
}

// Going (自然輸入法) exports its personal dictionary as a CSV whose first line
// is an HTML-comment marker. The readings are already canonical Bopomofo, so
// the conversion is purely about separators: comma to tab, hyphen to space.
bool looksLikeGoingCsv(const std::string &firstLine) {
    return firstLine.rfind("<!--Going", 0) == 0;
}

// Rewrites a Going CSV into the tab-separated form readEntries() expects.
// Entries longer than libchewing's phrase limit are handed back separately:
// chewing_userphrase_add() rejects them without an error, so importing them as
// dictionary entries would silently drop the user's data.
std::string convertGoingCsv(std::istream &in,
                            std::vector<std::string> &tooLong) {
    std::string out = std::string(kHeader) + "\n";
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        if (line.empty() || line.rfind("<!--", 0) == 0) {
            continue;
        }
        // Split on the first comma only: a Chinese phrase never contains one,
        // and the reading field might.
        const std::size_t comma = line.find(',');
        if (comma == std::string::npos || comma == 0 ||
            comma + 1 >= line.size()) {
            continue;
        }
        const std::string phrase = line.substr(0, comma);
        std::string reading = line.substr(comma + 1);
        std::replace(reading.begin(), reading.end(), '-', ' ');

        if (ari_ime::unicode::graphemeCount(phrase) > kMaxChewingPhrase) {
            tooLong.push_back(phrase);
            continue;
        }
        out += phrase;
        out += '\t';
        out += reading;
        out += '\n';
    }
    return out;
}

int commandImport(const std::string &filename, bool dryRun) {
    std::ifstream in;
    if (filename != "-") {
        in.open(filename, std::ios::binary);
        if (!in) {
            std::cerr << "ari-ime-dict: cannot open import file: " << filename
                      << '\n';
            return 1;
        }
    }
    std::istream &source = filename == "-" ? std::cin : in;

    // Peek at the first line to decide whether this needs converting first.
    const std::streampos start = source.tellg();
    std::string firstLine;
    std::getline(source, firstLine);
    if (!firstLine.empty() && firstLine.back() == '\r') {
        firstLine.pop_back();
    }

    std::vector<std::string> tooLong;
    std::string converted;
    std::istringstream convertedStream;
    if (looksLikeGoingCsv(firstLine)) {
        converted = convertGoingCsv(source, tooLong);
        convertedStream.str(converted);
    } else if (start != std::streampos(-1)) {
        source.clear();
        source.seekg(start);
    } else {
        // A pipe cannot be rewound, so the line already read is put back in
        // front of the rest.
        converted = firstLine + "\n";
        std::string rest((std::istreambuf_iterator<char>(source)),
                         std::istreambuf_iterator<char>());
        converted += rest;
        convertedStream.str(converted);
    }

    std::istream &parseSource =
        converted.empty() ? source : static_cast<std::istream &>(convertedStream);

    std::vector<Entry> entries;
    std::string parseError;
    if (!readEntries(parseSource, entries, parseError)) {
        std::cerr << "ari-ime-dict: invalid import: " << parseError << '\n';
        return 2;
    }
    if (!tooLong.empty()) {
        std::vector<ari_ime::LongPhrase> phrases = ari_ime::loadLongPhrases();
        std::size_t added = 0;
        for (const std::string &phrase : tooLong) {
            const auto existing =
                std::find_if(phrases.begin(), phrases.end(),
                             [&](const ari_ime::LongPhrase &entry) {
                                 return entry.text == phrase;
                             });
            if (existing != phrases.end()) {
                continue;
            }
            // Imported deliberately, so it starts out already eligible rather
            // than waiting to be typed three more times.
            phrases.push_back({ari_ime::kLongPhraseMinCount, phrase});
            ++added;
        }
        if (!dryRun && added > 0) {
            ari_ime::saveLongPhrases(phrases);
        }
        std::cout << (dryRun ? "would move " : "moved ") << added
                  << " phrase(s) too long for the dictionary into "
                  << ari_ime::longPhrasesPath().string() << '\n';
    }

    if (dryRun) {
        std::cout << "validated " << entries.size() << " entr"
                  << (entries.size() == 1 ? "y" : "ies") << "\n";
        return 0;
    }
    if (!ensureDataDirectory()) {
        return 1;
    }
    Zhuyin engine;
    if (!openEngine(engine)) {
        return 1;
    }
    std::unordered_set<std::string> existing;
    for (const auto &entry : engine.userPhrases()) {
        existing.insert(entryKey(entry.phrase, entry.reading));
    }

    std::error_code backupEc;
    const auto backup = makeBackup(backupEc);
    if (backupEc) {
        std::cerr << "ari-ime-dict: cannot create backup before import: "
                  << backupEc.message() << '\n';
        return 1;
    }

    int added = 0;
    int skipped = 0;
    for (const auto &entry : entries) {
        if (!existing.insert(entryKey(entry.phrase, entry.reading)).second) {
            ++skipped;
            continue;
        }
        const int result = engine.addUserPhrase(entry.phrase, entry.reading);
        if (result < 0) {
            std::cerr << "ari-ime-dict: libchewing rejected an entry for "
                      << entry.phrase << " on line " << entry.line << '\n';
            if (!backup.empty()) {
                std::cerr << "A backup was kept at " << backup.string() << '\n';
            }
            return 1;
        }
        if (result == 0) {
            ++skipped;
        } else {
            added += result;
        }
    }
    std::cout << "added " << added << ", skipped " << skipped;
    if (!backup.empty()) {
        std::cout << ", backup " << backup.string();
    }
    std::cout << '\n';
    return 0;
}

int commandBackup() {
    if (!ensureDataDirectory()) {
        return 1;
    }
    std::error_code ec;
    const auto backup = makeBackup(ec);
    if (ec) {
        std::cerr << "ari-ime-dict: cannot create backup: " << ec.message()
                  << '\n';
        return 1;
    }
    if (backup.empty()) {
        std::cout << "no learned dictionary files or preference files to back up\n";
    } else {
        std::cout << backup.string() << '\n';
    }
    return 0;
}

int commandCandidates(const std::string &keys) {
    if (!ensureDataDirectory()) {
        return 1;
    }
    Zhuyin engine;
    if (!openEngine(engine)) {
        return 1;
    }
    engine.feedSequence(keys);
    // On libchewing < 0.10, explicit user phrases are not ranked ahead of
    // built-in candidates by the library itself.
    engine.promoteUserPhrases();
    std::cout << "keys\t" << keys << '\n'
              << "preedit\t" << engine.preedit() << '\n';
    if (!engine.openCandidates()) {
        std::cerr << "ari-ime-dict: no candidates for the supplied keys\n";
        return 1;
    }
    std::cout << "total\t" << engine.candidateCount() << '\n'
              << "page\t" << engine.candCurrentPage() + 1 << "/"
              << engine.candTotalPage() << '\n';
    for (const auto &candidate : engine.pageCandidates()) {
        std::cout << "candidate\t" << candidate << '\n';
    }
    return 0;
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 2 || std::string_view(argv[1]) == "--help" ||
        std::string_view(argv[1]) == "-h") {
        usage(std::cout);
        return argc < 2 ? 2 : 0;
    }

    const std::string command = argv[1];
    if (command == "info" && argc == 2) {
        return commandInfo();
    }
    if (command == "list" && argc == 2) {
        return commandList();
    }
    if (command == "export" && (argc == 2 || argc == 3)) {
        return commandExport(argc == 3 ? argv[2] : "-");
    }
    if (command == "import" && (argc == 3 || argc == 4)) {
        bool dryRun = false;
        std::string filename;
        if (argc == 3) {
            filename = argv[2];
        } else if (std::string_view(argv[2]) == "--dry-run") {
            dryRun = true;
            filename = argv[3];
        } else {
            usage(std::cerr);
            return 2;
        }
        return commandImport(filename, dryRun);
    }
    if (command == "backup" && argc == 2) {
        return commandBackup();
    }
    if (command == "candidates" && argc == 3) {
        return commandCandidates(argv[2]);
    }

    usage(std::cerr);
    return 2;
}
