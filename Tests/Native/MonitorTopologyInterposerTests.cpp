#include <freerdp/settings.h>

#include <cstdio>
#include <cstdlib>
#include <limits>

#include "../../Native/FnTapRecognizer.hpp"

extern "C" BOOL selective_freerdp_set_monitor_def_array_sorted(
    rdpSettings* settings,
    const rdpMonitor* monitors,
    size_t count
);
extern "C" bool selective_rdp_is_probe_window_title(const char* title);
extern "C" bool selective_rdp_probe_display_id(const char* title, UINT32* displayID);

namespace
{
bool expect(bool condition, const char* message)
{
    if (condition)
        return true;
    std::fprintf(stderr, "Native monitor test failed: %s\n", message);
    return false;
}
}

int main()
{
    bool passed = true;
    FnTapRecognizer fnTap;
    fnTap.fnChanged(true);
    fnTap.fnChanged(false);
    passed &= expect(fnTap.takeTap(), "single Fn tap was not recognized");
    passed &= expect(!fnTap.takeTap(), "Fn tap fired more than once");

    fnTap.fnChanged(true);
    fnTap.otherKeyChanged();
    fnTap.fnChanged(false);
    passed &= expect(!fnTap.takeTap(), "Fn plus another key was treated as a tap");

    fnTap.fnChanged(true, true);
    fnTap.fnChanged(false);
    passed &= expect(!fnTap.takeTap(), "Fn plus another modifier was treated as a tap");

    fnTap.fnChanged(true);
    fnTap.cancel();
    fnTap.fnChanged(false);
    passed &= expect(!fnTap.takeTap(), "cancelled Fn press was treated as a tap");

    passed &= expect(
        selective_rdp_is_probe_window_title("SdlWindow::query(2)"),
        "probe window title was not recognized"
    );
    passed &= expect(
        !selective_rdp_is_probe_window_title("SelectiveRemote — Work"),
        "session window was mistaken for a probe"
    );
    passed &= expect(
        !selective_rdp_is_probe_window_title("SdlWindow::query(2) extra"),
        "malformed probe title was accepted"
    );
    UINT32 probeDisplayID = 0;
    passed &= expect(
        selective_rdp_probe_display_id(
            "SdlWindow::query(4294967295)",
            &probeDisplayID
        ) && (probeDisplayID == std::numeric_limits<UINT32>::max()),
        "probe display ID was not parsed"
    );
    passed &= expect(
        !selective_rdp_probe_display_id(
            "SdlWindow::query(4294967296)",
            &probeDisplayID
        ),
        "overflowing probe display ID was accepted"
    );
    if (setenv(
            "SELECTIVE_RDP_MONITOR_LAYOUT",
            "2:0:0:1;3:2560:0:0",
            1
        ) != 0)
        return 1;

    rdpSettings* settings = freerdp_settings_new(0);
    if (!expect(settings != nullptr, "could not create rdpSettings"))
        return 1;

    rdpMonitor monitors[2] = {};
    monitors[0].orig_screen = 2;
    monitors[0].x = -2560;
    monitors[0].y = -111;
    monitors[0].width = 2560;
    monitors[0].height = 1440;
    monitors[0].is_primary = TRUE;
    monitors[1].orig_screen = 3;
    monitors[1].x = 2056;
    monitors[1].y = -111;
    monitors[1].width = 2560;
    monitors[1].height = 1440;

    passed &= expect(
        selective_freerdp_set_monitor_def_array_sorted(settings, monitors, 2),
        "interposer returned FALSE"
    );
    passed &= expect(
        selective_freerdp_set_monitor_def_array_sorted(settings, monitors, 2),
        "repeated interposer call returned FALSE"
    );
    passed &= expect(
        freerdp_settings_get_uint32(settings, FreeRDP_MonitorCount) == 2,
        "monitor count is not 2"
    );

    const auto* first = static_cast<const rdpMonitor*>(
        freerdp_settings_get_pointer_array(settings, FreeRDP_MonitorDefArray, 0)
    );
    const auto* second = static_cast<const rdpMonitor*>(
        freerdp_settings_get_pointer_array(settings, FreeRDP_MonitorDefArray, 1)
    );
    passed &= expect(
        first && first->orig_screen == 2 && first->x == 0 && first->y == 0 &&
            first->is_primary,
        "primary monitor was not normalized"
    );
    passed &= expect(
        second && second->orig_screen == 3 && second->x == 2560 && second->y == 0 &&
            !second->is_primary,
        "secondary monitor was not compacted"
    );

    if (setenv(
            "SELECTIVE_RDP_MONITOR_LAYOUT",
            "2:0:0:1;3:0:-1440:0",
            1
        ) != 0)
        return 1;
    passed &= expect(
        selective_freerdp_set_monitor_def_array_sorted(settings, monitors, 2),
        "manual vertical topology returned FALSE"
    );
    const auto* verticalSecond = static_cast<const rdpMonitor*>(
        freerdp_settings_get_pointer_array(settings, FreeRDP_MonitorDefArray, 1)
    );
    passed &= expect(
        verticalSecond && verticalSecond->orig_screen == 3 && verticalSecond->x == 0 &&
            verticalSecond->y == -1440 && !verticalSecond->is_primary,
        "manual vertical topology was not preserved"
    );

    freerdp_settings_free(settings);
    if (!passed)
        return 1;

    std::puts("Native monitor interposer test passed");
    return 0;
}
