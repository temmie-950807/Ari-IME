// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Kaiyasi

#include "ari-ime-wasm.h"

#include <algorithm>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "buffer.h"
#include "layout.h"

struct AriWasmEngine {
    Buffer buffer;
    KeyResult lastResult;
    std::string json;

    AriWasmEngine() { publish({}); }

    void publish(const KeyResult &result) {
        lastResult = result;
        json.clear();
        json.reserve(256);
        json.push_back('{');
        appendBool("handled", result.handled);
        appendBool("hasCommit", result.hasCommit);
        appendString("commitText", result.commitText);
        appendBool("updateUI", result.updateUI);
        appendBool("notifyMode", result.notifyMode);
        appendString("notification", result.notification);
        appendBool("engineReady", buffer.engineReady());
        appendString("preedit", buffer.preeditText());
        appendCandidates();
        json.push_back('}');
    }

    void appendBool(std::string_view name, bool value) {
        appendName(name);
        json += value ? "true" : "false";
    }

    void appendString(std::string_view name, std::string_view value) {
        appendName(name);
        appendJsonString(value);
    }

    void appendName(std::string_view name) {
        if (json.size() > 1) {
            json.push_back(',');
        }
        appendJsonString(name);
        json.push_back(':');
    }

    void appendJsonString(std::string_view value) {
        static constexpr char hex[] = "0123456789abcdef";
        json.push_back('"');
        for (const unsigned char c : value) {
            switch (c) {
            case '"': json += "\\\""; break;
            case '\\': json += "\\\\"; break;
            case '\b': json += "\\b"; break;
            case '\f': json += "\\f"; break;
            case '\n': json += "\\n"; break;
            case '\r': json += "\\r"; break;
            case '\t': json += "\\t"; break;
            default:
                if (c < 0x20) {
                    json += "\\u00";
                    json.push_back(hex[c >> 4]);
                    json.push_back(hex[c & 0x0f]);
                } else {
                    json.push_back(static_cast<char>(c));
                }
                break;
            }
        }
        json.push_back('"');
    }

    void appendCandidates() {
        appendName("candidates");
        json.push_back('[');
        const auto candidates = buffer.candidates();
        for (std::size_t i = 0; i < candidates.size(); ++i) {
            if (i != 0) {
                json.push_back(',');
            }
            appendJsonString(candidates[i]);
        }
        json.push_back(']');
        appendNumber("candidatePage", buffer.candidatePage());
        appendNumber("candidatePageCount", buffer.candidatePageCount());
        appendNumber("highlight", buffer.highlight());
        appendNumber("selectionChar", buffer.selectionChar());
        appendNumber("caretChar", buffer.caretChar());
        appendBool("editing", buffer.isEditing());
        appendBool("picking", buffer.isPicking());
    }

    void appendNumber(std::string_view name, int value) {
        appendName(name);
        json += std::to_string(value);
    }
};

namespace {

ari_ime::KeyboardLayout layoutFromInt(int value) {
    constexpr int first = static_cast<int>(ari_ime::KeyboardLayout::Default);
    constexpr int last = static_cast<int>(ari_ime::KeyboardLayout::Colemak);
    value = std::clamp(value, first, last);
    return static_cast<ari_ime::KeyboardLayout>(value);
}

ari_ime::ChinesePunctuationShortcut punctuationShortcutFromInt(int value) {
    constexpr int first = static_cast<int>(
        ari_ime::ChinesePunctuationShortcut::ControlShift);
    constexpr int last = static_cast<int>(
        ari_ime::ChinesePunctuationShortcut::Disabled);
    value = std::clamp(value, first, last);
    return static_cast<ari_ime::ChinesePunctuationShortcut>(value);
}

const char *invalidEngine() {
    static constexpr char result[] =
        R"({"handled":false,"hasCommit":false,"commitText":"","updateUI":false,"notifyMode":false,"notification":"","engineReady":false,"preedit":"","candidates":[]})";
    return result;
}

// Emscripten builds disable exception unwinding by default, so a throw
// already traps fail-stop. The guards below keep the C ABI safe as well if
// -fexceptions is ever enabled for JS interop debugging: no exception may
// unwind into JS frames.
template <typename Fn>
const char *guardedJson(Fn &&fn) {
    try {
        return fn();
    } catch (...) {
        return invalidEngine();
    }
}

} // namespace

extern "C" {

AriWasmEngine *ari_engine_create() { return new AriWasmEngine(); }

void ari_engine_destroy(AriWasmEngine *engine) { delete engine; }

const char *ari_engine_state_json(AriWasmEngine *engine) {
    return guardedJson([&] {
        return engine ? engine->json.c_str() : invalidEngine();
    });
}

const char *ari_engine_handle_key_json(AriWasmEngine *engine,
                                       std::uint32_t keySym,
                                       std::uint32_t modifiers) {
    return guardedJson([&] {
        if (!engine) {
            return invalidEngine();
        }
        const KeyResult result = engine->buffer.handleKey(
            fcitx::Key(keySym, fcitx::KeyStates(modifiers)));
        engine->publish(result);
        return engine->json.c_str();
    });
}

const char *ari_engine_select_candidate_json(AriWasmEngine *engine,
                                             int pageIndex) {
    return guardedJson([&] {
        if (!engine) {
            return invalidEngine();
        }
        engine->publish(engine->buffer.selectCandidate(pageIndex));
        return engine->json.c_str();
    });
}

const char *ari_engine_paste_utf8_json(AriWasmEngine *engine,
                                       const char *text) {
    return guardedJson([&] {
        if (!engine) {
            return invalidEngine();
        }
        engine->buffer.pasteAtCaret(text ? text : "");
        engine->publish({true, false, {}, true});
        return engine->json.c_str();
    });
}

const char *ari_engine_reconvert_utf8_json(AriWasmEngine *engine,
                                           const char *text) {
    return guardedJson([&] {
        if (!engine) {
            return invalidEngine();
        }
        engine->publish(engine->buffer.beginReconversion(text ? text : ""));
        return engine->json.c_str();
    });
}

const char *ari_engine_reset_json(AriWasmEngine *engine) {
    return guardedJson([&] {
        if (!engine) {
            return invalidEngine();
        }
        engine->buffer.reset();
        engine->publish({true, false, {}, true});
        return engine->json.c_str();
    });
}

void ari_engine_set_learning_allowed(AriWasmEngine *engine, int allowed) {
    try {
        if (engine) {
            engine->buffer.setLearningAllowed(allowed != 0);
        }
    } catch (...) {
    }
}

int ari_engine_set_keyboard_layout(AriWasmEngine *engine, int layout) {
    try {
        if (!engine) {
            return 0;
        }
        return engine->buffer.setKeyboardLayout(layoutFromInt(layout)) ? 1 : 0;
    } catch (...) {
        return 0;
    }
}

void ari_engine_set_full_width_punctuation(AriWasmEngine *engine,
                                           int enabled) {
    try {
        if (engine) {
            engine->buffer.setFullWidthPunct(enabled != 0);
        }
    } catch (...) {
    }
}

void ari_engine_set_punctuation_shortcut(AriWasmEngine *engine, int shortcut) {
    try {
        if (engine) {
            engine->buffer.setChinesePunctuationShortcut(
                punctuationShortcutFromInt(shortcut));
        }
    } catch (...) {
    }
}

void ari_engine_set_space_candidate_mode(AriWasmEngine *engine, int enabled) {
    try {
        if (engine) {
            engine->buffer.setSpaceCandidateMode(enabled != 0);
        }
    } catch (...) {
    }
}

} // extern "C"
