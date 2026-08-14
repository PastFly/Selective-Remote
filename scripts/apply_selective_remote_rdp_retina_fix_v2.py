#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path.cwd()

SERVICE = ROOT / "Sources/SelectiveRemote/FreeRDPService.swift"
INTERPOSER = ROOT / "Native/MonitorTopologyInterposer.cpp"
TESTS = ROOT / "Tests/SelectiveRemoteTests/VirtualTopologyMapperTests.swift"

for path in (SERVICE, INTERPOSER, TESTS):
    if not path.exists():
        raise SystemExit(f"ERROR: missing expected file: {path}")

def write(path: Path, text: str):
    path.write_text(text, encoding="utf-8")

def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count == 0:
        if new in text:
            print(f"already fixed: {label}")
            return text
        raise SystemExit(f"ERROR: anchor not found for {label}")
    if count != 1:
        raise SystemExit(f"ERROR: expected one anchor for {label}, found {count}")
    print(f"fixed: {label}")
    return text.replace(old, new, 1)

service = SERVICE.read_text(encoding="utf-8")

service_new, n = re.subn(
    r"""let smartSizing = singleDisplayFullscreen
            \? RDPDesktopSize\(
                width: selected\[0\]\.(?:pixelWidth|rdpWidthHint),
                height: selected\[0\]\.(?:pixelHeight|rdpHeightHint)
            \)
            : nil""",
    """let smartSizing = singleDisplayFullscreen
            ? RDPDesktopSize(
                width: selected[0].rdpWidthHint,
                height: selected[0].rdpHeightHint
            )
            : nil""",
    service,
    count=1
)
if n == 1:
    service = service_new
    print("fixed: single-monitor fullscreen smart-sizing normalized to logical AppKit size")
elif "width: selected[0].rdpWidthHint" in service and "height: selected[0].rdpHeightHint" in service:
    print("already fixed: smart-sizing uses logical AppKit size")
else:
    raise SystemExit("ERROR: smart-sizing block not found")

old_env = """        processEnvironment.removeValue(forKey: "SELECTIVE_RDP_MONITOR_LAYOUT")
        if monitorLayout.count > 1 {
            let interposer = try monitorInterposerURL()
            processEnvironment["DYLD_INSERT_LIBRARIES"] = prependPath(
                interposer.path,
                to: processEnvironment["DYLD_INSERT_LIBRARIES"]
            )
            processEnvironment["SELECTIVE_RDP_MONITOR_LAYOUT"] =
                SDLTopologyMapper.environmentValue(monitorLayout)
        }"""

new_env = """        processEnvironment.removeValue(forKey: "SELECTIVE_RDP_MONITOR_LAYOUT")
        processEnvironment.removeValue(forKey: "SELECTIVE_RDP_FORCE_LOGICAL_FULLSCREEN")

        // SDL3/FreeRDP creates macOS windows with SDL_WINDOW_HIGH_PIXEL_DENSITY.
        // On the affected Retina fullscreen path the SDL renderer receives a 2x
        // backing surface while FreeRDP composes in logical window coordinates,
        // leaving the desktop in the upper-left quarter. Load our existing SDL
        // interposer for this single-display fullscreen path as well as multimon.
        if singleDisplayFullscreen || monitorLayout.count > 1 {
            let interposer = try monitorInterposerURL()
            processEnvironment["DYLD_INSERT_LIBRARIES"] = prependPath(
                interposer.path,
                to: processEnvironment["DYLD_INSERT_LIBRARIES"]
            )
        }
        if singleDisplayFullscreen {
            processEnvironment["SELECTIVE_RDP_FORCE_LOGICAL_FULLSCREEN"] = "1"
        }
        if monitorLayout.count > 1 {
            processEnvironment["SELECTIVE_RDP_MONITOR_LAYOUT"] =
                SDLTopologyMapper.environmentValue(monitorLayout)
        }"""

service = replace_once(
    service, old_env, new_env,
    "single-monitor fullscreen now loads SDL interposer and requests 1x framebuffer"
)

marker_old = """        if let smartSizing {
            launchMarkers += "[SelectiveRemote Host] Single-monitor fullscreen: "
                + "native Retina drawable, smart-sizing "
                + "\\(smartSizing.width)x\\(smartSizing.height), "
                + "wlroots fallback disabled\\n"
        }"""

marker_new = """        if let smartSizing {
            launchMarkers += "[SelectiveRemote Host] Single-monitor fullscreen: "
                + "logical SDL framebuffer compatibility, smart-sizing "
                + "\\(smartSizing.width)x\\(smartSizing.height), "
                + "high-pixel-density disabled, wlroots fallback disabled\\n"
        }"""

service = replace_once(
    service, marker_old, marker_new,
    "RDP log marker identifies Retina compatibility mode"
)

write(SERVICE, service)

native = INTERPOSER.read_text(encoding="utf-8")

anchor = """    const bool isProbe = selective_rdp_is_probe_window_title(title);

    if (isProbe)
    {"""

insert = """    const bool isProbe = selective_rdp_is_probe_window_title(title);

    const char* forceLogicalFullscreen =
        std::getenv("SELECTIVE_RDP_FORCE_LOGICAL_FULLSCREEN");
    const bool shouldForceLogicalFullscreen =
        !isProbe &&
        forceLogicalFullscreen &&
        (std::strcmp(forceLogicalFullscreen, "1") == 0) &&
        SDL_GetBooleanProperty(
            properties,
            SDL_PROP_WINDOW_CREATE_FULLSCREEN_BOOLEAN,
            false
        );

    if (shouldForceLogicalFullscreen)
    {
        // On macOS Retina, FreeRDP requests SDL_WINDOW_HIGH_PIXEL_DENSITY.
        // The affected SDL fullscreen path then exposes a 2x renderer output
        // while FreeRDP's desktop coordinates remain logical, which renders
        // the session in the upper-left quarter. For this compatibility path
        // keep window coordinates and renderer pixels 1:1. macOS will scale
        // the resulting surface to the physical Retina panel.
        SDL_SetBooleanProperty(
            properties,
            SDL_PROP_WINDOW_CREATE_HIGH_PIXEL_DENSITY_BOOLEAN,
            false
        );
        std::fputs(
            "[SelectiveRemote] Retina fullscreen compatibility: "
            "disabled SDL high-pixel-density backbuffer\\n",
            stderr
        );
    }

    if (isProbe)
    {"""

native = replace_once(
    native, anchor, insert,
    "real fullscreen RDP window disables SDL high-pixel-density backbuffer"
)

write(INTERPOSER, native)

tests = TESTS.read_text(encoding="utf-8")
test_marker = '@Test("Retina fullscreen использует 1x SDL framebuffer вместо четверти экрана")'

if test_marker not in tests:
    anchor = 'private let realSDLMonitorOutput = """'
    if anchor not in tests:
        raise SystemExit("ERROR: test insertion anchor not found")

    test = r"""
@Test("Retina fullscreen использует 1x SDL framebuffer вместо четверти экрана")
func forcesLogicalSDLFramebufferForRetinaFullscreen() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let service = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Sources/SelectiveRemote/FreeRDPService.swift"),
        encoding: .utf8
    )
    let interposer = try String(
        contentsOf: projectRoot
            .appendingPathComponent("Native/MonitorTopologyInterposer.cpp"),
        encoding: .utf8
    )

    #expect(service.contains("singleDisplayFullscreen || monitorLayout.count > 1"))
    #expect(service.contains("SELECTIVE_RDP_FORCE_LOGICAL_FULLSCREEN"))
    #expect(service.contains("width: selected[0].rdpWidthHint"))
    #expect(service.contains("height: selected[0].rdpHeightHint"))

    #expect(interposer.contains("SELECTIVE_RDP_FORCE_LOGICAL_FULLSCREEN"))
    #expect(interposer.contains("SDL_PROP_WINDOW_CREATE_HIGH_PIXEL_DENSITY_BOOLEAN"))
    #expect(interposer.contains("disabled SDL high-pixel-density backbuffer"))
}

"""
    tests = tests.replace(anchor, test + anchor, 1)
    print("fixed: added regression test for Retina quarter-screen rendering")
else:
    print("already fixed: Retina quarter-screen regression test")

write(TESTS, tests)

print()
print("Selective Remote emergency Retina RDP display fix v2 applied.")
print("Changed:")
print("  Sources/SelectiveRemote/FreeRDPService.swift")
print("  Native/MonitorTopologyInterposer.cpp")
print("  Tests/SelectiveRemoteTests/VirtualTopologyMapperTests.swift")
print()
print("IMPORTANT: rebuild the packaged app with scripts/build_and_install.sh;")
print("swift build alone does not rebuild the nested Selective Remote Session helper/interposer.")
