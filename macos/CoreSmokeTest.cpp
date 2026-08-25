// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi
//
// Confirms the shared core builds and runs natively on macOS against the
// bundled libchewing, independent of any InputMethodKit plumbing. When the
// input method misbehaves, this separates "the core is broken" from "the
// front end is wired up wrong".
//
// Usage: core_smoke_test <chewing-data-dir> <scratch-user-data-dir>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <system_error>
#include <vector>

#include <fcitx-utils/keysym.h>

#include "buffer.h"
#include "layout.h"
#include "user_data.h"

namespace {

void type(Buffer &buffer, const std::string &keys) {
    for (const unsigned char c : keys) {
        buffer.handleKey(fcitx::Key(static_cast<fcitx::KeySym>(c)));
    }
}

std::string preeditAfter(const std::string &keys) {
    Buffer buffer;
    type(buffer, keys);
    return buffer.preeditText();
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 3) {
        std::fprintf(stderr,
                     "usage: %s <chewing-data-dir> <user-data-dir>\n", argv[0]);
        return 2;
    }
    setenv("CHEWING_PATH", argv[1], 1);
    setenv("ARI_IME_USER_DATA_DIR", argv[2], 1);
    setenv("ARI_IME_DISABLE_AUTOLEARN", "1", 1);

    {
        Buffer buffer;
        assert(buffer.engineReady() && "libchewing context failed to load");
    }

    // A toned syllable converts; the untoned prefix stays literal until then.
    assert(preeditAfter("su") == "su");
    assert(preeditAfter("su3") == "你");
    assert(preeditAfter("su3cl3") == "你好");

    // English and Chinese coexist in one pre-edit without a mode switch.
    const std::string mixed = preeditAfter("linuxy04");
    assert(mixed.rfind("linux", 0) == 0 && mixed.size() > 5);

    // Nothing reaches the application until Return.
    {
        Buffer buffer;
        type(buffer, "su3");
        const KeyResult result = buffer.handleKey(fcitx::Key(FcitxKey_Return));
        assert(result.hasCommit);
        assert(result.commitText == "你");
        assert(buffer.preeditText().empty());
    }

    // Down opens candidate selection over the pre-edit.
    {
        Buffer buffer;
        type(buffer, "su3");
        buffer.handleKey(fcitx::Key(FcitxKey_Down));
        assert(buffer.isPicking());
        assert(buffer.candidatePage() == 1);
        assert(buffer.candidatePageCount() >= 1);
        assert(!buffer.candidates().empty());
        assert(buffer.candidates().size() <= 9);
        assert(buffer.highlight() == 0);
    }

    // A non-default keyboard layout has to survive the resets that happen
    // between syllables. libchewing 0.8's chewing_Reset() wipes its keyboard
    // type, so without re-asserting it the user silently lands back on the
    // 大千 key map partway through typing.
    {
        assert(ari_ime::keyboardLayoutAvailable(ari_ime::KeyboardLayout::Hsu) &&
               "Hsu layout should be selectable");
        Buffer buffer;
        buffer.setKeyboardLayout(ari_ime::KeyboardLayout::Hsu);

        type(buffer, "nef"); // 許氏: nef -> 你
        assert(buffer.preeditText() == "你");

        // Escape runs the engine's full reset; the layout must still apply.
        buffer.handleKey(fcitx::Key(FcitxKey_Escape));
        assert(buffer.preeditText().empty());
        type(buffer, "nef");
        assert(buffer.preeditText() == "你" && "layout lost after reset");

        buffer.setKeyboardLayout(ari_ime::KeyboardLayout::Default);
    }

    // Full-width punctuation has to reach the keys the layout spends on 注音 —
    // the comma is ㄝ on 大千 — without stopping those keys from typing 注音
    // when a syllable is actually under way.
    {
        Buffer plain;
        type(plain, ",");
        assert(plain.preeditText() == "," && "comma stays literal by default");

        Buffer full;
        full.setFullWidthPunct(true);
        type(full, ",");
        assert(full.preeditText() == "，" && "comma must become full-width");

        Buffer period;
        period.setFullWidthPunct(true);
        type(period, ".");
        assert(period.preeditText() == "。");

        // ㄒㄧㄝ ends on the comma key; mid-syllable it is still 注音.
        Buffer syllable;
        syllable.setFullWidthPunct(true);
        type(syllable, "vu,4");
        assert(syllable.preeditText() == "謝" && "comma still types ㄝ");

        // A 注音 key only converts when the shortcut table names it. Asking
        // libchewing about any other one parks a Bopomofo symbol, and
        // force-committing that emits a stray ㄅㄆㄇ instead of punctuation.
        Buffer bopomofo;
        bopomofo.setFullWidthPunct(true);
        type(bopomofo, "a");
        assert(bopomofo.preeditText() == "a" &&
               "an unnamed 注音 key must not go through the probe");
    }

    // The two punctuation mechanisms are independent, and the useful pairing is
    // the shortcut alone: keys stay literal until Shift is held. With
    // full-width mode also on, a bare / becomes ？ and the slash is untypable.
    {
        Buffer b;
        b.setChinesePunctuationShortcut(
            ari_ime::ChinesePunctuationShortcut::Shift);

        type(b, "/");
        assert(b.preeditText() == "/" && "a bare slash must stay a slash");
        b.reset();

        // Shift+/ arrives as '?' with the Shift bit; the core maps it back
        // through the physical key, so it yields ？ rather than ＜-style
        // conversion of the shifted symbol.
        b.handleKey(fcitx::Key(static_cast<fcitx::KeySym>('?'),
                               fcitx::KeyStates{fcitx::KeyState::Shift}));
        assert(b.preeditText() == "？");
        b.reset();

        b.handleKey(fcitx::Key(static_cast<fcitx::KeySym>('<'),
                               fcitx::KeyStates{fcitx::KeyState::Shift}));
        assert(b.preeditText() == "，" && "Shift+comma is ，not ＜");
    }

    // The corner quote is the ordinary Chinese quotation mark, so both halves
    // of the bracket key produce it — Shift is already spent reaching `[`.
    // Typing an opening bracket also parks its closing half after the caret.
    {
        const fcitx::KeyStates shortcut{fcitx::KeyState::Ctrl,
                                        fcitx::KeyState::Shift};
        Buffer buffer;
        // Shift turns `[` into `{` before the core ever sees it.
        buffer.handleKey(fcitx::Key(static_cast<fcitx::KeySym>('{'), shortcut));
        assert(buffer.preeditText() == "「」" && "must pair, and be 「 not 『");
        assert(buffer.caretChar() == 1 && "caret belongs between the halves");

        type(buffer, "su3");
        assert(buffer.preeditText() == "「你」");
        assert(buffer.caretChar() == 2);

        // Typing the closing half steps over the parked one.
        buffer.handleKey(fcitx::Key(static_cast<fcitx::KeySym>('}'), shortcut));
        assert(buffer.preeditText() == "「你」" && "must not double up");
        assert(buffer.caretChar() == -1 && "caret ends up past the pair");

        const KeyResult committed =
            buffer.handleKey(fcitx::Key(FcitxKey_Return));
        assert(committed.commitText == "「你」");
    }

    // Full-width mode reaches the same pairing, and Alt+[ still works.
    {
        Buffer full;
        full.setFullWidthPunct(true);
        type(full, "[");
        assert(full.preeditText() == "「」" && full.caretChar() == 1);

        Buffer alt;
        alt.handleKey(fcitx::Key(static_cast<fcitx::KeySym>('['),
                                 fcitx::KeyStates{fcitx::KeyState::Alt}));
        assert(alt.preeditText() == "「」" && alt.caretChar() == 1);
    }

    // An explicit candidate pick has to outlive the session. That only works if
    // the choice reaches libchewing's own user dictionary: the sidecar alone is
    // intersected against it before anything is promoted, so a sidecar-only
    // entry can never take effect.
    {
        const std::string learningDir = std::string(argv[2]) + "-learning";
        setenv("ARI_IME_USER_DATA_DIR", learningDir.c_str(), 1);
        unsetenv("ARI_IME_DISABLE_AUTOLEARN"); // this is the thing under test
        std::error_code ec;
        ari_ime::resetUserDictionary(ec);

        std::string picked;
        {
            Buffer buffer;
            type(buffer, "su3");
            buffer.handleKey(fcitx::Key(FcitxKey_Down));
            const std::vector<std::string> candidates = buffer.candidates();
            assert(candidates.size() >= 2);
            picked = candidates[1];
            assert(picked != buffer.preeditText() && "need a different choice");

            buffer.handleKey(fcitx::Key(static_cast<fcitx::KeySym>('2')));
            assert(buffer.preeditText() == picked);
            buffer.handleKey(fcitx::Key(FcitxKey_Return));
        } // the context flushes its dictionary as it is destroyed

        Buffer relaunched;
        type(relaunched, "su3");
        assert(relaunched.preeditText() == picked &&
               "an explicit pick must come back first next time");

        setenv("ARI_IME_DISABLE_AUTOLEARN", "1", 1);
        setenv("ARI_IME_USER_DATA_DIR", argv[2], 1);
    }

    // In the candidate window the bare arrows turn pages, which is what the
    // list is mostly used for. Stepping between characters is the rarer action
    // and lives on Control+arrow.
    {
        Buffer buffer;
        type(buffer, "su3cl3");
        buffer.handleKey(fcitx::Key(FcitxKey_Home));
        buffer.handleKey(fcitx::Key(FcitxKey_Down));
        assert(buffer.isPicking() && buffer.candidatePageCount() > 1);
        assert(buffer.candidatePage() == 1 && buffer.selectionChar() == 0);

        buffer.handleKey(fcitx::Key(FcitxKey_Right));
        assert(buffer.candidatePage() == 2 && "→ turns the page");
        assert(buffer.selectionChar() == 0 && "and stays on the same character");

        buffer.handleKey(fcitx::Key(FcitxKey_Left));
        assert(buffer.candidatePage() == 1 && "← turns back");

        const fcitx::KeyStates ctrl{fcitx::KeyState::Ctrl};
        buffer.handleKey(fcitx::Key(FcitxKey_Right, ctrl));
        assert(buffer.isPicking() && buffer.selectionChar() == 1 &&
               "Control+→ steps to the next character");
        buffer.handleKey(fcitx::Key(FcitxKey_Left, ctrl));
        assert(buffer.selectionChar() == 0);
    }

    // --- Text templates ---------------------------------------------------
    //
    // Content lives on one line with a two-character escape for newlines, so
    // the file stays greppable and a hand edit cannot desynchronise a
    // multi-line record.
    {
        const std::filesystem::path path = ari_ime::templatesPath();
        assert(!path.empty());
        {
            std::ofstream out(path, std::ios::binary | std::ios::trunc);
            out << "# Ari IME templates v1\n";
            out << "\n";                       // blank lines are skipped
            out << "信箱\ttem\ta@b.com\n";
            out << "地址\tadd\t一樓\\n二樓\n"; // escaped newline
            out << "壞的\tno-tab-here\n";      // too few fields, dropped
            out << "數字\tt3m\tnope\n";        // digit in code, dropped
        }
        ari_ime::templateStore().reload();

        const auto all = ari_ime::loadTemplates();
        assert(all.size() == 2 && "malformed lines must be dropped, not fatal");
        assert(all[1].content == "一樓\n二樓" && "\\n must become a real newline");

        assert(ari_ime::templateStore().matching("tem").size() == 1);
        assert(ari_ime::templateStore().matching("t").size() == 1);
        assert(ari_ime::templateStore().matching("").size() == 2);
        assert(ari_ime::templateStore().matching("zz").empty());

        assert(ari_ime::validTemplateCode("tem"));
        assert(ari_ime::validTemplateCode("my_sig.v2-b") == false); // digit
        assert(!ari_ime::validTemplateCode("t3m") && "digits select candidates");
        assert(!ari_ime::validTemplateCode(""));
    }

    // --- Long phrases ------------------------------------------------------
    {
        ari_ime::longPhraseStore().reload();
        const std::string sentence = "不好意思打擾了再麻煩協助確認";  // 14 chars

        ari_ime::longPhraseStore().bump("太短");        // below the floor
        assert(ari_ime::longPhraseStore().suggest("太短", 5).empty());

        // A phrase is only offered once it has been seen enough times.
        ari_ime::longPhraseStore().bump(sentence);
        ari_ime::longPhraseStore().bump(sentence);
        assert(ari_ime::longPhraseStore().suggest("不好", 5).empty() &&
               "must not suggest below the count threshold");
        ari_ime::longPhraseStore().bump(sentence);

        const auto hits = ari_ime::longPhraseStore().suggest("不好", 5);
        assert(hits.size() == 1);
        assert(hits[0] == "意思打擾了再麻煩協助確認" &&
               "suggestion is the remainder, not the whole phrase");
        // An exact match has nothing left to add.
        assert(ari_ime::longPhraseStore().suggest(sentence, 5).empty());

        // The counts have to survive a process restart.
        ari_ime::longPhraseStore().reload();
        assert(ari_ime::longPhraseStore().suggest("不好", 5).size() == 1);
    }

    // --- Template mode ----------------------------------------------------
    {
        {
            std::ofstream out(ari_ime::templatesPath(),
                              std::ios::binary | std::ios::trunc);
            out << "# Ari IME templates v1\n";
            out << "信箱\ttem\ta@b.com\n";
            out << "信箱\ttem\tc@d.edu.tw\n";
            out << "地址\tadd\t一樓\\n二樓\n";
        }
        ari_ime::templateStore().reload();

        Buffer buffer;
        buffer.handleKey(fcitx::Key(static_cast<fcitx::KeySym>('`')));
        assert(buffer.isTemplateMode());
        assert(buffer.candidates().size() == 3 && "a bare prefix lists them all");

        type(buffer, "tem");
        assert(buffer.candidates().size() == 2 && "the code narrows the list");

        // Rows are labelled with their content, not the code: two entries
        // sharing a code would otherwise render as identical strings, and the
        // candidate panel collapses duplicates into one row.
        const auto rows = buffer.candidates();
        assert(rows[0] != rows[1] && "candidate labels must be distinguishable");
        assert(rows[0] == "a@b.com" && rows[1] == "c@d.edu.tw");

        const KeyResult picked = buffer.handleKey(fcitx::Key(FcitxKey_1));
        // Committed rather than composed: a template is finished text.
        assert(picked.hasCommit && picked.commitText == "a@b.com");
        assert(!buffer.isTemplateMode() && buffer.preeditText().empty());
    }

    // Newlines survive, which is why the content is committed rather than sent
    // through the paste path (that folds separators into spaces).
    {
        Buffer buffer;
        buffer.handleKey(fcitx::Key(static_cast<fcitx::KeySym>('`')));
        type(buffer, "add");
        const KeyResult picked = buffer.handleKey(fcitx::Key(FcitxKey_1));
        assert(picked.commitText == "一樓\n二樓");
    }

    // The mode is only reachable from an empty pre-edit, so a backtick inside a
    // sentence stays an ordinary character.
    {
        Buffer buffer;
        type(buffer, "su3");
        buffer.handleKey(fcitx::Key(static_cast<fcitx::KeySym>('`')));
        assert(!buffer.isTemplateMode());
        assert(buffer.preeditText() == "你`");
    }

    // Pressing the prefix key again leaves and types it, so the character stays
    // reachable without switching to English.
    {
        Buffer buffer;
        buffer.handleKey(fcitx::Key(static_cast<fcitx::KeySym>('`')));
        buffer.handleKey(fcitx::Key(static_cast<fcitx::KeySym>('`')));
        assert(!buffer.isTemplateMode() && buffer.preeditText() == "`");
    }

    // Escape must not fall through to the shared handler, which resets the
    // whole pre-edit — that would throw away a sentence in progress.
    {
        Buffer buffer;
        buffer.handleKey(fcitx::Key(static_cast<fcitx::KeySym>('`')));
        type(buffer, "tem");
        buffer.handleKey(fcitx::Key(FcitxKey_Escape));
        assert(!buffer.isTemplateMode() && buffer.preeditText().empty());
    }

    // Backspacing past the start of the code leaves the mode.
    {
        Buffer buffer;
        buffer.handleKey(fcitx::Key(static_cast<fcitx::KeySym>('`')));
        type(buffer, "t");
        buffer.handleKey(fcitx::Key(FcitxKey_BackSpace));
        assert(buffer.isTemplateMode() && "still in the mode with an empty code");
        buffer.handleKey(fcitx::Key(FcitxKey_BackSpace));
        assert(!buffer.isTemplateMode());
    }

    // An unknown code offers nothing, and Return then just leaves.
    {
        Buffer buffer;
        buffer.handleKey(fcitx::Key(static_cast<fcitx::KeySym>('`')));
        type(buffer, "zzz");
        assert(buffer.candidates().empty());
        const KeyResult none = buffer.handleKey(fcitx::Key(FcitxKey_Return));
        assert(!none.hasCommit && !buffer.isTemplateMode());
    }

    // Both files hold personal text, so a reset has to take them with it.
    {
        std::error_code ec;
        assert(ari_ime::resetUserDictionary(ec));
        assert(!std::filesystem::exists(ari_ime::templatesPath()));
        assert(!std::filesystem::exists(ari_ime::longPhrasesPath()));
    }

    // The four tone marks libchewing emits, and the separator a multi-character
    // reading needs. Getting this wrong rejects every imported phrase: the
    // fourth tone and the neutral tone alone cover most of a real dictionary.
    {
        // 查看 (fourth), 應該 (first, unmarked), 式子 (neutral)
        assert(ari_ime::isCanonicalReadingForTesting("ㄔㄚˊ ㄎㄢˋ"));
        assert(ari_ime::isCanonicalReadingForTesting("ㄧㄥ ㄍㄞ"));
        assert(ari_ime::isCanonicalReadingForTesting("ㄕˋ ㄗ˙"));
        assert(ari_ime::isCanonicalReadingForTesting("ㄋㄧˇ"));

        assert(!ari_ime::isCanonicalReadingForTesting(""));
        assert(!ari_ime::isCanonicalReadingForTesting(" ㄋㄧˇ"));
        assert(!ari_ime::isCanonicalReadingForTesting("ㄋㄧˇ "));
        assert(!ari_ime::isCanonicalReadingForTesting("ㄋㄧˇ  ㄏㄠˇ"));
        // A middle dot is not the neutral tone mark, however similar it looks.
        assert(!ari_ime::isCanonicalReadingForTesting("ㄕˋ ㄗ·"));
        assert(!ari_ime::isCanonicalReadingForTesting("nihao"));
    }

    std::puts("core smoke test passed");
    return 0;
}
