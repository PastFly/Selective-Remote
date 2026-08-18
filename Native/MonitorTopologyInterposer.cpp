#include <freerdp/settings.h>

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#if !defined(SELECTIVE_RDP_TESTING)
#include <CoreGraphics/CoreGraphics.h>
#include <SDL3/SDL.h>
#include <mutex>
#endif

namespace
{
#if !defined(SELECTIVE_RDP_TESTING)
Uint32 SDLCALL restoreQuitEvents(
    void*,
    SDL_TimerID,
    Uint32
)
{
    // Discard any delayed close event created by the temporary monitor
    // probing windows before returning normal quit handling to SDL-FreeRDP.
    SDL_FlushEvent(SDL_EVENT_QUIT);
    SDL_SetEventEnabled(SDL_EVENT_QUIT, true);
    std::fputs("[SelectiveRemote] Restored SDL quit events after startup\n", stderr);
    return 0;
}

void suppressStartupQuitEvents()
{
    static std::once_flag once;
    std::call_once(once, [] {
        SDL_SetEventEnabled(SDL_EVENT_QUIT, false);
        SDL_FlushEvent(SDL_EVENT_QUIT);
        std::fputs("[SelectiveRemote] Suppressing stale SDL quit events during startup\n", stderr);

        constexpr Uint32 suppressionMilliseconds = 5000;
        if (SDL_AddTimer(suppressionMilliseconds, restoreQuitEvents, nullptr) == 0)
        {
            std::fprintf(
                stderr,
                "[SelectiveRemote] Failed to arm SDL quit restore timer: %s\n",
                SDL_GetError()
            );
        }
    });
}

bool staleDisplayEventGuardEnabled()
{
    const char* raw = std::getenv("SELECTIVE_RDP_STALE_DISPLAY_EVENT_GUARD");
    return raw && (std::strcmp(raw, "1") == 0);
}

bool currentSDLDisplayID(SDL_DisplayID displayID)
{
    int count = 0;
    SDL_DisplayID* displays = SDL_GetDisplays(&count);
    if (!displays)
        return true;

    bool found = false;
    for (int index = 0; index < count; ++index)
    {
        if (displays[index] == displayID)
        {
            found = true;
            break;
        }
    }
    SDL_free(displays);
    return found;
}

bool staleDisplayPropertyEvent(const SDL_Event& event)
{
    if (!staleDisplayEventGuardEnabled())
        return false;

    switch (event.type)
    {
        case SDL_EVENT_DISPLAY_ORIENTATION:
        case SDL_EVENT_DISPLAY_MOVED:
        case SDL_EVENT_DISPLAY_DESKTOP_MODE_CHANGED:
        case SDL_EVENT_DISPLAY_CURRENT_MODE_CHANGED:
        case SDL_EVENT_DISPLAY_CONTENT_SCALE_CHANGED:
        case SDL_EVENT_DISPLAY_USABLE_BOUNDS_CHANGED:
            return !currentSDLDisplayID(event.display.displayID);
        default:
            return false;
    }
}
#endif

struct TargetPlacement
{
    INT32 x;
    INT32 y;
    BOOL primary;
};

bool parseSigned(const std::string& value, INT32& result)
{
    if (value.empty())
        return false;

    errno = 0;
    char* end = nullptr;
    const long long parsed = std::strtoll(value.c_str(), &end, 10);
    if ((errno != 0) || !end || (*end != '\0'))
        return false;
    if ((parsed < std::numeric_limits<INT32>::min()) ||
        (parsed > std::numeric_limits<INT32>::max()))
        return false;

    result = static_cast<INT32>(parsed);
    return true;
}

bool parseUnsigned(const std::string& value, UINT32& result)
{
    if (value.empty() || (value.front() == '-'))
        return false;

    errno = 0;
    char* end = nullptr;
    const unsigned long long parsed = std::strtoull(value.c_str(), &end, 10);
    if ((errno != 0) || !end || (*end != '\0') ||
        (parsed > std::numeric_limits<UINT32>::max()))
        return false;

    result = static_cast<UINT32>(parsed);
    return true;
}

#if !defined(SELECTIVE_RDP_TESTING)
struct AppLocalDisplayPlacement
{
    CGDirectDisplayID displayID;
    INT32 x;
    INT32 y;
};

bool parseAppLocalDisplayLayout(
    const char* raw,
    std::vector<AppLocalDisplayPlacement>& result
)
{
    if (!raw || (*raw == '\0'))
        return false;

    std::stringstream entries(raw);
    std::string entry;
    while (std::getline(entries, entry, ';'))
    {
        std::stringstream fields(entry);
        std::vector<std::string> values;
        std::string value;
        while (std::getline(fields, value, ':'))
            values.emplace_back(value);

        if (values.size() != 3)
            return false;

        UINT32 displayID = 0;
        INT32 x = 0;
        INT32 y = 0;
        if (!parseUnsigned(values[0], displayID) ||
            !parseSigned(values[1], x) ||
            !parseSigned(values[2], y))
            return false;

        result.push_back(
            AppLocalDisplayPlacement{
                static_cast<CGDirectDisplayID>(displayID),
                x,
                y
            }
        );
    }
    return result.size() > 1;
}

void applyAppScopedLocalDisplayLayoutOnce()
{
    static std::once_flag once;
    std::call_once(once, [] {
        const char* raw =
            std::getenv("SELECTIVE_RDP_APP_LOCAL_DISPLAY_LAYOUT");
        std::vector<AppLocalDisplayPlacement> placements;
        if (!parseAppLocalDisplayLayout(raw, placements))
            return;

        CGDisplayConfigRef config = nullptr;
        const CGError begin = CGBeginDisplayConfiguration(&config);
        if ((begin != kCGErrorSuccess) || !config)
        {
            std::fprintf(
                stderr,
                "[SelectiveRemote] Could not begin app-scoped display "
                "configuration: %d\n",
                static_cast<int>(begin)
            );
            return;
        }

        for (const auto& placement : placements)
        {
            const CGError rc = CGConfigureDisplayOrigin(
                config,
                placement.displayID,
                placement.x,
                placement.y
            );
            if (rc != kCGErrorSuccess)
            {
                CGCancelDisplayConfiguration(config);
                std::fprintf(
                    stderr,
                    "[SelectiveRemote] Could not configure local display %u "
                    "at %d,%d: %d\n",
                    static_cast<unsigned int>(placement.displayID),
                    placement.x,
                    placement.y,
                    static_cast<int>(rc)
                );
                return;
            }
        }

        const CGError complete = CGCompleteDisplayConfiguration(
            config,
            kCGConfigureForAppOnly
        );
        if (complete != kCGErrorSuccess)
        {
            std::fprintf(
                stderr,
                "[SelectiveRemote] Could not apply app-scoped local display "
                "order: %d\n",
                static_cast<int>(complete)
            );
            return;
        }

        std::fprintf(
            stderr,
            "[SelectiveRemote] Applied app-scoped local display order to "
            "%zu displays\n",
            placements.size()
        );
    });
}
#endif

bool parseLayout(const char* raw, std::unordered_map<UINT32, TargetPlacement>& result)
{
    if (!raw || (*raw == '\0'))
        return false;

    std::stringstream entries(raw);
    std::string entry;
    while (std::getline(entries, entry, ';'))
    {
        std::stringstream fields(entry);
        std::vector<std::string> values;
        std::string value;
        while (std::getline(fields, value, ':'))
            values.emplace_back(value);

        if (values.size() != 4)
            return false;

        UINT32 id = 0;
        INT32 x = 0;
        INT32 y = 0;
        INT32 primary = 0;
        if (!parseUnsigned(values[0], id) || !parseSigned(values[1], x) ||
            !parseSigned(values[2], y) || !parseSigned(values[3], primary) ||
            ((primary != 0) && (primary != 1)))
            return false;

        const auto inserted = result.emplace(
            id,
            TargetPlacement{ x, y, primary == 1 ? TRUE : FALSE }
        );
        if (!inserted.second)
            return false;
    }
    return !result.empty();
}

bool displayIDListed(const char* raw, UINT32 displayID)
{
    if (!raw || (*raw == '\0'))
        return false;

    std::stringstream stream(raw);
    std::string value;
    while (std::getline(stream, value, ','))
    {
        UINT32 parsed = 0;
        if (parseUnsigned(value, parsed) && (parsed == displayID))
            return true;
    }
    return false;
}

bool monitorComesBefore(const rdpMonitor& lhs, const rdpMonitor& rhs)
{
    if (lhs.is_primary != rhs.is_primary)
        return lhs.is_primary != FALSE;
    if (lhs.x != rhs.x)
        return lhs.x < rhs.x;
    return lhs.y < rhs.y;
}

BOOL storeMonitorDefinitions(
    rdpSettings* settings,
    const rdpMonitor* monitors,
    size_t count
)
{
    if (!settings || (!monitors && (count > 0)) ||
        (count > std::numeric_limits<UINT32>::max()))
        return FALSE;

    if (count == 0)
    {
        if (!freerdp_settings_set_int32(settings, FreeRDP_MonitorLocalShiftX, 0) ||
            !freerdp_settings_set_int32(settings, FreeRDP_MonitorLocalShiftY, 0) ||
            !freerdp_settings_set_pointer_len(
                settings,
                FreeRDP_MonitorDefArray,
                nullptr,
                0
            ))
            return FALSE;
        return freerdp_settings_set_uint32(settings, FreeRDP_MonitorCount, 0);
    }

    const rdpMonitor* primary = nullptr;
    for (size_t index = 0; index < count; ++index)
    {
        if (monitors[index].is_primary)
        {
            primary = &monitors[index];
            break;
        }
    }
    if (!primary)
    {
        for (size_t index = 0; index < count; ++index)
        {
            if ((monitors[index].x == 0) && (monitors[index].y == 0))
            {
                primary = &monitors[index];
                break;
            }
        }
    }
    if (!primary)
    {
        std::fputs("[SelectiveRemote] Monitor topology has no primary display\n", stderr);
        return FALSE;
    }

    const INT32 offsetX = primary->x;
    const INT32 offsetY = primary->y;
    std::vector<rdpMonitor> sorted;
    sorted.reserve(count);

    rdpMonitor normalizedPrimary = *primary;
    normalizedPrimary.x = 0;
    normalizedPrimary.y = 0;
    normalizedPrimary.is_primary = TRUE;
    sorted.emplace_back(normalizedPrimary);

    for (size_t index = 0; index < count; ++index)
    {
        const rdpMonitor* current = &monitors[index];
        if (current == primary)
            continue;

        rdpMonitor normalized = *current;
        normalized.x -= offsetX;
        normalized.y -= offsetY;
        sorted.emplace_back(normalized);
    }
    std::sort(sorted.begin(), sorted.end(), monitorComesBefore);

    if (!freerdp_settings_set_pointer_len(
            settings,
            FreeRDP_MonitorDefArray,
            nullptr,
            count
        ))
        return FALSE;
    auto* destination = static_cast<rdpMonitor*>(
        freerdp_settings_get_pointer_writable(settings, FreeRDP_MonitorDefArray)
    );
    if (!destination)
        return FALSE;

    std::copy(sorted.begin(), sorted.end(), destination);
    if (!freerdp_settings_set_int32(
            settings,
            FreeRDP_MonitorLocalShiftX,
            offsetX
        ) ||
        !freerdp_settings_set_int32(
            settings,
            FreeRDP_MonitorLocalShiftY,
            offsetY
        ))
        return FALSE;

    return freerdp_settings_set_uint32(
        settings,
        FreeRDP_MonitorCount,
        static_cast<UINT32>(count)
    );
}
}

extern "C" bool selective_rdp_is_probe_window_title(const char* title)
{
    constexpr const char* prefix = "SdlWindow::query(";
    if (!title || (std::strncmp(title, prefix, std::strlen(prefix)) != 0))
        return false;

    const char* value = title + std::strlen(prefix);
    if (*value == '\0')
        return false;

    errno = 0;
    char* end = nullptr;
    const unsigned long parsed = std::strtoul(value, &end, 10);
    return (errno == 0) && end && (end != value) && (*end == ')') &&
        (end[1] == '\0') && (parsed <= std::numeric_limits<UINT32>::max());
}

extern "C" bool selective_rdp_probe_display_id(
    const char* title,
    UINT32* displayID
)
{
    if (!displayID || !selective_rdp_is_probe_window_title(title))
        return false;

    constexpr const char* prefix = "SdlWindow::query(";
    const unsigned long parsed = std::strtoul(
        title + std::strlen(prefix),
        nullptr,
        10
    );
    *displayID = static_cast<UINT32>(parsed);
    return true;
}

extern "C" BOOL selective_freerdp_set_monitor_def_array_sorted(
    rdpSettings* settings,
    const rdpMonitor* monitors,
    size_t count
)
{
#if !defined(SELECTIVE_RDP_TESTING)
    suppressStartupQuitEvents();
#endif

    const char* raw = std::getenv("SELECTIVE_RDP_MONITOR_LAYOUT");
    if (!raw || (count < 2) || !monitors)
        return storeMonitorDefinitions(settings, monitors, count);

    std::unordered_map<UINT32, TargetPlacement> targets;
    if (!parseLayout(raw, targets) || (targets.size() != count))
    {
        std::fputs("[SelectiveRemote] Invalid selected monitor layout; using native coordinates\n", stderr);
        return storeMonitorDefinitions(settings, monitors, count);
    }

    std::vector<rdpMonitor> adjusted(monitors, monitors + count);
    for (auto& monitor : adjusted)
    {
        const auto target = targets.find(monitor.orig_screen);
        if (target == targets.end())
        {
            std::fputs("[SelectiveRemote] SDL monitor ID mismatch; using native coordinates\n", stderr);
            return storeMonitorDefinitions(settings, monitors, count);
        }
        monitor.x = target->second.x;
        monitor.y = target->second.y;
        monitor.is_primary = target->second.primary;
    }

#if !defined(SELECTIVE_RDP_TESTING)
    applyAppScopedLocalDisplayLayoutOnce();
#endif

    std::fprintf(stderr, "[SelectiveRemote] Applied selected topology to %zu monitors\n", count);
    return storeMonitorDefinitions(settings, adjusted.data(), adjusted.size());
}

#if !defined(SELECTIVE_RDP_TESTING)
extern "C" SDL_Window* SDLCALL selective_SDL_CreateWindowWithProperties(
    SDL_PropertiesID properties
)
{
    const char* title = SDL_GetStringProperty(
        properties,
        SDL_PROP_WINDOW_CREATE_TITLE_STRING,
        ""
    );
    const bool isProbe = selective_rdp_is_probe_window_title(title);

    const char* forceLogicalFullscreen =
        std::getenv("SELECTIVE_RDP_FORCE_LOGICAL_FULLSCREEN");

    const bool requestedFullscreen = SDL_GetBooleanProperty(
        properties,
        SDL_PROP_WINDOW_CREATE_FULLSCREEN_BOOLEAN,
        false
    );
    const bool requestedBorderless = SDL_GetBooleanProperty(
        properties,
        SDL_PROP_WINDOW_CREATE_BORDERLESS_BOOLEAN,
        false
    );
    const bool shouldForceLogicalFullscreen =
        !isProbe &&
        forceLogicalFullscreen &&
        (std::strcmp(forceLogicalFullscreen, "1") == 0) &&
        (requestedFullscreen || requestedBorderless);

    if (shouldForceLogicalFullscreen)
    {
        // FreeRDP multimon windows are BORDERLESS rather than SDL fullscreen.
        // Keep real fullscreen RDP windows at 1x so the renderer target uses
        // the same coordinate system as the logical monitor definitions.
        SDL_SetBooleanProperty(
            properties,
            SDL_PROP_WINDOW_CREATE_HIGH_PIXEL_DENSITY_BOOLEAN,
            false
        );
        std::fprintf(
            stderr,
            "[SelectiveRemote] Logical RDP backing requested: "
            "fullscreen=%d borderless=%d high-pixel-density=off\n",
            requestedFullscreen ? 1 : 0,
            requestedBorderless ? 1 : 0
        );
    }

    if (isProbe)
    {
        // FreeRDP explicitly creates these as visible, then takes every screen
        // fullscreen just to measure its backing pixel size. With the built-in
        // direct-bounds fallback enabled, a hidden 64x64 probe is sufficient.
        SDL_SetBooleanProperty(
            properties,
            SDL_PROP_WINDOW_CREATE_HIDDEN_BOOLEAN,
            true
        );
    }

    SDL_Window* window = SDL_CreateWindowWithProperties(properties);

    if (window && shouldForceLogicalFullscreen)
    {
        int logicalWidth = 0;
        int logicalHeight = 0;
        int pixelWidth = 0;
        int pixelHeight = 0;
        const bool logicalOK = SDL_GetWindowSize(
            window,
            &logicalWidth,
            &logicalHeight
        );
        const bool pixelOK = SDL_GetWindowSizeInPixels(
            window,
            &pixelWidth,
            &pixelHeight
        );
        if (logicalOK && pixelOK)
        {
            std::fprintf(
                stderr,
                "[SelectiveRemote] Logical RDP backing active: "
                "window=%dx%d pixels=%dx%d\n",
                logicalWidth,
                logicalHeight,
                pixelWidth,
                pixelHeight
            );
        }
    }

    return window;
}

extern "C" bool SDLCALL selective_SDL_SetWindowFullscreen(
    SDL_Window* window,
    bool fullscreen
)
{
    const char* title = window ? SDL_GetWindowTitle(window) : nullptr;
    if (fullscreen && selective_rdp_is_probe_window_title(title))
    {
        static std::once_flag once;
        std::call_once(once, [] {
            std::fputs(
                "[SelectiveRemote] Hidden SDL monitor probes use direct display bounds\n",
                stderr
            );
        });
        return true;
    }
    return SDL_SetWindowFullscreen(window, fullscreen);
}

bool selective_probe_window_size(
    SDL_Window* window,
    int* width,
    int* height
)
{
    const char* title = window ? SDL_GetWindowTitle(window) : nullptr;
    UINT32 rawDisplayID = 0;
    if (!selective_rdp_probe_display_id(title, &rawDisplayID))
        return false;

    SDL_Rect bounds = {};
    const SDL_DisplayID displayID = static_cast<SDL_DisplayID>(rawDisplayID);
    if (!SDL_GetDisplayBounds(displayID, &bounds))
    {
        std::fprintf(
            stderr,
            "[SelectiveRemote] Could not read display bounds for SDL display %u: %s\n",
            rawDisplayID,
            SDL_GetError()
        );
        return false;
    }

    const char* safeIDs = std::getenv("SELECTIVE_RDP_FULLSCREEN_SAFE_TOP_IDS");
    const bool reserveSafeTop = displayIDListed(safeIDs, rawDisplayID);
    if (reserveSafeTop)
    {
        SDL_Rect usable = {};
        if (SDL_GetDisplayUsableBounds(displayID, &usable))
        {
            const int topInset = std::max(0, usable.y - bounds.y);
            if ((topInset > 0) && (topInset < bounds.h))
            {
                bounds.y += topInset;
                bounds.h -= topInset;
            }
        }
    }

    if (width)
        *width = bounds.w;
    if (height)
        *height = bounds.h;

    std::fprintf(
        stderr,
        "[SelectiveRemote] Probe display %u uses %s bounds %dx%d at %d,%d\n",
        rawDisplayID,
        reserveSafeTop ? "fullscreen-safe" : "logical",
        bounds.w,
        bounds.h,
        bounds.x,
        bounds.y
    );
    return true;
}

extern "C" bool SDLCALL selective_SDL_GetWindowSize(
    SDL_Window* window,
    int* width,
    int* height
)
{
    if (selective_probe_window_size(window, width, height))
        return true;
    return SDL_GetWindowSize(window, width, height);
}

extern "C" bool SDLCALL selective_SDL_GetWindowSizeInPixels(
    SDL_Window* window,
    int* width,
    int* height
)
{
    if (selective_probe_window_size(window, width, height))
        return true;
    return SDL_GetWindowSizeInPixels(window, width, height);
}

extern "C" int SDLCALL selective_SDL_PeepEvents(
    SDL_Event* events,
    int numevents,
    SDL_EventAction action,
    Uint32 minType,
    Uint32 maxType
)
{
    if (!events || (numevents != 1) || (action != SDL_GETEVENT) ||
        !staleDisplayEventGuardEnabled())
    {
        return SDL_PeepEvents(events, numevents, action, minType, maxType);
    }

    for (;;)
    {
        const int rc = SDL_PeepEvents(events, numevents, action, minType, maxType);
        if (rc <= 0)
            return rc;
        if (!staleDisplayPropertyEvent(events[0]))
            return rc;

        std::fprintf(
            stderr,
            "[SelectiveRemote] Dropped stale SDL display event 0x%08x for display %u\n",
            static_cast<unsigned int>(events[0].type),
            static_cast<unsigned int>(events[0].display.displayID)
        );
    }
}

#define SELECTIVE_DYLD_INTERPOSE(replacement, replacee)                                      \
    __attribute__((used)) static struct                                                       \
    {                                                                                         \
        const void* replacement;                                                              \
        const void* replacee;                                                                 \
    } _selective_interpose_##replacee __attribute__((section("__DATA,__interpose"))) = {      \
        (const void*)(std::uintptr_t)&replacement, (const void*)(std::uintptr_t)&replacee      \
    };

SELECTIVE_DYLD_INTERPOSE(
    selective_freerdp_set_monitor_def_array_sorted,
    freerdp_settings_set_monitor_def_array_sorted
)
SELECTIVE_DYLD_INTERPOSE(
    selective_SDL_CreateWindowWithProperties,
    SDL_CreateWindowWithProperties
)
SELECTIVE_DYLD_INTERPOSE(
    selective_SDL_SetWindowFullscreen,
    SDL_SetWindowFullscreen
)
SELECTIVE_DYLD_INTERPOSE(
    selective_SDL_GetWindowSize,
    SDL_GetWindowSize
)
SELECTIVE_DYLD_INTERPOSE(
    selective_SDL_GetWindowSizeInPixels,
    SDL_GetWindowSizeInPixels
)
SELECTIVE_DYLD_INTERPOSE(
    selective_SDL_PeepEvents,
    SDL_PeepEvents
)
#endif
