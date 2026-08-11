#import <AppKit/AppKit.h>

#include <SDL3/SDL.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <initializer_list>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unistd.h>

#include "FnTapRecognizer.hpp"

namespace
{
FnTapRecognizer fnTapRecognizer;
id localEventMonitor = nil;
id resignActiveObserver = nil;
int commandPipe = -1;
dispatch_source_t commandSource = nil;
std::unordered_map<std::string, std::string> customKeyMappings;
std::unordered_map<unsigned short, SDL_Scancode> activeSyntheticKeys;

bool enabled()
{
    const char* value = std::getenv("SELECTIVE_RDP_FN_LANGUAGE_SWITCH");
    return value && (std::strcmp(value, "1") == 0);
}

bool environmentFlag(const char* name)
{
    const char* value = std::getenv(name);
    return value && (std::strcmp(value, "1") == 0);
}

void parseCustomKeyMappings()
{
    customKeyMappings.clear();
    const char* value = std::getenv("SELECTIVE_RDP_CUSTOM_KEY_MAPPINGS");
    if (!value || !*value)
        return;

    const std::string serialized(value);
    size_t start = 0;
    while (start < serialized.size())
    {
        const size_t end = serialized.find(';', start);
        const std::string rule = serialized.substr(
            start,
            end == std::string::npos ? std::string::npos : end - start
        );
        const size_t separator = rule.find('=');
        if ((separator != std::string::npos) && separator &&
            (separator + 1 < rule.size()))
        {
            customKeyMappings.emplace(
                rule.substr(0, separator),
                rule.substr(separator + 1)
            );
        }
        if (end == std::string::npos)
            break;
        start = end + 1;
    }
}

bool keyboardMappingEnabled()
{
    const char* custom = std::getenv("SELECTIVE_RDP_CUSTOM_KEY_MAPPINGS");
    return environmentFlag("SELECTIVE_RDP_COMMAND_CONTROL") ||
        environmentFlag("SELECTIVE_RDP_RIGHT_COMMAND_WINDOWS") ||
        environmentFlag("SELECTIVE_RDP_RIGHT_COMMAND_CONTROL") ||
        environmentFlag("SELECTIVE_RDP_OPTION_WINDOWS") ||
        (custom && *custom);
}

const char* commandPipePath()
{
    return std::getenv("SELECTIVE_RDP_COMMAND_PIPE");
}

bool hasOtherModifier(NSEventModifierFlags flags)
{
    constexpr NSEventModifierFlags otherModifiers =
        NSEventModifierFlagShift |
        NSEventModifierFlagControl |
        NSEventModifierFlagOption |
        NSEventModifierFlagCommand;
    return (flags & otherModifiers) != 0;
}

bool pushKey(SDL_Scancode scancode, bool down)
{
    SDL_Event event = {};
    event.type = down ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
    event.key.type = down ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
    event.key.timestamp = SDL_GetTicksNS();
    SDL_Window* window = SDL_GetKeyboardFocus();
    event.key.windowID = window ? SDL_GetWindowID(window) : 0;
    event.key.which = 0;
    event.key.scancode = scancode;
    event.key.key = SDL_GetKeyFromScancode(scancode, SDL_KMOD_NONE, true);
    event.key.mod = SDL_KMOD_NONE;
    event.key.raw = 0;
    event.key.down = down;
    event.key.repeat = false;
    return SDL_PushEvent(&event);
}

const char* sourceNameForKeyCode(unsigned short keyCode)
{
    switch (keyCode)
    {
        case 55: return "leftCommand";
        case 54: return "rightCommand";
        case 58: return "leftOption";
        case 61: return "rightOption";
        case 57: return "capsLock";
        case 53: return "escape";
        case 59: return "leftControl";
        case 62: return "rightControl";
        default: return nullptr;
    }
}

SDL_Scancode windowsKeyScancode()
{
    // When both FreeRDP parser slots are used by physical Command and Option,
    // Right GUI remains untouched and can carry synthetic Windows commands.
    return environmentFlag("SELECTIVE_RDP_DIRECT_WINDOWS_KEY")
        ? SDL_SCANCODE_RGUI : SDL_SCANCODE_F24;
}

SDL_Scancode targetScancode(const std::string& target)
{
    // Windows uses the F24 sentinel when a parser slot is available, otherwise
    // Right GUI. All other mappings are normal SDL scancodes.
    if ((target == "leftCommand") || (target == "rightCommand") ||
        (target == "leftWindows") || (target == "rightWindows"))
        return windowsKeyScancode();
    if (target == "leftOption") return SDL_SCANCODE_LALT;
    if (target == "rightOption") return SDL_SCANCODE_RALT;
    if (target == "capsLock") return SDL_SCANCODE_CAPSLOCK;
    if (target == "escape") return SDL_SCANCODE_ESCAPE;
    if (target == "leftControl") return SDL_SCANCODE_LCTRL;
    if (target == "rightControl") return SDL_SCANCODE_RCTRL;
    return SDL_SCANCODE_UNKNOWN;
}

SDL_Scancode customScancodeForSource(const char* source)
{
    auto rule = customKeyMappings.find(source);
    if (rule == customKeyMappings.end())
    {
        // Windows and Command are aliases for the same physical macOS keys.
        if (std::strcmp(source, "leftCommand") == 0)
            rule = customKeyMappings.find("leftWindows");
        else if (std::strcmp(source, "rightCommand") == 0)
            rule = customKeyMappings.find("rightWindows");
    }
    return rule == customKeyMappings.end()
        ? SDL_SCANCODE_UNKNOWN
        : targetScancode(rule->second);
}

SDL_Scancode mappedScancodeForKeyCode(unsigned short keyCode)
{
    const char* source = sourceNameForKeyCode(keyCode);
    if (!source)
        return SDL_SCANCODE_UNKNOWN;

    const SDL_Scancode custom = customScancodeForSource(source);
    if (custom != SDL_SCANCODE_UNKNOWN)
        return custom;

    switch (keyCode)
    {
        case 55:
            return environmentFlag("SELECTIVE_RDP_COMMAND_CONTROL")
                ? SDL_SCANCODE_LCTRL : SDL_SCANCODE_UNKNOWN;
        case 54:
            if (environmentFlag("SELECTIVE_RDP_RIGHT_COMMAND_CONTROL"))
                return SDL_SCANCODE_RCTRL;
            if (environmentFlag("SELECTIVE_RDP_COMMAND_CONTROL"))
                return environmentFlag("SELECTIVE_RDP_RIGHT_COMMAND_WINDOWS")
                    ? windowsKeyScancode() : SDL_SCANCODE_RCTRL;
            return SDL_SCANCODE_UNKNOWN;
        case 58:
        case 61:
            return environmentFlag("SELECTIVE_RDP_OPTION_WINDOWS")
                ? SDL_SCANCODE_F24 : SDL_SCANCODE_UNKNOWN;
        default:
            return SDL_SCANCODE_UNKNOWN;
    }
}

void releaseSyntheticKeys()
{
    for (const auto& entry : activeSyntheticKeys)
        pushKey(entry.second, false);
    activeSyntheticKeys.clear();
}

NSEvent* translateMappedEvent(NSEvent* event)
{
    const unsigned short keyCode = event.keyCode;
    if (!sourceNameForKeyCode(keyCode))
        return event;

    if (event.type == NSEventTypeFlagsChanged)
    {
        // Caps Lock exposes its toggle state rather than a conventional
        // key-up. Represent a custom Caps mapping as one complete key tap.
        if (keyCode == 57)
        {
            const SDL_Scancode mapped = mappedScancodeForKeyCode(keyCode);
            if (mapped == SDL_SCANCODE_UNKNOWN)
                return event;
            pushKey(mapped, true);
            pushKey(mapped, false);
            return nil;
        }

        const auto active = activeSyntheticKeys.find(keyCode);
        if (active != activeSyntheticKeys.end())
        {
            pushKey(active->second, false);
            activeSyntheticKeys.erase(active);
            return nil;
        }

        const SDL_Scancode mapped = mappedScancodeForKeyCode(keyCode);
        if (mapped == SDL_SCANCODE_UNKNOWN)
            return event;
        pushKey(mapped, true);
        activeSyntheticKeys.emplace(keyCode, mapped);
        std::fprintf(
            stderr,
            "[SelectiveRemote Input] mapped macOS keyCode=%hu to SDL=%s\n",
            keyCode,
            SDL_GetScancodeName(mapped)
        );
        std::fflush(stderr);
        return nil;
    }

    if ((event.type == NSEventTypeKeyDown) || (event.type == NSEventTypeKeyUp))
    {
        const SDL_Scancode mapped = mappedScancodeForKeyCode(keyCode);
        if (mapped == SDL_SCANCODE_UNKNOWN)
            return event;
        pushKey(mapped, event.type == NSEventTypeKeyDown);
        return nil;
    }
    return event;
}

void sendWindowsLanguageShortcut()
{
    // The events stay in SDL's normal input queue and do not replace or call
    // any internal FreeRDP function.
    const SDL_Scancode windows = windowsKeyScancode();
    const bool windowsDown = pushKey(windows, true);
    const bool spaceDown = pushKey(SDL_SCANCODE_SPACE, true);
    const bool spaceUp = pushKey(SDL_SCANCODE_SPACE, false);
    const bool windowsUp = pushKey(windows, false);
    const bool sent = windowsDown && spaceDown && spaceUp && windowsUp;
    if (!sent)
    {
        std::fprintf(
            stderr,
            "[SelectiveRemote Input] Fn shortcut could not be queued: %s\n",
            SDL_GetError()
        );
        std::fflush(stderr);
        return;
    }
    std::fputs("[SelectiveRemote Input] Fn sent Win+Space\n", stderr);
    std::fflush(stderr);
}

void sendKeyTap(SDL_Scancode key)
{
    pushKey(key, true);
    pushKey(key, false);
}

void sendChord(std::initializer_list<SDL_Scancode> modifiers, SDL_Scancode key)
{
    for (const auto modifier : modifiers)
        pushKey(modifier, true);
    sendKeyTap(key);
    for (auto iterator = modifiers.end(); iterator != modifiers.begin();)
    {
        --iterator;
        pushKey(*iterator, false);
    }
}

void executeCommand(const std::string& command)
{
    if (command == "windows")
        sendKeyTap(windowsKeyScancode());
    else if (command == "language")
        sendWindowsLanguageShortcut();
    else if (command == "ctrl-alt-delete")
        sendChord({ SDL_SCANCODE_LCTRL, SDL_SCANCODE_LALT }, SDL_SCANCODE_DELETE);
    else if (command == "alt-tab")
        sendChord({ SDL_SCANCODE_LALT }, SDL_SCANCODE_TAB);
    else if (command == "print-screen")
        sendKeyTap(SDL_SCANCODE_PRINTSCREEN);
    else if (command == "fullscreen")
        sendChord({ SDL_SCANCODE_RSHIFT }, SDL_SCANCODE_RETURN);
    else if (command == "disconnect")
        sendChord({ SDL_SCANCODE_RSHIFT }, SDL_SCANCODE_D);
    else
        return;
    std::fprintf(stderr, "[SelectiveRemote Input] command: %s\n", command.c_str());
    std::fflush(stderr);
}

void installCommandPipe()
{
    const char* path = commandPipePath();
    if (!path || !*path)
        return;
    commandPipe = open(path, O_RDWR | O_NONBLOCK);
    if (commandPipe < 0)
    {
        std::perror("[SelectiveRemote Input] open command pipe");
        return;
    }
    commandSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ,
        static_cast<uintptr_t>(commandPipe),
        0,
        dispatch_get_main_queue()
    );
    dispatch_source_set_event_handler(commandSource, ^{
        char buffer[1024];
        const ssize_t count = read(commandPipe, buffer, sizeof(buffer));
        if (count <= 0)
            return;
        std::string commands(buffer, static_cast<size_t>(count));
        size_t start = 0;
        while (start < commands.size())
        {
            const size_t end = commands.find('\n', start);
            const std::string command = commands.substr(
                start,
                end == std::string::npos ? std::string::npos : end - start
            );
            if (!command.empty())
                executeCommand(command);
            if (end == std::string::npos)
                break;
            start = end + 1;
        }
    });
    dispatch_source_set_cancel_handler(commandSource, ^{
        if (commandPipe >= 0)
        {
            close(commandPipe);
            commandPipe = -1;
        }
    });
    dispatch_resume(commandSource);
}

NSEvent* observeEvent(NSEvent* event)
{
    if ((event.type == NSEventTypeFlagsChanged) && (event.keyCode == 63))
    {
        const bool pressed =
            (event.modifierFlags & NSEventModifierFlagFunction) != 0;
        fnTapRecognizer.fnChanged(
            pressed,
            pressed && hasOtherModifier(event.modifierFlags)
        );
        if (fnTapRecognizer.takeTap())
            sendWindowsLanguageShortcut();

        // Fn itself has no useful RDP scancode. Consuming its flagsChanged
        // event also prevents a single tap from invoking a local macOS Fn
        // action while the RDP window is active. Fn combined with another key
        // still reaches that key's normal AppKit/SDL path.
        return nil;
    }

    if ((event.type == NSEventTypeKeyDown) ||
        (event.type == NSEventTypeKeyUp) ||
        (event.type == NSEventTypeFlagsChanged))
    {
        fnTapRecognizer.otherKeyChanged();
        return translateMappedEvent(event);
    }
    return event;
}

void installEventMonitor()
{
    static std::once_flag once;
    std::call_once(once, [] {
        parseCustomKeyMappings();
        const NSEventMask mask =
            NSEventMaskFlagsChanged | NSEventMaskKeyDown | NSEventMaskKeyUp;
        if (enabled() || keyboardMappingEnabled())
        {
            localEventMonitor = [NSEvent
                addLocalMonitorForEventsMatchingMask:mask
                handler:^NSEvent* (NSEvent* event) {
                    return observeEvent(event);
                }];
            resignActiveObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:NSApplicationDidResignActiveNotification
                object:nil
                queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification* notification) {
                    fnTapRecognizer.cancel();
                    releaseSyntheticKeys();
                }];
            std::fputs(
                "[SelectiveRemote Input] keyboard mappings enabled through SDL queue\n",
                stderr
            );
        }
        installCommandPipe();
        std::fflush(stderr);
    });
}
}

__attribute__((constructor)) static void selective_install_fn_language_shortcut()
{
    if (!enabled() && !keyboardMappingEnabled() && !commandPipePath())
        return;

    // Do not initialize AppKit or SDL under dyld's constructor lock. The main
    // queue runs after SDL-FreeRDP has entered its normal application loop.
    dispatch_async(dispatch_get_main_queue(), ^{
        installEventMonitor();
    });
}
