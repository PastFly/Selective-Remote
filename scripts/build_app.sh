#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="0.19.5"
# CFBundleVersion is an internal monotonically increasing identifier required
# by macOS and the update comparator. It is deliberately not shown as part of
# the public application version.
BUILD_NUMBER="85"
APP_NAME="Selective Remote"
ARTIFACT_NAME="SelectiveRemote"
EXECUTABLE_NAME="SelectiveRemote"
BUILD_ARCH="$(uname -m)"
APP="$ROOT/dist/$APP_NAME.app"
DMG="$ROOT/dist/$ARTIFACT_NAME-$VERSION-$BUILD_ARCH.dmg"
DMG_HASH="$DMG.sha256"
DMG_STAGE="$ROOT/.build/dmg-stage"
DMG_RW="$ROOT/.build/$ARTIFACT_NAME-$VERSION-$BUILD_ARCH-rw.dmg"
DMG_ATTACH_PLIST="$ROOT/.build/dmg-attach.plist"
DMG_BACKGROUND="$DMG_STAGE/.background/installer-background.png"
DMG_VOLUME_NAME="$APP_NAME $VERSION"
BIN_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"
HELPERS_DIR="$APP/Contents/Helpers"
SSH_ASKPASS_HELPER="$HELPERS_DIR/SelectiveRemoteSSHAskPass"
SESSION_APP="$HELPERS_DIR/Selective Remote Session.app"
SESSION_BIN_DIR="$SESSION_APP/Contents/MacOS"
SESSION_RES_DIR="$SESSION_APP/Contents/Resources"
FRAMEWORKS_DIR="$SESSION_APP/Contents/Frameworks"
OPENSSL_MODULES_DIR="$FRAMEWORKS_DIR/ossl-modules"
CAMERA_ADDIN_DIR="$FRAMEWORKS_DIR/lib/freerdp3"
CAMERA_ADDIN=""
SESSION_BIN="$SESSION_BIN_DIR/SelectiveRemoteSession"
APP_ENTITLEMENTS="$ROOT/Resources/SelectiveRemote.entitlements"
SESSION_ENTITLEMENTS="$ROOT/Resources/SelectiveRemoteSession.entitlements"
LICENSES_DIR="$RES_DIR/ThirdPartyLicenses"
UPDATE_FEED_URL="${SELECTIVEREMOTE_UPDATE_FEED_URL:-https://raw.githubusercontent.com/PastFly/Selective-Remote/main/Resources/updates.json}"
NOTARY_PROFILE="${SELECTIVEREMOTE_NOTARY_PROFILE:-}"

DMG_MOUNTED=false
DMG_MOUNT=""
DMG_DEVICE=""
DMG_FINDER_DISK_NAME=""
cleanup_dmg_workspace() {
    if [[ "$DMG_MOUNTED" == "true" ]]; then
        if [[ -n "$DMG_DEVICE" ]]; then
            hdiutil detach "$DMG_DEVICE" -force >/dev/null 2>&1 || true
        elif [[ -n "$DMG_MOUNT" ]]; then
            hdiutil detach "$DMG_MOUNT" -force >/dev/null 2>&1 || true
        fi
    fi
    rm -f "$DMG_RW" "$DMG_ATTACH_PLIST"
}
trap cleanup_dmg_workspace EXIT

attach_dmg() {
    local image="$1"
    local access_mode="$2"
    local index=0
    local candidate=""
    local candidate_device=""
    local fallback_device=""

    DMG_MOUNT=""
    DMG_DEVICE=""
    DMG_FINDER_DISK_NAME=""
    rm -f "$DMG_ATTACH_PLIST"
    hdiutil attach \
        -plist \
        "$access_mode" \
        -noverify \
        -noautoopen \
        -owners off \
        "$image" >"$DMG_ATTACH_PLIST"

    while [[ "$index" -lt 64 ]]; do
        candidate="$(
            /usr/libexec/PlistBuddy \
                -c "Print :system-entities:$index:mount-point" \
                "$DMG_ATTACH_PLIST" 2>/dev/null \
                || true
        )"
        candidate_device="$(
            /usr/libexec/PlistBuddy \
                -c "Print :system-entities:$index:dev-entry" \
                "$DMG_ATTACH_PLIST" 2>/dev/null \
                || true
        )"
        if [[ -n "$candidate" ]]; then
            DMG_MOUNT="$candidate"
            DMG_DEVICE="$candidate_device"
            break
        fi
        if [[ -z "$fallback_device" && -n "$candidate_device" ]]; then
            fallback_device="$candidate_device"
        fi
        index=$((index + 1))
    done

    if [[ -z "$DMG_MOUNT" ]]; then
        if [[ -n "$fallback_device" ]]; then
            hdiutil detach "$fallback_device" -force >/dev/null 2>&1 || true
        fi
        echo "Ошибка: hdiutil не вернул точку монтирования для $image" >&2
        exit 1
    fi

    DMG_FINDER_DISK_NAME="$(basename "$DMG_MOUNT")"
    DMG_MOUNTED=true
}

detach_dmg() {
    local attempt
    local target

    if [[ "$DMG_MOUNTED" != "true" ]]; then
        return
    fi
    target="${DMG_DEVICE:-$DMG_MOUNT}"
    if [[ -z "$target" ]]; then
        echo "Ошибка: отсутствует идентификатор подключённого DMG" >&2
        return 1
    fi

    for attempt in 1 2 3; do
        if hdiutil detach "$target" >/dev/null 2>&1; then
            DMG_MOUNTED=false
            DMG_MOUNT=""
            DMG_DEVICE=""
            DMG_FINDER_DISK_NAME=""
            rm -f "$DMG_ATTACH_PLIST"
            return
        fi
        sleep 1
    done

    if ! hdiutil detach "$target" -force >/dev/null 2>&1; then
        if [[ -n "$DMG_DEVICE" ]] \
                && hdiutil info | grep -Fq -- "$DMG_DEVICE"; then
            echo "Ошибка: не удалось отключить $DMG_DEVICE" >&2
            return 1
        fi
        if [[ -z "$DMG_DEVICE" && -d "$DMG_MOUNT" ]]; then
            echo "Ошибка: не удалось отключить $DMG_MOUNT" >&2
            return 1
        fi
    fi
    DMG_MOUNTED=false
    DMG_MOUNT=""
    DMG_DEVICE=""
    DMG_FINDER_DISK_NAME=""
    rm -f "$DMG_ATTACH_PLIST"
}

if ! command -v brew >/dev/null 2>&1; then
    echo "Ошибка: Homebrew нужен на Mac, где создаётся distributable-сборка" >&2
    exit 1
fi

swift test
swift build -c release

SIGN_IDENTITY="${SELECTIVEREMOTE_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' '/"Developer ID Application:/{print $2; exit}' \
            || true
    )"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' '/"Apple Development:/{print $2; exit}' \
            || true
    )"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="-"
fi

if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
    DISTRIBUTION_SIGNING=true
else
    DISTRIBUTION_SIGNING=false
fi

if [[ -d "$APP" ]]; then
    rm -rf "$APP"
fi
rm -f "$DMG" "$DMG_HASH" "$DMG_RW" "$DMG_ATTACH_PLIST"
rm -rf "$DMG_STAGE"
mkdir -p \
    "$BIN_DIR" \
    "$RES_DIR" \
    "$FRAMEWORKS_DIR" \
    "$SESSION_BIN_DIR" \
    "$SESSION_RES_DIR" \
    "$LICENSES_DIR" \
    "$DMG_STAGE/.background"

cp "$ROOT/.build/release/$EXECUTABLE_NAME" "$BIN_DIR/$EXECUTABLE_NAME"
xcrun swiftc \
    -O \
    -parse-as-library \
    -target "$BUILD_ARCH-apple-macos14.0" \
    "$ROOT/Native/SSHKeychainAskPass.swift" \
    -framework AppKit \
    -o "$SSH_ASKPASS_HELPER"

HOMEBREW_PREFIX="$(brew --prefix)"
FREERDP_PREFIX="$(brew --prefix freerdp)"
SDL_FREERDP="$FREERDP_PREFIX/bin/sdl-freerdp"
FREERDP_INCLUDE="$FREERDP_PREFIX/include/freerdp3"
WINPR_INCLUDE="$FREERDP_PREFIX/include/winpr3"
SDL_PREFIX="$(brew --prefix sdl3)"
SDL_INCLUDE="$SDL_PREFIX/include"
OPENSSL_PREFIX="$(brew --prefix openssl@3 2>/dev/null || true)"
OPENSSL_LEGACY_SOURCE="$OPENSSL_PREFIX/lib/ossl-modules/legacy.dylib"
OPENSSL_LEGACY_MODULE="$OPENSSL_MODULES_DIR/legacy.dylib"
INTERPOSER="$FRAMEWORKS_DIR/SelectiveRemoteMonitorInterposer.dylib"
INTERPOSER_CPP_OBJECT="$ROOT/.build/MonitorTopologyInterposer.o"
FN_SHORTCUT="$FRAMEWORKS_DIR/SelectiveRemoteFnShortcut.dylib"
FN_SHORTCUT_OBJECT="$ROOT/.build/FnLanguageShortcut.o"
PRIVACY_PREFLIGHT="$FRAMEWORKS_DIR/SelectiveRemotePrivacyPreflight.dylib"
NATIVE_TEST="$ROOT/.build/SelectiveRemoteMonitorInterposerTests"
PTY_NATIVE_TEST="$ROOT/.build/SelectiveRemotePTYBridgeTests"
CAMERA_OBJECT_DIR="$ROOT/.build/camera"
ADDIN_INFO_PROBE="$ROOT/.build/SelectiveRemoteAddinInfo"
ADDIN_LOADER_SMOKE="$ROOT/.build/SelectiveRemoteCameraAddinSmoke"

if [[ ! -f "$FREERDP_INCLUDE/freerdp/settings.h" ]]; then
    echo "Ошибка: заголовки FreeRDP не найдены. Выполните: brew reinstall freerdp" >&2
    exit 1
fi
if [[ ! -x "$SDL_FREERDP" ]]; then
    echo "Ошибка: $SDL_FREERDP не найден. Выполните: brew reinstall freerdp" >&2
    exit 1
fi
if [[ ! -f "$SDL_INCLUDE/SDL3/SDL.h" ]]; then
    echo "Ошибка: заголовки SDL3 не найдены. Выполните: brew reinstall sdl3" >&2
    exit 1
fi
if [[ -z "$OPENSSL_PREFIX" || ! -f "$OPENSSL_LEGACY_SOURCE" ]]; then
    echo "Ошибка: модуль OpenSSL legacy не найден. Выполните: brew reinstall openssl@3 freerdp" >&2
    exit 1
fi
if [[ ! -f "$SESSION_ENTITLEMENTS" ]]; then
    echo "Ошибка: не найден $SESSION_ENTITLEMENTS" >&2
    exit 1
fi
if [[ ! -f "$APP_ENTITLEMENTS" ]]; then
    echo "Ошибка: не найден $APP_ENTITLEMENTS" >&2
    exit 1
fi
if ! /usr/libexec/PlistBuddy \
        -c "Print :com.apple.security.device.camera" \
        "$APP_ENTITLEMENTS" 2>/dev/null \
        | grep -qx 'true'; then
    echo "Ошибка: основное приложение должно иметь entitlement Camera для списка устройств" >&2
    exit 1
fi
if ! /usr/libexec/PlistBuddy \
        -c "Print :com.apple.security.device.audio-input" \
        "$APP_ENTITLEMENTS" 2>/dev/null \
        | grep -qx 'true'; then
    echo "Ошибка: основное приложение должно иметь entitlement Audio Input для TCC-атрибуции дочерней RDP-сессии" >&2
    exit 1
fi
if ! /usr/libexec/PlistBuddy \
        -c "Print :com.apple.security.device.audio-input" \
        "$SESSION_ENTITLEMENTS" 2>/dev/null \
        | grep -qx 'true'; then
    echo "Ошибка: Session helper должен иметь entitlement Audio Input" >&2
    exit 1
fi
if ! /usr/libexec/PlistBuddy \
        -c "Print :com.apple.security.device.camera" \
        "$SESSION_ENTITLEMENTS" 2>/dev/null \
        | grep -qx 'true'; then
    echo "Ошибка: Session helper должен иметь entitlement Camera" >&2
    exit 1
fi
xcrun clang++ \
    -std=c++17 \
    -O2 \
    -mmacosx-version-min=14.0 \
    -DSELECTIVE_RDP_TESTING \
    -I"$FREERDP_INCLUDE" \
    -I"$WINPR_INCLUDE" \
    "$ROOT/Native/MonitorTopologyInterposer.cpp" \
    "$ROOT/Tests/Native/MonitorTopologyInterposerTests.cpp" \
    -L"$FREERDP_PREFIX/lib" \
    -Wl,-rpath,"$FREERDP_PREFIX/lib" \
    -lfreerdp3 \
    -o "$NATIVE_TEST"

echo "[SelectiveRemote] Running monitor topology tests"
"$NATIVE_TEST"

echo "[SelectiveRemote] Building deterministic PTY bridge test"
xcrun clang \
    -std=c11 \
    -O2 \
    -mmacosx-version-min=14.0 \
    -I"$ROOT/Sources/PTYBridge/include" \
    "$ROOT/Sources/PTYBridge/PTYBridge.c" \
    "$ROOT/Tests/Native/PTYBridgeTests.c" \
    -o "$PTY_NATIVE_TEST"

echo "[SelectiveRemote] Running deterministic PTY bridge test"
"$PTY_NATIVE_TEST"

xcrun clang++ \
    -std=c++17 \
    -O2 \
    -mmacosx-version-min=14.0 \
    -c \
    -I"$FREERDP_INCLUDE" \
    -I"$WINPR_INCLUDE" \
    -I"$SDL_INCLUDE" \
    "$ROOT/Native/MonitorTopologyInterposer.cpp" \
    -o "$INTERPOSER_CPP_OBJECT"

xcrun clang++ \
    -mmacosx-version-min=14.0 \
    -dynamiclib \
    "$INTERPOSER_CPP_OBJECT" \
    -L"$FREERDP_PREFIX/lib" \
    -L"$SDL_PREFIX/lib" \
    -Wl,-rpath,"$FREERDP_PREFIX/lib" \
    -Wl,-rpath,"$SDL_PREFIX/lib" \
    -Wl,-install_name,@rpath/SelectiveRemoteMonitorInterposer.dylib \
    -lfreerdp3 \
    -lwinpr3 \
    -lSDL3 \
    -o "$INTERPOSER"

xcrun clang++ \
    -std=c++17 \
    -fobjc-arc \
    -fblocks \
    -O2 \
    -fPIC \
    -mmacosx-version-min=14.0 \
    -c \
    -I"$SDL_INCLUDE" \
    "$ROOT/Native/FnLanguageShortcut.mm" \
    -o "$FN_SHORTCUT_OBJECT"

xcrun clang++ \
    -mmacosx-version-min=14.0 \
    -dynamiclib \
    "$FN_SHORTCUT_OBJECT" \
    -L"$SDL_PREFIX/lib" \
    -Wl,-rpath,"$SDL_PREFIX/lib" \
    -Wl,-install_name,@rpath/SelectiveRemoteFnShortcut.dylib \
    -lSDL3 \
    -framework AppKit \
    -o "$FN_SHORTCUT"

# This module may observe AppKit events and enqueue SDL events only. A future
# accidental return to FreeRDP function interposition must fail the build: that
# design previously caused the RDP window to remain black.
if /usr/bin/otool -l "$FN_SHORTCUT" \
        | /usr/bin/grep -F 'sectname __interpose' >/dev/null; then
    echo "Ошибка: Fn-модуль не должен содержать таблицу DYLD interpose" >&2
    exit 1
fi

xcrun clang \
    -std=c17 \
    -fobjc-arc \
    -fblocks \
    -O2 \
    -fPIC \
    -mmacosx-version-min=14.0 \
    -dynamiclib \
    -I"$SDL_INCLUDE" \
    "$ROOT/Native/PrivacyPermissionPreflight.m" \
    -L"$SDL_PREFIX/lib" \
    -Wl,-rpath,"$SDL_PREFIX/lib" \
    -Wl,-install_name,@rpath/SelectiveRemotePrivacyPreflight.dylib \
    -lSDL3 \
    -framework AVFoundation \
    -framework Foundation \
    -o "$PRIVACY_PREFLIGHT"

if ! /usr/bin/otool -l "$PRIVACY_PREFLIGHT" \
        | /usr/bin/grep -F 'sectname __interpose' >/dev/null; then
    echo "Ошибка: privacy preflight не содержит таблицу DYLD interpose" >&2
    exit 1
fi

# FreeRDP's channel loader uses a compile-time addin directory and the
# platform's shared-library suffix. Only the public API is available to
# consumers of the Homebrew headers: FREERDP_INSTALL_PREFIX and
# FREERDP_ADDIN_PATH are private build-time macros and are intentionally not
# exported by freerdp/config.h. Query the effective full addin path instead,
# then split it using Homebrew's resolved keg prefix.
ADDIN_INFO_SOURCE="$ROOT/.build/SelectiveRemoteAddinInfo.cpp"
ADDIN_INFO_OUTPUT="$ROOT/.build/SelectiveRemoteAddinInfo.txt"
cat >"$ADDIN_INFO_SOURCE" <<'ADDIN_INFO_C'
#include <stdio.h>
#include <stdlib.h>
#include <freerdp/addin.h>
#include <winpr/path.h>

int main(void)
{
    char* dynamicPath = freerdp_get_dynamic_addin_install_path();
    const char* extension = PathGetSharedLibraryExtensionA(0);
    printf("%s\n", extension ? extension : "");
    printf("%s\n", dynamicPath ? dynamicPath : "");
    free(dynamicPath);
    return 0;
}
ADDIN_INFO_C
xcrun clang++ \
    -std=c++17 \
    -O2 \
    -mmacosx-version-min=14.0 \
    -I"$FREERDP_INCLUDE" \
    -I"$WINPR_INCLUDE" \
    "$ADDIN_INFO_SOURCE" \
    -L"$FREERDP_PREFIX/lib" \
    -Wl,-rpath,"$FREERDP_PREFIX/lib" \
    -lfreerdp3 \
    -lwinpr3 \
    -o "$ADDIN_INFO_PROBE"
"$ADDIN_INFO_PROBE" >"$ADDIN_INFO_OUTPUT"
CAMERA_ADDIN_EXTENSION="$(/usr/bin/sed -n '1p' "$ADDIN_INFO_OUTPUT")"
FREERDP_DYNAMIC_ADDIN_PATH="$(/usr/bin/sed -n '2p' "$ADDIN_INFO_OUTPUT")"
FREERDP_COMPILED_PREFIX=""
FREERDP_ADDIN_RELATIVE_PATH=""

if [[ -z "$CAMERA_ADDIN_EXTENSION" \
      || "$CAMERA_ADDIN_EXTENSION" == */* \
      || "$CAMERA_ADDIN_EXTENSION" == .* ]]; then
    echo "Ошибка: FreeRDP вернул некорректное расширение addin: $CAMERA_ADDIN_EXTENSION" >&2
    exit 1
fi
if [[ -n "$FREERDP_DYNAMIC_ADDIN_PATH" ]]; then
    FREERDP_PREFIX_REAL="$(cd -P "$FREERDP_PREFIX" && pwd)"

    if [[ "$FREERDP_DYNAMIC_ADDIN_PATH" == "$FREERDP_PREFIX_REAL/"* ]]; then
        FREERDP_COMPILED_PREFIX="$FREERDP_PREFIX_REAL"
        FREERDP_ADDIN_RELATIVE_PATH="${FREERDP_DYNAMIC_ADDIN_PATH#"$FREERDP_PREFIX_REAL/"}"
    elif [[ "$FREERDP_DYNAMIC_ADDIN_PATH" == "$FREERDP_PREFIX/"* ]]; then
        FREERDP_COMPILED_PREFIX="$FREERDP_PREFIX"
        FREERDP_ADDIN_RELATIVE_PATH="${FREERDP_DYNAMIC_ADDIN_PATH#"$FREERDP_PREFIX/"}"
    else
        # Homebrew normally compiles FreeRDP with a Cellar prefix, while
        # `brew --prefix freerdp` may expose the stable opt symlink. Keep a
        # conservative fallback for the standard FreeRDP 3 addin directories.
        for candidate in lib/freerdp3 lib64/freerdp3; do
            if [[ "$FREERDP_DYNAMIC_ADDIN_PATH" == */"$candidate" ]]; then
                FREERDP_COMPILED_PREFIX="${FREERDP_DYNAMIC_ADDIN_PATH%/"$candidate"}"
                FREERDP_ADDIN_RELATIVE_PATH="$candidate"
                break
            fi
        done
    fi

    case "$FREERDP_COMPILED_PREFIX" in
        ""|"/"|".")
            echo "Ошибка: не удалось определить compile-time prefix FreeRDP из $FREERDP_DYNAMIC_ADDIN_PATH" >&2
            exit 1
            ;;
    esac
    case "$FREERDP_ADDIN_RELATIVE_PATH" in
        ""|/*|*".."*)
            echo "Ошибка: FreeRDP использует непереносимый addin path: $FREERDP_ADDIN_RELATIVE_PATH" >&2
            exit 1
            ;;
    esac

    CAMERA_ADDIN_DIR="$FRAMEWORKS_DIR/$FREERDP_ADDIN_RELATIVE_PATH"
else
    # WITH_ADD_PLUGIN_TO_RPATH builds load the addin by leaf name. The helper
    # already prepends its Frameworks directory to DYLD_LIBRARY_PATH.
    CAMERA_ADDIN_DIR="$FRAMEWORKS_DIR"
fi
mkdir -p "$CAMERA_ADDIN_DIR" "$CAMERA_OBJECT_DIR"
CAMERA_ADDIN="$CAMERA_ADDIN_DIR/librdpecam-client.$CAMERA_ADDIN_EXTENSION"

if xcrun clang -std=c23 -E -x c /dev/null >/dev/null 2>&1; then
    CAMERA_C_STANDARD="-std=c23"
else
    CAMERA_C_STANDARD="-std=c2x"
fi
CAMERA_C_FLAGS=(
    "$CAMERA_C_STANDARD"
    -O2
    -fPIC
    -mmacosx-version-min=14.0
    -I"$FREERDP_INCLUDE"
    -I"$WINPR_INCLUDE"
    -I"$ROOT/Native/Camera/FreeRDP"
)

xcrun clang "${CAMERA_C_FLAGS[@]}" \
    -Drdpecam_DVCPluginEntry=DVCPluginEntry \
    -c "$ROOT/Native/Camera/FreeRDP/camera_device_enum_main.c" \
    -o "$CAMERA_OBJECT_DIR/camera_device_enum_main.o"
xcrun clang "${CAMERA_C_FLAGS[@]}" \
    -c "$ROOT/Native/Camera/FreeRDP/camera_device_main.c" \
    -o "$CAMERA_OBJECT_DIR/camera_device_main.o"
xcrun clang "${CAMERA_C_FLAGS[@]}" \
    -c "$ROOT/Native/Camera/FreeRDP/encoding.c" \
    -o "$CAMERA_OBJECT_DIR/encoding.o"
xcrun clang++ \
    -std=c++17 \
    -fobjc-arc \
    -O2 \
    -fPIC \
    -mmacosx-version-min=14.0 \
    -I"$FREERDP_INCLUDE" \
    -I"$WINPR_INCLUDE" \
    -I"$ROOT/Native/Camera" \
    -c "$ROOT/Native/Camera/AVFoundationCamera.mm" \
    -o "$CAMERA_OBJECT_DIR/AVFoundationCamera.o"

xcrun clang++ \
    -mmacosx-version-min=14.0 \
    -dynamiclib \
    "$CAMERA_OBJECT_DIR/camera_device_enum_main.o" \
    "$CAMERA_OBJECT_DIR/camera_device_main.o" \
    "$CAMERA_OBJECT_DIR/encoding.o" \
    "$CAMERA_OBJECT_DIR/AVFoundationCamera.o" \
    -L"$FREERDP_PREFIX/lib" \
    -Wl,-rpath,"$FREERDP_PREFIX/lib" \
    -Wl,-install_name,"@rpath/$(basename "$CAMERA_ADDIN")" \
    -lfreerdp3 \
    -lwinpr3 \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework Foundation \
    -o "$CAMERA_ADDIN"

if ! /usr/bin/nm -gU "$CAMERA_ADDIN" | /usr/bin/grep -Eq '[[:space:]]_DVCPluginEntry$'; then
    echo "Ошибка: camera addin не экспортирует DVCPluginEntry" >&2
    exit 1
fi

sign_code() {
    local target="$1"
    shift
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
        codesign --force --sign - "$@" "$target"
    else
        codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@" "$target"
    fi
}

# The first signature is only for the Homebrew launch smoke test. Dependency
# rewriting below invalidates it, so every nested component is signed again.
sign_code "$INTERPOSER"
sign_code "$FN_SHORTCUT"

run_monitor_smoke() {
    local client="$1"
    local interposer="$2"
    local log="$3"
    local frameworks="${4:-}"
    local ca_bundle="${5:-}"
    local openssl_modules="${6:-}"
    local smoke_pid
    local smoke_finished=false
    local smoke_environment=(
        /usr/bin/env
        "DYLD_INSERT_LIBRARIES=$interposer"
        "SDL_QUIT_ON_LAST_WINDOW_CLOSE=0"
        "FREERDP_WLROOTS_HACK=force"
        "SELECTIVE_RDP_PREFLIGHT_MICROPHONE=0"
        "SELECTIVE_RDP_PREFLIGHT_CAMERA=0"
        "SELECTIVE_RDP_FN_LANGUAGE_SWITCH=1"
    )
    if [[ -n "$frameworks" ]]; then
        smoke_environment+=("DYLD_LIBRARY_PATH=$frameworks")
    fi
    if [[ -n "$ca_bundle" && -f "$ca_bundle" ]]; then
        smoke_environment+=("SSL_CERT_FILE=$ca_bundle")
    fi
    if [[ -n "$openssl_modules" && -d "$openssl_modules" ]]; then
        smoke_environment+=("OPENSSL_MODULES=$openssl_modules")
    fi

    "${smoke_environment[@]}" \
        "$client" -grab-keyboard -grab-mouse /list:monitor >"$log" 2>&1 &
    smoke_pid=$!
    local attempt
    for ((attempt = 0; attempt < 80; attempt++)); do
        if ! kill -0 "$smoke_pid" 2>/dev/null; then
            smoke_finished=true
            break
        fi
        sleep 0.1
    done

    if [[ "$smoke_finished" != "true" ]]; then
        kill -TERM "$smoke_pid" 2>/dev/null || true
        sleep 0.5
        kill -KILL "$smoke_pid" 2>/dev/null || true
        wait "$smoke_pid" 2>/dev/null || true
        echo "Ошибка: smoke-тест SDL-FreeRDP завис" >&2
        echo "Журнал: $log" >&2
        exit 1
    fi
    wait "$smoke_pid" 2>/dev/null || true

    if ! grep -Eq 'listing [0-9]+ monitors' "$log"; then
        echo "Ошибка: smoke-тест SDL-FreeRDP не вернул список мониторов" >&2
        echo "Журнал: $log" >&2
        exit 1
    fi
}

# Catch loader/interposition deadlocks before changing any dependency paths.
HOME_BREW_SMOKE_LOG="$ROOT/.build/SelectiveRemoteHomebrewLaunchSmoke.log"
run_monitor_smoke \
    "$SDL_FREERDP" \
    "$FN_SHORTCUT:$INTERPOSER" \
    "$HOME_BREW_SMOKE_LOG"
echo "Homebrew SDL-FreeRDP launch smoke test passed"

# Generate a native multi-resolution macOS icon from the checked-in source.
ICON_SOURCE="$ROOT/Resources/AppIcon-Source.png"
ICONSET="$ROOT/.build/AppIcon.iconset"
if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "Ошибка: не найден исходник иконки $ICON_SOURCE" >&2
    exit 1
fi
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
while read -r filename size; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/$filename" >/dev/null
done <<'ICON_SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
ICON_SIZES
iconutil -c icns "$ICONSET" -o "$RES_DIR/AppIcon.icns"
cp "$RES_DIR/AppIcon.icns" "$SESSION_RES_DIR/AppIcon.icns"
cp "$ROOT/Resources/updates.example.json" "$RES_DIR/updates.example.json"
cp "$ROOT/Resources/THIRD-PARTY-NOTICES.txt" "$LICENSES_DIR/SelectiveRemote-Notices.txt"
cp -R "$ROOT/Sources/SelectiveRemote/TerminalResources" "$RES_DIR/TerminalResources"
cp -R "$ROOT/Resources/en.lproj" "$RES_DIR/en.lproj"
cp -R "$ROOT/Resources/ru.lproj" "$RES_DIR/ru.lproj"
cp -R "$ROOT/Resources/en.lproj" "$SESSION_RES_DIR/en.lproj"
cp -R "$ROOT/Resources/ru.lproj" "$SESSION_RES_DIR/ru.lproj"
cp "$ROOT/Native/Camera/FreeRDP/LICENSE" "$LICENSES_DIR/FreeRDP-RDPECAM-Apache-2.0.txt"

# Run the RDP engine from a real nested application bundle. macOS can then
# present each child as “Selective Remote Session” instead of a raw executable.
cp "$SDL_FREERDP" "$SESSION_BIN"
chmod +x "$SESSION_BIN"

/usr/libexec/PlistBuddy -c "Clear dict" "$SESSION_APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleName string Selective Remote Session" "$SESSION_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Selective Remote Session" "$SESSION_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string local.selectiveremote.session" "$SESSION_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string SelectiveRemoteSession" "$SESSION_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$SESSION_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$SESSION_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string ru" "$SESSION_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations array" "$SESSION_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations:0 string ru" "$SESSION_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations:1 string en" "$SESSION_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$SESSION_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$SESSION_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$SESSION_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$SESSION_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string Selective Remote передаёт звук с микрофона на удалённый компьютер только в профилях с включённым микрофоном." "$SESSION_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSCameraUsageDescription string Selective Remote передаёт изображение с выбранной камеры на удалённый компьютер только в профилях с включённой камерой." "$SESSION_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSCameraUseContinuityCameraDeviceType bool true" "$SESSION_APP/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Clear dict" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleName string Selective Remote" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Selective Remote" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string local.selectiveremote" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $EXECUTABLE_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string ru" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations array" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations:0 string ru" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations:1 string en" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string Selective Remote передаёт звук с микрофона на удалённый компьютер только после запуска профиля с включённым микрофоном." "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSCameraUsageDescription string Selective Remote показывает доступные камеры для выбора в профиле; захват выполняет только «Selective Remote Session» после подключения." "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSCameraUseContinuityCameraDeviceType bool true" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SelectiveRemoteBuildArchitecture string $BUILD_ARCH" "$APP/Contents/Info.plist"
if [[ -n "$UPDATE_FEED_URL" ]]; then
    if [[ "$UPDATE_FEED_URL" != https://* ]]; then
        echo "Ошибка: SELECTIVEREMOTE_UPDATE_FEED_URL должен начинаться с https://" >&2
        exit 1
    fi
    /usr/libexec/PlistBuddy -c "Add :SelectiveRemoteUpdateFeedURL string $UPDATE_FEED_URL" "$APP/Contents/Info.plist"
fi

require_nonempty_plist_string() {
    local plist="$1"
    local key="$2"
    local bundle_name="$3"
    local value
    value="$(
        /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null \
            || true
    )"
    if [[ -z "${value//[[:space:]]/}" ]]; then
        echo "Ошибка: $bundle_name не содержит непустой ключ $key" >&2
        exit 1
    fi
}

verify_capture_privacy_metadata() {
    local bundle="$1"
    local bundle_name="$2"
    local plist="$bundle/Contents/Info.plist"

    /usr/bin/plutil -lint "$plist" >/dev/null
    require_nonempty_plist_string \
        "$plist" \
        "NSMicrophoneUsageDescription" \
        "$bundle_name"
    require_nonempty_plist_string \
        "$plist" \
        "NSCameraUsageDescription" \
        "$bundle_name"
}

# TCC may attribute a protected-resource request either to the nested session
# process or to the outer app that launched it. Both bundles therefore need
# complete purpose strings; otherwise macOS terminates the session with
# __TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__ before a permission dialog appears.
verify_capture_privacy_metadata "$SESSION_APP" "Selective Remote Session"
verify_capture_privacy_metadata "$APP" "$APP_NAME"

# Resolve symlinks without relying on GNU readlink -f, which macOS does not
# provide. Directory components and the final file link are both followed.
canonical_path() {
    local path="$1"
    local directory
    local link
    while true; do
        directory="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd)" || return 1
        path="$directory/$(basename "$path")"
        if [[ ! -L "$path" ]]; then
            break
        fi
        link="$(readlink "$path")"
        if [[ "$link" == /* ]]; then
            path="$link"
        else
            path="$directory/$link"
        fi
    done
    printf '%s\n' "$path"
}

rpaths_for_binary() {
    /usr/bin/otool -l "$1" 2>/dev/null \
        | /usr/bin/awk '/cmd LC_RPATH/{found=1; next} found && $1 == "path" {print $2; found=0}'
}

dependencies_for_binary() {
    # otool separates the path from its version metadata with the literal
    # " (compatibility version" marker. Reading only awk field $1 breaks as
    # soon as an application directory contains a space.
    /usr/bin/otool -L "$1" 2>/dev/null \
        | /usr/bin/awk 'NR > 1 {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+\(compatibility version.*$/, "", line)
            if (length(line) > 0) print line
        }'
}

run_install_name_tool() {
    local output
    if ! output="$(/usr/bin/install_name_tool "$@" 2>&1)"; then
        printf '%s\n' "$output" >&2
        return 1
    fi
}

expand_origin_path() {
    local value="$1"
    local source="$2"
    local executable_directory="$3"
    case "$value" in
        @loader_path*)
            printf '%s%s\n' "$(dirname "$source")" "${value#@loader_path}"
            ;;
        @executable_path*)
            printf '%s%s\n' "$executable_directory" "${value#@executable_path}"
            ;;
        /*)
            printf '%s\n' "$value"
            ;;
        *)
            return 1
            ;;
    esac
}

resolve_dependency() {
    local dependency="$1"
    local source="$2"
    local executable_directory="$3"
    local candidate
    local suffix
    local rpath
    local expanded_rpath
    local basename_only="$(basename "$dependency")"

    case "$dependency" in
        /*|@loader_path*|@executable_path*)
            candidate="$(expand_origin_path "$dependency" "$source" "$executable_directory" 2>/dev/null || true)"
            if [[ -n "$candidate" && -f "$candidate" ]]; then
                canonical_path "$candidate"
                return 0
            fi
            ;;
        @rpath/*)
            suffix="${dependency#@rpath/}"
            while IFS= read -r rpath; do
                [[ -n "$rpath" ]] || continue
                expanded_rpath="$(expand_origin_path "$rpath" "$source" "$executable_directory" 2>/dev/null || true)"
                [[ -n "$expanded_rpath" ]] || continue
                candidate="$expanded_rpath/$suffix"
                if [[ -f "$candidate" ]]; then
                    canonical_path "$candidate"
                    return 0
                fi
            done < <(rpaths_for_binary "$source")
            ;;
    esac

    for candidate in \
        "$(dirname "$source")/$basename_only" \
        "$FREERDP_PREFIX/lib/$basename_only" \
        "$SDL_PREFIX/lib/$basename_only" \
        "$HOMEBREW_PREFIX/lib/$basename_only"; do
        if [[ -f "$candidate" ]]; then
            canonical_path "$candidate"
            return 0
        fi
    done

    candidate="$(/usr/bin/find "$HOMEBREW_PREFIX/Cellar" \
        \( -type f -o -type l \) -name "$basename_only" -path '*/lib/*' -print 2>/dev/null \
        | /usr/bin/head -n 1 || true)"
    if [[ -n "$candidate" && -f "$candidate" ]]; then
        canonical_path "$candidate"
        return 0
    fi
    return 1
}

FORMULAS_LIST="$ROOT/.build/bundled-formulas.txt"
BUNDLED_MAP="$ROOT/.build/bundled-dylibs.map"
: >"$FORMULAS_LIST"
: >"$BUNDLED_MAP"
printf 'Third-party formula licenses copied into this directory:\n' >"$LICENSES_DIR/README.txt"

copy_formula_notices() {
    local source="$1"
    local canonical
    local relative
    local formula
    local after_formula
    local formula_version
    local formula_root
    local destination
    local notice
    local safe_name

    canonical="$(canonical_path "$source" 2>/dev/null || true)"
    case "$canonical" in
        "$HOMEBREW_PREFIX/Cellar/"*) ;;
        *) return 0 ;;
    esac

    relative="${canonical#"$HOMEBREW_PREFIX/Cellar/"}"
    formula="${relative%%/*}"
    after_formula="${relative#*/}"
    formula_version="${after_formula%%/*}"
    formula_root="$HOMEBREW_PREFIX/Cellar/$formula/$formula_version"
    if grep -Fxq "$formula $formula_version" "$FORMULAS_LIST"; then
        return 0
    fi
    printf '%s %s\n' "$formula" "$formula_version" >>"$FORMULAS_LIST"
    printf -- '- %s %s\n' "$formula" "$formula_version" >>"$LICENSES_DIR/README.txt"
    destination="$LICENSES_DIR/$formula-$formula_version"
    mkdir -p "$destination"

    while IFS= read -r notice; do
        [[ -n "$notice" ]] || continue
        safe_name="${notice#"$formula_root/"}"
        safe_name="${safe_name//\//_}"
        cp "$notice" "$destination/$safe_name"
    done < <(/usr/bin/find "$formula_root" -type f \
        \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'COPYRIGHT*' -o -iname 'NOTICE*' \) \
        -print 2>/dev/null || true)
}

copy_formula_notices "$SDL_FREERDP"

mapped_source_for_basename() {
    /usr/bin/awk -F '|' -v name="$1" '$1 == name {print $2; exit}' "$BUNDLED_MAP"
}

relative_reference_for() {
    local target="$1"
    local basename_only="$2"
    case "$target" in
        "$SESSION_BIN_DIR/"*)
            printf '@loader_path/../Frameworks/%s\n' "$basename_only"
            ;;
        "$CAMERA_ADDIN_DIR/"*)
            if [[ "$CAMERA_ADDIN_DIR" == "$FRAMEWORKS_DIR" ]]; then
                printf '@loader_path/%s\n' "$basename_only"
            else
                local camera_depth
                local camera_relative="${CAMERA_ADDIN_DIR#"$FRAMEWORKS_DIR"/}"
                camera_depth="$(printf '%s' "$camera_relative" | /usr/bin/awk -F/ '{print NF}')"
                local upward=""
                local index=0
                while [[ "$index" -lt "$camera_depth" ]]; do
                    upward="../$upward"
                    index=$((index + 1))
                done
                printf '@loader_path/%s%s\n' "$upward" "$basename_only"
            fi
            ;;
        "$OPENSSL_MODULES_DIR/"*)
            printf '@loader_path/../%s\n' "$basename_only"
            ;;
        "$FRAMEWORKS_DIR/"*)
            printf '@loader_path/%s\n' "$basename_only"
            ;;
        *)
            echo "Ошибка: неизвестное расположение Mach-O: $target" >&2
            return 1
            ;;
    esac
}

strip_homebrew_rpaths() {
    local target="$1"
    local rpath
    while IFS= read -r rpath; do
        [[ -n "$rpath" ]] || continue
        if [[ "$rpath" == "$HOMEBREW_PREFIX"* \
              || "$rpath" == /opt/homebrew/* \
              || "$rpath" == /usr/local/Cellar/* \
              || "$rpath" == /usr/local/opt/* ]]; then
            run_install_name_tool -delete_rpath "$rpath" "$target"
        fi
    done < <(rpaths_for_binary "$target")
}

bundle_dependencies() {
    local target="$1"
    local source="$2"
    local executable_directory="$3"
    local own_id
    local dependency
    local basename_only
    local mapped_source
    local resolved
    local canonical
    local destination
    local new_reference

    chmod u+w "$target"
    own_id="$(/usr/bin/otool -D "$source" 2>/dev/null \
        | /usr/bin/sed -n '2{s/^[[:space:]]*//; s/[[:space:]]*$//; p;}' || true)"
    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        [[ "$dependency" != "$own_id" ]] || continue
        case "$dependency" in
            /System/Library/*|/usr/lib/*) continue ;;
        esac

        basename_only="$(basename "$dependency")"
        mapped_source="$(mapped_source_for_basename "$basename_only")"
        if [[ -n "$mapped_source" ]]; then
            resolved="$(resolve_dependency "$dependency" "$source" "$executable_directory" 2>/dev/null || true)"
            if [[ -n "$resolved" \
                  && "$(canonical_path "$resolved")" != "$(canonical_path "$mapped_source")" ]]; then
                echo "Ошибка: конфликт библиотек с одинаковым именем $basename_only" >&2
                exit 1
            fi
            resolved="$mapped_source"
        else
            resolved="$(resolve_dependency "$dependency" "$source" "$executable_directory" 2>/dev/null || true)"
            if [[ -z "$resolved" ]]; then
                echo "Ошибка: не удалось разрешить зависимость $dependency для $source" >&2
                exit 1
            fi
        fi

        canonical="$(canonical_path "$resolved")"
        case "$canonical" in
            /System/Library/*|/usr/lib/*) continue ;;
        esac

        destination="$FRAMEWORKS_DIR/$basename_only"
        if [[ -z "$mapped_source" ]]; then
            cp -L "$canonical" "$destination"
            chmod u+w "$destination"
            printf '%s|%s\n' "$basename_only" "$canonical" >>"$BUNDLED_MAP"
            copy_formula_notices "$canonical"
            run_install_name_tool -id "@rpath/$basename_only" "$destination"
            # Record the mapping before recursion so cyclic dylib graphs end.
            bundle_dependencies "$destination" "$canonical" "$executable_directory"
        fi

        new_reference="$(relative_reference_for "$target" "$basename_only")"
        run_install_name_tool -change "$dependency" "$new_reference" "$target"
    done < <(dependencies_for_binary "$source")

    strip_homebrew_rpaths "$target"
}

bundle_dependencies "$SESSION_BIN" "$SDL_FREERDP" "$SESSION_BIN_DIR"
bundle_dependencies "$INTERPOSER" "$INTERPOSER" "$SESSION_BIN_DIR"
bundle_dependencies "$FN_SHORTCUT" "$FN_SHORTCUT" "$SESSION_BIN_DIR"
bundle_dependencies "$PRIVACY_PREFLIGHT" "$PRIVACY_PREFLIGHT" "$SESSION_BIN_DIR"
bundle_dependencies "$CAMERA_ADDIN" "$CAMERA_ADDIN" "$SESSION_BIN_DIR"

# OpenSSL 3 keeps MD4 in its loadable legacy provider. FreeRDP needs MD4 for
# NTLM/CredSSP authentication, but a copied libcrypto still points at the
# builder's Homebrew MODULESDIR unless the provider is bundled explicitly.
# Keep the provider next to the portable libraries and rewrite its own
# dependencies through the same relocation pass.
mkdir -p "$OPENSSL_MODULES_DIR"
cp -L "$OPENSSL_LEGACY_SOURCE" "$OPENSSL_LEGACY_MODULE"
chmod u+w "$OPENSSL_LEGACY_MODULE"
copy_formula_notices "$OPENSSL_LEGACY_SOURCE"
bundle_dependencies \
    "$OPENSSL_LEGACY_MODULE" \
    "$OPENSSL_LEGACY_SOURCE" \
    "$SESSION_BIN_DIR"

BUNDLED_FREERDP_LIB="$(/usr/bin/find "$FRAMEWORKS_DIR" -maxdepth 1 -type f \
    -name 'libfreerdp3*.dylib' -print | /usr/bin/head -n 1)"
if [[ -z "$BUNDLED_FREERDP_LIB" ]]; then
    echo "Ошибка: после упаковки не найдена libfreerdp3 в $FRAMEWORKS_DIR" >&2
    exit 1
fi

# Homebrew embeds its installation prefix into libfreerdp. Dynamic channel
# loading therefore points at the builder's Cellar path even after all Mach-O
# dependencies have been made portable. Replace that compile-time prefix with
# "." without changing binary size; with the helper working directory set to
# Contents/Frameworks, the loader resolves its regular lib/freerdp3 directory.
if [[ -n "$FREERDP_DYNAMIC_ADDIN_PATH" \
      && -n "$FREERDP_COMPILED_PREFIX" \
      && "$FREERDP_COMPILED_PREFIX" != "." ]]; then
    xcrun swift - "$BUNDLED_FREERDP_LIB" "$FREERDP_COMPILED_PREFIX" <<'PATCH_PREFIX_SWIFT'
import Foundation
import Darwin

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: patch-prefix BINARY OLD_PREFIX\n", stderr)
    exit(64)
}

let binary = URL(fileURLWithPath: CommandLine.arguments[1])
let old = Array(CommandLine.arguments[2].utf8)
guard old.count > 1 else {
    fputs("Compiled prefix is too short to patch safely\n", stderr)
    exit(65)
}

var bytes = Array(try Data(contentsOf: binary))
var replacements = 0
var index = 0
while index + old.count <= bytes.count {
    if bytes[index] == old[0] && bytes[index..<(index + old.count)].elementsEqual(old) {
        bytes[index] = 46
        if old.count > 1 {
            for offset in 1..<old.count { bytes[index + offset] = 0 }
        }
        replacements += 1
        index += old.count
    } else {
        index += 1
    }
}

guard replacements > 0 else {
    fputs("Compiled FreeRDP prefix was not found in bundled library\n", stderr)
    exit(66)
}
try Data(bytes).write(to: binary, options: .atomic)
print("Patched FreeRDP addin prefix in \(replacements) location(s)")
PATCH_PREFIX_SWIFT
fi

# Build a probe that loads the camera channel through FreeRDP's real dynamic
# addin API. Dependency rewriting and the compile-time-prefix patch invalidate
# the original Homebrew code signatures, so the probe is executed only after
# every nested Mach-O has received its final signature below. Running it here
# would make Apple Silicon macOS terminate dyld with SIGKILL (exit 137 / Killed: 9).
ADDIN_SMOKE_SOURCE="$ROOT/.build/SelectiveRemoteCameraAddinSmoke.cpp"
cat >"$ADDIN_SMOKE_SOURCE" <<'ADDIN_SMOKE_CPP'
#include <cstdio>
#include <freerdp/addin.h>

int main(void)
{
    const auto entry = freerdp_load_dynamic_channel_addin_entry(
        "rdpecam", nullptr, nullptr, FREERDP_ADDIN_CHANNEL_DYNAMIC);
    if (!entry)
    {
        std::fputs("Unable to load rdpecam dynamic channel addin\n", stderr);
        return 1;
    }
    std::puts("RDPECAM dynamic addin load smoke test passed");
    return 0;
}
ADDIN_SMOKE_CPP
xcrun clang++ \
    -std=c++17 \
    -O2 \
    -mmacosx-version-min=14.0 \
    -I"$FREERDP_INCLUDE" \
    -I"$WINPR_INCLUDE" \
    "$ADDIN_SMOKE_SOURCE" \
    "$BUNDLED_FREERDP_LIB" \
    -Wl,-rpath,"$FRAMEWORKS_DIR" \
    -o "$ADDIN_LOADER_SMOKE"
# Do not execute the probe yet: install_name_tool and the prefix patch above
# have intentionally invalidated the copied Homebrew signatures. It is run
# after the final nested-code signing stage.

minimum_macos_for_binary() {
    /usr/bin/otool -l "$1" 2>/dev/null \
        | /usr/bin/awk '
            $1 == "cmd" && $2 == "LC_BUILD_VERSION" { mode="build"; next }
            $1 == "cmd" && $2 == "LC_VERSION_MIN_MACOSX" { mode="legacy"; next }
            mode == "build" && $1 == "minos" { print $2; mode=""; next }
            mode == "legacy" && $1 == "version" { print $2; mode=""; next }
        '
}

MINIMUM_MACOS_VALUES="$ROOT/.build/bundled-minimum-macos.txt"
printf '14.0\n' >"$MINIMUM_MACOS_VALUES"
minimum_macos_for_binary "$BIN_DIR/$EXECUTABLE_NAME" >>"$MINIMUM_MACOS_VALUES"
minimum_macos_for_binary "$SESSION_BIN" >>"$MINIMUM_MACOS_VALUES"
minimum_macos_for_binary "$SSH_ASKPASS_HELPER" >>"$MINIMUM_MACOS_VALUES"
while IFS= read -r framework_binary; do
    minimum_macos_for_binary "$framework_binary" >>"$MINIMUM_MACOS_VALUES"
done < <(/usr/bin/find "$FRAMEWORKS_DIR" -type f -print | /usr/bin/sort)

BUNDLE_MINIMUM_MACOS="$(/usr/bin/awk -F. '
    {
        major=$1+0; minor=$2+0; patch=$3+0
        if (major > maxMajor ||
            (major == maxMajor && minor > maxMinor) ||
            (major == maxMajor && minor == maxMinor && patch > maxPatch)) {
            maxMajor=major; maxMinor=minor; maxPatch=patch
        }
    }
    END {
        if (maxPatch > 0) printf "%d.%d.%d", maxMajor, maxMinor, maxPatch
        else printf "%d.%d", maxMajor, maxMinor
    }
' "$MINIMUM_MACOS_VALUES")"

/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $BUNDLE_MINIMUM_MACOS" "$SESSION_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $BUNDLE_MINIMUM_MACOS" "$APP/Contents/Info.plist"
/usr/bin/plutil -replace version -string "$VERSION" "$RES_DIR/updates.example.json"
/usr/bin/plutil -replace build -integer "$BUILD_NUMBER" "$RES_DIR/updates.example.json"
/usr/bin/plutil -replace minimumMacOS -string "$BUNDLE_MINIMUM_MACOS" "$RES_DIR/updates.example.json"
/usr/bin/plutil -replace downloadURL -string \
    "https://github.com/PastFly/Selective-Remote/releases/download/v$VERSION/$ARTIFACT_NAME-$VERSION-$BUILD_ARCH.dmg" \
    "$RES_DIR/updates.example.json"
echo "Минимальная macOS готового пакета: $BUNDLE_MINIMUM_MACOS"

copy_ca_bundle() {
    local ca_prefix
    local candidate
    ca_prefix="$(brew --prefix ca-certificates 2>/dev/null || true)"
    if [[ -n "$ca_prefix" && -d "$ca_prefix" ]]; then
        copy_formula_notices "$ca_prefix"
    fi
    for candidate in \
        "$ca_prefix/share/ca-certificates/cacert.pem" \
        "$ca_prefix/etc/ca-certificates/cert.pem" \
        "$HOMEBREW_PREFIX/etc/ca-certificates/cert.pem" \
        "/etc/ssl/cert.pem"; do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            cp -L "$candidate" "$RES_DIR/cacert.pem"
            copy_formula_notices "$candidate"
            return 0
        fi
    done
    echo "Предупреждение: CA bundle не найден; TLS будет использовать системные настройки библиотеки" >&2
}
copy_ca_bundle

verify_portable_binary() {
    local target="$1"
    local metadata
    metadata="$(/usr/bin/otool -L "$target" 2>/dev/null; /usr/bin/otool -l "$target" 2>/dev/null)"
    if printf '%s\n' "$metadata" | grep -F "$HOMEBREW_PREFIX/" >/dev/null 2>&1 \
       || printf '%s\n' "$metadata" | grep -Eq '/opt/homebrew/|/usr/local/(Cellar|opt)/|/Cellar/' >/dev/null 2>&1; then
        echo "Ошибка: в пакете осталась внешняя Homebrew-ссылка: $target" >&2
        printf '%s\n' "$metadata" \
            | grep -E "$HOMEBREW_PREFIX|/opt/homebrew/|/usr/local/(Cellar|opt)/|/Cellar/" >&2 \
            || true
        exit 1
    fi
}

verify_portable_binary "$SESSION_BIN"
verify_portable_binary "$INTERPOSER"
verify_portable_binary "$FN_SHORTCUT"
verify_portable_binary "$PRIVACY_PREFLIGHT"
verify_portable_binary "$BIN_DIR/$EXECUTABLE_NAME"
verify_portable_binary "$SSH_ASKPASS_HELPER"
if [[ ! -f "$OPENSSL_LEGACY_MODULE" ]]; then
    echo "Ошибка: portable-пакет не содержит OpenSSL legacy provider" >&2
    exit 1
fi
while IFS= read -r framework_binary; do
    verify_portable_binary "$framework_binary"
done < <(/usr/bin/find "$FRAMEWORKS_DIR" -type f -print | /usr/bin/sort)

# Dependency rewriting invalidates previous signatures. Sign every nested
# Mach-O first, then the helper bundle, and finally the containing app.
while IFS= read -r framework_binary; do
    sign_code "$framework_binary"
done < <(/usr/bin/find "$FRAMEWORKS_DIR" -type f -print | /usr/bin/sort)
sign_code "$SESSION_APP" --entitlements "$SESSION_ENTITLEMENTS"
sign_code "$SSH_ASKPASS_HELPER"
sign_code "$APP" --entitlements "$APP_ENTITLEMENTS"
codesign --verify --deep --strict --verbose=2 "$APP"

verify_signed_entitlement() {
    local bundle="$1"
    local key="$2"
    local bundle_name="$3"
    local extracted="$ROOT/.build/signed-entitlements.plist"

    if ! codesign -d --entitlements :- "$bundle" >"$extracted" 2>/dev/null \
       || ! /usr/libexec/PlistBuddy -c "Print :$key" "$extracted" 2>/dev/null \
            | grep -qx 'true'; then
        echo "Ошибка: подпись $bundle_name не содержит entitlement $key" >&2
        rm -f "$extracted"
        exit 1
    fi
    rm -f "$extracted"
}

verify_signed_entitlement \
    "$SESSION_APP" \
    "com.apple.security.device.audio-input" \
    "Selective Remote Session"
verify_signed_entitlement \
    "$SESSION_APP" \
    "com.apple.security.device.camera" \
    "Selective Remote Session"
verify_signed_entitlement \
    "$APP" \
    "com.apple.security.device.audio-input" \
    "$APP_NAME"
verify_signed_entitlement \
    "$APP" \
    "com.apple.security.device.camera" \
    "$APP_NAME"

# The standalone loader lives outside the app and therefore is not covered by
# signing the bundle. Give it a temporary ad-hoc signature, then load the now
# correctly signed bundled libfreerdp and RDPECAM module from Frameworks.
# This order is required on Apple Silicon: a modified Mach-O with a stale code
# signature is rejected by dyld with SIGKILL before main() can report an error.
codesign --force --sign - "$ADDIN_LOADER_SMOKE"
codesign --verify --strict --verbose=2 "$BUNDLED_FREERDP_LIB"
codesign --verify --strict --verbose=2 "$CAMERA_ADDIN"
codesign --verify --strict --verbose=2 "$PRIVACY_PREFLIGHT"
codesign --verify --strict --verbose=2 "$FN_SHORTCUT"
(
    cd "$FRAMEWORKS_DIR"
    DYLD_LIBRARY_PATH="$FRAMEWORKS_DIR" "$ADDIN_LOADER_SMOKE"
)

# Final smoke test uses only files inside the application bundle. It proves
# that a recipient does not need Homebrew for monitor discovery and loading.
PORTABLE_SMOKE_LOG="$ROOT/.build/SelectiveRemotePortableLaunchSmoke.log"
run_monitor_smoke \
    "$SESSION_BIN" \
    "$PRIVACY_PREFLIGHT:$FN_SHORTCUT:$INTERPOSER" \
    "$PORTABLE_SMOKE_LOG" \
    "$FRAMEWORKS_DIR" \
    "$RES_DIR/cacert.pem" \
    "$OPENSSL_MODULES_DIR"
if grep -Eqi 'LEGACY provider failed|no md4 support|md4: NTLM support not available' \
        "$PORTABLE_SMOKE_LOG"; then
    echo "Ошибка: portable OpenSSL не загрузил legacy provider; NTLM/CredSSP работать не будет" >&2
    echo "Журнал: $PORTABLE_SMOKE_LOG" >&2
    exit 1
fi
echo "Portable SDL-FreeRDP launch smoke test passed"

# Build a conventional macOS drag-and-drop image. Finder stores the icon
# positions, window geometry, and background in .DS_Store inside the image.
generate_dmg_background() {
    local output="$1"
    xcrun swift - "$output" <<'SWIFT'
import AppKit
import Darwin

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: background.swift OUTPUT\n", stderr)
    exit(64)
}

let canvas = NSSize(width: 680, height: 420)
let image = NSImage(size: canvas)
image.lockFocus()

NSColor(deviceRed: 0.955, green: 0.958, blue: 0.965, alpha: 1).setFill()
NSRect(origin: .zero, size: canvas).fill()

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 287, y: 226))
arrow.line(to: NSPoint(x: 338, y: 226))
arrow.line(to: NSPoint(x: 338, y: 252))
arrow.line(to: NSPoint(x: 393, y: 210))
arrow.line(to: NSPoint(x: 338, y: 168))
arrow.line(to: NSPoint(x: 338, y: 194))
arrow.line(to: NSPoint(x: 287, y: 194))
arrow.close()
arrow.lineWidth = 4
arrow.lineJoinStyle = .round
arrow.lineCapStyle = .round
arrow.setLineDash([9, 7], count: 2, phase: 0)
NSColor(deviceWhite: 0.36, alpha: 1).setStroke()
arrow.stroke()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Unable to create DMG background\n", stderr)
    exit(1)
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
SWIFT
}

ditto "$APP" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
generate_dmg_background "$DMG_BACKGROUND"

DMG_SIZE_MB="$(( $(du -sm "$DMG_STAGE" | awk '{print $1}') + 64 ))"
hdiutil create \
    -size "${DMG_SIZE_MB}m" \
    -fs HFS+ \
    -volname "$DMG_VOLUME_NAME" \
    -ov \
    "$DMG_RW" >/dev/null

attach_dmg "$DMG_RW" "-readwrite"

ditto "$DMG_STAGE" "$DMG_MOUNT"

osascript <<APPLESCRIPT
tell application "Finder"
    set dmgDisk to missing value
    repeat 20 times
        if exists disk "$DMG_FINDER_DISK_NAME" then
            set dmgDisk to disk "$DMG_FINDER_DISK_NAME"
            exit repeat
        end if
        delay 0.25
    end repeat
    if dmgDisk is missing value then
        error "Finder не увидел смонтированный том $DMG_FINDER_DISK_NAME"
    end if

    tell dmgDisk
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 780, 520}

        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 14
        set background picture of viewOptions to file ".background:installer-background.png"

        set position of item "$APP_NAME.app" of container window to {175, 210}
        set position of item "Applications" of container window to {505, 210}
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

/bin/sync
detach_dmg

hdiutil convert \
    "$DMG_RW" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG" >/dev/null
rm -f "$DMG_RW"

# Reopen the compressed image read-only and assert that the recipient sees the
# conventional two-item layout, with Finder metadata and its hidden backdrop.
attach_dmg "$DMG" "-readonly"

if [[ ! -d "$DMG_MOUNT/$APP_NAME.app" \
      || ! -L "$DMG_MOUNT/Applications" \
      || "$(readlink "$DMG_MOUNT/Applications")" != "/Applications" \
      || ! -f "$DMG_MOUNT/.DS_Store" \
      || ! -f "$DMG_MOUNT/.background/installer-background.png" ]]; then
    echo "Ошибка: готовый DMG не содержит полный Drag & Drop макет" >&2
    exit 1
fi

shopt -s nullglob
VISIBLE_DMG_ITEMS=("$DMG_MOUNT"/*)
shopt -u nullglob
if [[ "${#VISIBLE_DMG_ITEMS[@]}" -ne 2 ]]; then
    echo "Ошибка: в готовом DMG обнаружены лишние видимые объекты" >&2
    printf '%s\n' "${VISIBLE_DMG_ITEMS[@]}" >&2
    exit 1
fi

detach_dmg
echo "Drag & Drop DMG layout test passed"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    codesign --verify --verbose=2 "$DMG"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
    if [[ "$DISTRIBUTION_SIGNING" != "true" ]]; then
        echo "Ошибка: notarization требует сертификат Developer ID Application" >&2
        exit 1
    fi
    xcrun notarytool submit "$DMG" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
    echo "Notarization и stapling завершены"
fi

(
    cd "$(dirname "$DMG")"
    shasum -a 256 "$(basename "$DMG")" >"$(basename "$DMG_HASH")"
)

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "Примечание: эта сборка использует временную ad-hoc подпись."
    echo "Получателю потребуется один раз явно разрешить запуск в macOS."
elif [[ "$DISTRIBUTION_SIGNING" == "true" ]]; then
    echo "Подпись для распространения: $SIGN_IDENTITY"
else
    echo "Подпись для локальной разработки: $SIGN_IDENTITY"
    echo "Получателю всё равно потребуется явно разрешить первый запуск."
fi
echo "Homebrew, FreeRDP и SDL3 нужны только на Mac сборщика, не у получателя."
echo "Приложение: $APP"
echo "Community DMG: $DMG"
echo "SHA-256: $DMG_HASH"
