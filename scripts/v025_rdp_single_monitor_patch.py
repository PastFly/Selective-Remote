from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path: str, old: str, new: str) -> None:
    file = ROOT / path
    text = file.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {count}: {old[:80]!r}")
    file.write_text(text.replace(old, new, 1), encoding="utf-8")


# 1) Preserve native macOS fullscreen controls, but tell the hidden SDL monitor
# probe to negotiate a desktop height that excludes only the top menu/safe-area
# inset for a true single-display fullscreen session.
replace_once(
    "Sources/SelectiveRemote/FreeRDPService.swift",
    """        // With one physical display there is no mapping ambiguity, so avoid a
        // separate /list:monitor helper process. `monitorIDs == nil` means the
        // only current display. The native topology interposer is deliberately
        // not loaded for this path.
""",
    """        // With one physical display there is no mapping ambiguity, so avoid a
        // separate /list:monitor helper process. `monitorIDs == nil` means the
        // only current display. Fullscreen still uses the native interposer so
        // its hidden probe can reserve the macOS top safe area without a second
        // monitor-list process.
""",
)

replace_once(
    "Sources/SelectiveRemote/FreeRDPService.swift",
    """        processEnvironment.removeValue(forKey: "SELECTIVE_RDP_FULLSCREEN_SAFE_TOP_IDS")
        processEnvironment.removeValue(forKey: "SELECTIVE_RDP_STALE_DISPLAY_EVENT_GUARD")
""",
    """        processEnvironment.removeValue(forKey: "SELECTIVE_RDP_FULLSCREEN_SAFE_TOP_IDS")
        processEnvironment.removeValue(forKey: "SELECTIVE_RDP_FULLSCREEN_SAFE_SINGLE")
        processEnvironment.removeValue(forKey: "SELECTIVE_RDP_STALE_DISPLAY_EVENT_GUARD")
""",
)

replace_once(
    "Sources/SelectiveRemote/FreeRDPService.swift",
    """        if fullscreenLogicalBacking {
            processEnvironment["SELECTIVE_RDP_FORCE_LOGICAL_FULLSCREEN"] = "1"
            if !builtInSDLMonitorIDs.isEmpty {
                processEnvironment["SELECTIVE_RDP_FULLSCREEN_SAFE_TOP_IDS"] =
                    builtInSDLMonitorIDs.map(String.init).joined(separator: ",")
            }
        }
""",
    """        if fullscreenLogicalBacking {
            processEnvironment["SELECTIVE_RDP_FORCE_LOGICAL_FULLSCREEN"] = "1"
            if singleDisplayFullscreen {
                // The single-monitor path intentionally skips /list:monitor, so
                // there is no SDL monitor ID to put into SAFE_TOP_IDS. Let the
                // interposer identify the sole current SDL display and subtract
                // only its top menu/safe-area inset from the negotiated desktop.
                processEnvironment["SELECTIVE_RDP_FULLSCREEN_SAFE_SINGLE"] = "1"
            }
            if !builtInSDLMonitorIDs.isEmpty {
                processEnvironment["SELECTIVE_RDP_FULLSCREEN_SAFE_TOP_IDS"] =
                    builtInSDLMonitorIDs.map(String.init).joined(separator: ",")
            }
        }
""",
)

replace_once(
    "Sources/SelectiveRemote/FreeRDPService.swift",
    """            launchMarkers += "[SelectiveRemote Host] Single-monitor fullscreen: "
                + "native monitor sizing, smart-sizing disabled, "
                + "monitor=\(selectedMonitor), multimon disabled\n"
""",
    """            launchMarkers += "[SelectiveRemote Host] Single-monitor fullscreen: "
                + "logical monitor sizing, macOS top safe-area reserved, "
                + "smart-sizing disabled, monitor=\(selectedMonitor), multimon disabled\n"
""",
)

replace_once(
    "Sources/SelectiveRemote/FreeRDPService.swift",
    """        // Fullscreen RDP owns its macOS Space. An accessible macOS menu bar
        // reserves vertical space while FreeRDP still creates a full-height
        // monitor window, which can clip the Windows taskbar below the visible
        // area. The app provides its own fullscreen escape shortcut, so keep the
        // system menu hidden for programmatic SDL fullscreen.
        environment["SDL_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY"] = "0"
""",
    """        // Keep normal macOS fullscreen behavior: moving the pointer to the
        // top edge must reveal the menu/title-bar controls. Single-display RDP
        // geometry is corrected separately by the monitor probe safe-area path;
        // hiding the menu here would only remove the user's way to reach the
        // native close/minimize/fullscreen controls.
        environment["SDL_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY"] = "1"
""",
)

# 2) Extend the existing top-safe-area probe logic to the no-/list single display
# path. We intentionally subtract only the top inset, never the Dock/bottom inset.
replace_once(
    "Native/MonitorTopologyInterposer.cpp",
    """bool monitorComesBefore(const rdpMonitor& lhs, const rdpMonitor& rhs)
{
""",
    """#if !defined(SELECTIVE_RDP_TESTING)
bool singleDisplaySafeTopRequested(UINT32 displayID)
{
    const char* raw = std::getenv("SELECTIVE_RDP_FULLSCREEN_SAFE_SINGLE");
    if (!raw || (std::strcmp(raw, "1") != 0))
        return false;

    int count = 0;
    SDL_DisplayID* displays = SDL_GetDisplays(&count);
    if (!displays)
        return false;

    const bool matchesSoleDisplay =
        (count == 1) && (static_cast<UINT32>(displays[0]) == displayID);
    SDL_free(displays);
    return matchesSoleDisplay;
}
#endif

bool monitorComesBefore(const rdpMonitor& lhs, const rdpMonitor& rhs)
{
""",
)

replace_once(
    "Native/MonitorTopologyInterposer.cpp",
    """    const char* safeIDs = std::getenv("SELECTIVE_RDP_FULLSCREEN_SAFE_TOP_IDS");
    const bool reserveSafeTop = displayIDListed(safeIDs, rawDisplayID);
    if (reserveSafeTop)
""",
    """    const char* safeIDs = std::getenv("SELECTIVE_RDP_FULLSCREEN_SAFE_TOP_IDS");
    const bool safeByMappedID = displayIDListed(safeIDs, rawDisplayID);
    const bool safeSingleDisplay = singleDisplaySafeTopRequested(rawDisplayID);
    const bool reserveSafeTop = safeByMappedID || safeSingleDisplay;
    if (reserveSafeTop)
""",
)

replace_once(
    "Native/MonitorTopologyInterposer.cpp",
    """        reserveSafeTop ? "fullscreen-safe" : "logical",
""",
    """        reserveSafeTop
            ? (safeSingleDisplay ? "single-display-safe" : "fullscreen-safe")
            : "logical",
""",
)

# 3) Regression coverage for both pieces of the bug: hover controls and the
# single-monitor top-safe probe path.
replace_once(
    "Tests/SelectiveRemoteTests/VirtualTopologyMapperTests.swift",
    """@Test("Служебные окна SDL скрыты, а macOS menu bar не режет fullscreen RDP")
func configuresSDLSessionEnvironment() {
""",
    """@Test("Служебные окна SDL скрыты, а macOS menu bar доступен по наведению")
func configuresSDLSessionEnvironment() {
""",
)

text_path = ROOT / "Tests/SelectiveRemoteTests/VirtualTopologyMapperTests.swift"
text = text_path.read_text(encoding="utf-8")
old_expect = '#expect(environment["SDL_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY"] == "0")'
if text.count(old_expect) != 2:
    raise SystemExit(f"VirtualTopologyMapperTests.swift: expected two old menu assertions, found {text.count(old_expect)}")
text_path.write_text(text.replace(old_expect, '#expect(environment["SDL_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY"] == "1")'), encoding="utf-8")

insert_after = """    @Test("Local and SSH terminals reuse the complete appearance editor")
    func paneAppearanceUsesFullEditor() throws {
"""
terminal_test = ROOT / "Tests/SelectiveRemoteTests/TerminalUX0250Tests.swift"
terminal_text = terminal_test.read_text(encoding="utf-8")
if insert_after not in terminal_text:
    raise SystemExit("TerminalUX0250Tests.swift: insertion anchor missing")
new_test = """    @Test("Single-monitor fullscreen keeps macOS controls and reserves top safe area")
    func singleMonitorFullscreenUsesSafeProbeWithoutHidingControls() throws {
        let service = try source("Sources/SelectiveRemote/FreeRDPService.swift")
        let interposer = try source("Native/MonitorTopologyInterposer.cpp")

        #expect(service.contains(#"environment["SDL_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY"] = "1""#))
        #expect(service.contains("SELECTIVE_RDP_FULLSCREEN_SAFE_SINGLE"))
        #expect(interposer.contains("singleDisplaySafeTopRequested"))
        #expect(interposer.contains("SDL_GetDisplays(&count)"))
        #expect(interposer.contains("SDL_GetDisplayUsableBounds"))
        #expect(interposer.contains("bounds.h -= topInset"))
    }

"""
terminal_test.write_text(terminal_text.replace(insert_after, new_test + insert_after, 1), encoding="utf-8")

# 4) Candidate build and release notes.
replace_once(
    "scripts/build_app.sh",
    'BUILD_NUMBER="135"',
    'BUILD_NUMBER="136"',
)

replace_once(
    "CHANGELOG.md",
    "- Исправлен fullscreen RDP на одном мониторе macOS: системная строка меню больше не резервирует скрытую вертикальную область, из-за которой панель задач Windows могла оказаться ниже видимого экрана.",
    "- Исправлен fullscreen RDP на одном мониторе macOS: системные menu/title-bar controls снова появляются при наведении вверх, а hidden SDL probe отдельно учитывает только верхнюю safe-area/menu bar при расчёте высоты удалённого рабочего стола, чтобы панель задач Windows не уходила ниже видимой области.",
)

replace_once(
    "CHANGELOG_EN.md",
    "- Fixed single-monitor fullscreen RDP on macOS: the system menu bar no longer reserves hidden vertical space that could push the Windows taskbar below the visible desktop.",
    "- Fixed single-monitor fullscreen RDP on macOS: native menu/title-bar controls are reachable again at the top edge, while the hidden SDL probe separately subtracts only the top safe-area/menu-bar inset from the negotiated remote desktop height so the Windows taskbar stays visible.",
)

print("v0.25.0 single-monitor RDP round-three patch applied")
