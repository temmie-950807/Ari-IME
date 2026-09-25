cmake_minimum_required(VERSION 3.16)
project(ari_ime_macos VERSION 2.5.4 LANGUAGES CXX OBJCXX)

if(NOT APPLE)
    message(FATAL_ERROR "This directory builds the macOS InputMethodKit front end")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

set(ARI_SOURCE_ROOT "${CMAKE_CURRENT_LIST_DIR}/..")
set(ARI_BUNDLE_ID "org.kaiyasi.inputmethod.AriIME" CACHE STRING
    "Bundle identifier. Must contain \"inputmethod\" for the system to list it")
set(ARI_EXECUTABLE_NAME "AriIME")
set(ARI_VERSION "${PROJECT_VERSION}")
# build-libchewing-macos.sh pins this; reported by `ari-ime-dict info`.
set(ARI_CHEWING_VERSION "0.8.5")

set(CHEWING_INCLUDE_DIR "" CACHE PATH
    "Directory containing chewing.h (note: src/zhuyin.cpp includes <chewing.h>, \
so point at .../include/chewing, not .../include)")
set(CHEWING_LIBRARY "" CACHE FILEPATH "Path to the static libchewing.a")
set(CHEWING_DATA_DIR "" CACHE PATH
    "Directory holding libchewing's runtime dictionary files, copied into the bundle")

foreach(required CHEWING_INCLUDE_DIR CHEWING_LIBRARY CHEWING_DATA_DIR)
    if(NOT ${required})
        message(FATAL_ERROR
            "${required} is not set. Run macos/build-libchewing-macos.sh first; "
            "it prints the three values.")
    endif()
endforeach()

# --- Core state machine, shared verbatim with the Fcitx5 and WASM builds ------
#
# The core needs no Fcitx5 runtime: it only uses fcitx::Key/KeyStates as types.
# wasm/include holds the header shim that satisfies that, and it must come first
# on the include path so a system Fcitx5 installation cannot shadow it.
#
# ARI_IME_WASM is deliberately NOT defined: the WASM-only branches hardcode
# /usr/share/libchewing and a MEMFS data directory. main.mm points libchewing at
# the bundle through CHEWING_PATH and ARI_IME_USER_DATA_DIR instead, which is
# why src/ needs no macOS-specific changes.
set(ARI_CORE_SOURCES
    "${ARI_SOURCE_ROOT}/src/layout.cpp"
    "${ARI_SOURCE_ROOT}/src/zhuyin.cpp"
    "${ARI_SOURCE_ROOT}/src/buffer.cpp"
    "${ARI_SOURCE_ROOT}/src/user_data.cpp"
)

add_library(ari-ime-core STATIC ${ARI_CORE_SOURCES})
target_include_directories(ari-ime-core
    BEFORE PUBLIC
        "${ARI_SOURCE_ROOT}/wasm/include"
        "${ARI_SOURCE_ROOT}/src"
        "${CHEWING_INCLUDE_DIR}"
)
# build-libchewing-macos.sh pins v0.8.5, which predates chewing_ack().
# ARI_IME_LEGACY_PREFERENCE_PROMOTION is deliberately left undefined: it turns
# promoteUserPhrases() from a no-op into a libchewing replay loop on the typing
# hot path. The WASM build makes the same choice against the same version.
target_compile_definitions(ari-ime-core PUBLIC ARI_IME_LIBCHEWING_LEGACY_OUTPUT)
target_compile_options(ari-ime-core PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(ari-ime-core PUBLIC "${CHEWING_LIBRARY}")

# --- Input method application ------------------------------------------------

find_library(INPUT_METHOD_KIT InputMethodKit REQUIRED)
find_library(COCOA Cocoa REQUIRED)
find_library(CARBON Carbon REQUIRED) # TISRegisterInputSource / kVK_* key codes

configure_file("${CMAKE_CURRENT_LIST_DIR}/Info.plist.in"
               "${CMAKE_CURRENT_BINARY_DIR}/Info.plist" @ONLY)

# Bundle resources are carried by the target rather than copied by a POST_BUILD
# command, so that editing one actually reaches the bundle. A POST_BUILD copy
# runs only when AriIME relinks, and changing artwork does not relink anything:
# the build then reports success while the app keeps the previous icon. Listing
# the files with HEADER_FILE_ONLY does not fix it either — that marks them for
# IDEs without creating a dependency edge. MACOSX_PACKAGE_LOCATION makes CMake
# copy them as part of building the bundle, with the dependency tracked.
set(ARI_BUNDLE_RESOURCES "${CMAKE_CURRENT_LIST_DIR}/ari.pdf")
set_source_files_properties("${CMAKE_CURRENT_LIST_DIR}/ari.pdf" PROPERTIES
    MACOSX_PACKAGE_LOCATION "Resources")
foreach(lproj en ja zh-Hans zh-Hant)
    set(strings "${CMAKE_CURRENT_LIST_DIR}/Resources/${lproj}.lproj/InfoPlist.strings")
    set_source_files_properties("${strings}" PROPERTIES
        MACOSX_PACKAGE_LOCATION "Resources/${lproj}.lproj")
    list(APPEND ARI_BUNDLE_RESOURCES "${strings}")
endforeach()

add_executable(AriIME MACOSX_BUNDLE
    main.mm
    AriInputController.mm
    AriDictionaryWindow.mm
    KeyMap.mm
    ${ARI_BUNDLE_RESOURCES}
)
set_target_properties(AriIME PROPERTIES
    OUTPUT_NAME "${ARI_EXECUTABLE_NAME}"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Info.plist"
)
target_compile_options(AriIME PRIVATE -Wall -Wextra -fobjc-arc)
target_link_libraries(AriIME PRIVATE ari-ime-core "${INPUT_METHOD_KIT}" "${COCOA}" "${CARBON}")

# libchewing's dictionary ships inside the bundle so users install nothing.
add_custom_command(TARGET AriIME POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_directory
            "${CHEWING_DATA_DIR}"
            "$<TARGET_BUNDLE_CONTENT_DIR:AriIME>/Resources/chewing-data"
    COMMENT "Bundling libchewing dictionary"
)
# The menu icon and the localised names the input-source menu needs are carried
# by ARI_BUNDLE_RESOURCES above. Without a .lproj the menu shows the mode's
# identifier and the literal string "CFBundleName"; without the icon, an empty
# tile. Regenerate the icon with: swift macos/make-icon.swift macos/ari.pdf

# --- Personal dictionary tool -------------------------------------------------
#
# Shared verbatim with the Fcitx5 build: inspect, export, import and back up the
# personal phrase dictionary. It goes inside the bundle so it travels with the
# input method; macos/install.sh reports the path.
add_executable(ari-ime-dict "${ARI_SOURCE_ROOT}/src/dict_tool.cpp")
# A shell wrapper takes the plain name and points the tool at the bundled
# dictionary; the binary itself sits beside it.
set_target_properties(ari-ime-dict PROPERTIES OUTPUT_NAME "ari-ime-dict-bin")
target_link_libraries(ari-ime-dict PRIVATE ari-ime-core)
target_compile_definitions(ari-ime-dict
    PRIVATE ARI_IME_CHEWING_VERSION="${ARI_CHEWING_VERSION}")
target_compile_options(ari-ime-dict PRIVATE -Wall -Wextra -Wpedantic)
add_custom_command(TARGET AriIME POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy
            "$<TARGET_FILE:ari-ime-dict>"
            "$<TARGET_BUNDLE_CONTENT_DIR:AriIME>/MacOS/ari-ime-dict-bin"
    COMMAND "${CMAKE_COMMAND}" -E copy
            "${CMAKE_CURRENT_LIST_DIR}/ari-ime-dict.sh"
            "$<TARGET_BUNDLE_CONTENT_DIR:AriIME>/Resources/ari-ime-dict"
    COMMAND chmod +x "$<TARGET_BUNDLE_CONTENT_DIR:AriIME>/Resources/ari-ime-dict"
    COMMENT "Bundling ari-ime-dict"
)
add_dependencies(AriIME ari-ime-dict)

# Apple Silicon refuses to execute an unsigned binary at all, so this is not an
# optional release step. Ad-hoc is enough for local use.
#
# Signing is a stamped command rather than a POST_BUILD one because it has to
# re-run when a bundle RESOURCE changes, not only when the executable relinks.
# Copying a file into a signed bundle breaks the seal, so with POST_BUILD a
# changed icon left the app reporting "a sealed resource is missing or invalid"
# — and further rebuilds did not repair it, because nothing had relinked.
# install.sh refuses an unsigned bundle, which is how that surfaces.
add_custom_command(
    OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/codesign.stamp"
    COMMAND codesign --force --sign - "$<TARGET_BUNDLE_DIR:AriIME>"
    COMMAND "${CMAKE_COMMAND}" -E touch "${CMAKE_CURRENT_BINARY_DIR}/codesign.stamp"
    DEPENDS "$<TARGET_FILE:AriIME>" ${ARI_BUNDLE_RESOURCES}
    COMMENT "Ad-hoc signing the bundle"
    VERBATIM
)
add_custom_target(AriIMESign ALL
    DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/codesign.stamp")
add_dependencies(AriIMESign AriIME)

# --- Tests -------------------------------------------------------------------

include(CTest)
if(BUILD_TESTING)
    add_executable(keymap_test KeyMapTest.mm KeyMap.mm)
    target_compile_options(keymap_test PRIVATE -Wall -Wextra -fobjc-arc)
    target_link_libraries(keymap_test PRIVATE ari-ime-core "${COCOA}" "${CARBON}")
    add_test(NAME keymap COMMAND keymap_test)

    # Drives the controller directly with synthetic events, so the front-end
    # logic can be checked without the system having activated the input method.
    add_executable(controller_test ControllerTest.mm AriInputController.mm
                                   AriDictionaryWindow.mm KeyMap.mm)
    target_compile_options(controller_test PRIVATE -Wall -Wextra -fobjc-arc)
    target_link_libraries(controller_test
        PRIVATE ari-ime-core "${INPUT_METHOD_KIT}" "${COCOA}" "${CARBON}")
    add_test(NAME controller COMMAND controller_test)
    set_tests_properties(controller PROPERTIES
        ENVIRONMENT "CHEWING_PATH=${CHEWING_DATA_DIR};ARI_IME_USER_DATA_DIR=${CMAKE_CURRENT_BINARY_DIR}/test-user-data-controller;ARI_IME_DISABLE_AUTOLEARN=1")

    add_executable(core_smoke_test CoreSmokeTest.cpp)
    target_link_libraries(core_smoke_test PRIVATE ari-ime-core)
    add_test(NAME core_smoke
             COMMAND core_smoke_test "${CHEWING_DATA_DIR}"
                     "${CMAKE_CURRENT_BINARY_DIR}/test-user-data")
endif()
