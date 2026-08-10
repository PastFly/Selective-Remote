import Darwin
import Foundation

enum FreeRDPError: LocalizedError {
    case executableNotFound
    case monitorListFailed(String)
    case monitorMappingFailed(String)
    case noSelectedMonitors
    case invalidHost
    case monitorInterposerNotFound
    case fnShortcutModuleNotFound
    case privacyPreflightNotFound
    case unsupportedArgumentLineBreak
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "В пакете \(AppBrand.name) не найден встроенный RDP-движок. Переустановите приложение из полного community DMG"
        case let .monitorListFailed(message):
            "Не удалось получить список мониторов FreeRDP: \(message)"
        case let .monitorMappingFailed(name):
            "FreeRDP не смог сопоставить монитор «\(name)»"
        case .noSelectedMonitors:
            "Выберите хотя бы один монитор"
        case .invalidHost:
            "Укажите hostname удалённого компьютера"
        case .monitorInterposerNotFound:
            "Не найден модуль компактной раскладки мониторов. Пересоберите \(AppBrand.name) скриптом scripts/build_app.sh"
        case .fnShortcutModuleNotFound:
            "Не найден безопасный модуль клавиши Fn. Пересоберите \(AppBrand.name) скриптом scripts/build_app.sh"
        case .privacyPreflightNotFound:
            "Не найден модуль предварительной проверки доступа к микрофону и камере. Пересоберите \(AppBrand.name) скриптом scripts/build_app.sh"
        case .unsupportedArgumentLineBreak:
            "Параметры подключения не должны содержать перенос строки"
        case let .launchFailed(message):
            "Не удалось запустить RDP: \(message)"
        }
    }
}

struct RDPDesktopSize: Equatable {
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = max(200, width)
        self.height = max(200, height)
    }
}

struct RunningRDPSession {
    let process: Process
    let logURL: URL
    let logHandle: FileHandle
    let commandPipeURL: URL
}

final class FreeRDPService {
    private static let cameraAddinNames = [
        "librdpecam-client.dylib",
        "librdpecam-client.so"
    ]

    private static let detectedCameraRedirectionAvailable: Bool = {
        let frameworks = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("Selective Remote Session.app", isDirectory: true)
            .appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: frameworks,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }

        return enumerator.contains { item in
            guard let url = item as? URL else { return false }
            return cameraAddinNames.contains(url.lastPathComponent)
        }
    }()

    /// Camera redirection is available only in the packaged application where
    /// the isolated RDPECAM addin was built and embedded. Development launches
    /// through `swift run` keep the switch disabled instead of starting a
    /// connection that cannot load the channel.
    static var cameraRedirectionAvailable: Bool {
        detectedCameraRedirectionAvailable
    }

    private let fileManager: FileManager
    private let cameraRedirectionOverride: Bool?
    private var cachedMonitors: [SDLMonitor]?

    init(
        fileManager: FileManager = .default,
        cameraRedirectionAvailable: Bool? = nil
    ) {
        self.fileManager = fileManager
        cameraRedirectionOverride = cameraRedirectionAvailable
    }

    private var canRedirectCamera: Bool {
        cameraRedirectionOverride ?? Self.cameraRedirectionAvailable
    }

    func invalidateMonitorCache() {
        cachedMonitors = nil
    }

    func listMonitors(forceRefresh: Bool = false) throws -> [SDLMonitor] {
        if !forceRefresh, let cachedMonitors {
            return cachedMonitors
        }

        let process = Process()
        process.executableURL = try sessionExecutableURL()
        process.currentDirectoryURL = bundledSessionFrameworksURL()
        process.arguments = ["/list:monitor"]
        process.environment = launchEnvironment(from: ProcessInfo.processInfo.environment)

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            throw FreeRDPError.monitorListFailed(error.localizedDescription)
        }

        // Drain the pipe while the helper is still running. Waiting first can
        // deadlock if a future FreeRDP build writes more than the pipe capacity.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        let monitors = try validatedMonitorList(text, terminationStatus: process.terminationStatus)
        cachedMonitors = monitors
        return monitors
    }

    func launch(
        profile: ConnectionProfile,
        displays: [DisplayDescriptor],
        password: String,
        gatewayPassword: String = ""
    ) throws -> RunningRDPSession {
        let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw FreeRDPError.invalidHost }

        let selected = displays.filter { profile.selectedDisplayIDs.contains($0.id) }
        guard !selected.isEmpty else { throw FreeRDPError.noSelectedMonitors }

        let monitorLayout: [SDLMonitorPlacement]
        let monitorIDs: [Int]?

        // With one physical display there is no mapping ambiguity, so avoid a
        // separate /list:monitor helper process. `monitorIDs == nil` means the
        // only current display. The native topology interposer is deliberately
        // not loaded for this path.
        if profile.rdpWindowMode != .fullScreen || !profile.startFullScreen {
            // Windowed sessions use one resizable SDL window. The selected
            // macOS monitor still determines where the user opens it, but no
            // FreeRDP multimon topology is requested.
            monitorLayout = []
            monitorIDs = nil
        } else if displays.count == 1, selected.count == 1 {
            monitorLayout = []
            monitorIDs = nil
        } else {
            let sdlMonitors = try listMonitors()
            let mappings = try matchDisplays(selected, to: sdlMonitors, allDisplays: displays)
            monitorLayout = SDLTopologyMapper.arrange(
                mappings: mappings,
                primaryDisplayID: profile.primaryDisplayID,
                mode: profile.displayLayoutMode,
                customOrigins: profile.virtualDisplayOrigins
            )
            monitorIDs = monitorLayout.map(\.monitorID)
        }
        let executable = try sessionExecutableURL()

        let singleDisplayFullscreen = displays.count == 1
            && selected.count == 1
            && profile.rdpWindowMode == .fullScreen
            && profile.startFullScreen
        let smartSizing = singleDisplayFullscreen
            ? RDPDesktopSize(
                width: selected[0].rdpWidthHint,
                height: selected[0].rdpHeightHint
            )
            : nil

        let arguments = try connectionArguments(
            profile: profile,
            monitorIDs: monitorIDs,
            smartSizing: smartSizing,
            gatewayPassword: gatewayPassword
        )
        let stdinPayload = try argumentsFromStdinPayload(arguments, password: password)

        // Never force the wlroots fallback in a real RDP session. It reports
        // logical display bounds for every SDL window and therefore renders a
        // 2056x1329 framebuffer into only one quarter of a 4112x2658 Retina
        // fullscreen surface. The topology interposer supplies logical bounds
        // only to the hidden monitor probes and leaves session windows at their
        // native per-display pixel density.
        var processEnvironment = launchEnvironment(
            from: ProcessInfo.processInfo.environment,
            useMonitorProbeFallback: false
        )
        processEnvironment.removeValue(forKey: "SELECTIVE_RDP_MONITOR_LAYOUT")
        if monitorLayout.count > 1 {
            let interposer = try monitorInterposerURL()
            processEnvironment["DYLD_INSERT_LIBRARIES"] = prependPath(
                interposer.path,
                to: processEnvironment["DYLD_INSERT_LIBRARIES"]
            )
            processEnvironment["SELECTIVE_RDP_MONITOR_LAYOUT"] =
                SDLTopologyMapper.environmentValue(monitorLayout)
        }
        let fnShortcutModule = try fnShortcutModuleURL()
        let commandPipeURL = URL(
            fileURLWithPath: "/tmp/selectiveremote-rdp-\(UUID().uuidString).fifo"
        )
        guard Darwin.mkfifo(commandPipeURL.path, S_IRUSR | S_IWUSR) == 0 else {
            throw FreeRDPError.launchFailed("не удалось создать канал управления RDP")
        }
        var removeCommandPipeOnFailure = true
        defer {
            if removeCommandPipeOnFailure {
                try? fileManager.removeItem(at: commandPipeURL)
            }
        }
        processEnvironment = keyboardHotkeyEnvironment(
            from: processEnvironment,
            profile: profile,
            shortcutModule: fnShortcutModule,
            commandPipeURL: commandPipeURL
        )
        let needsPrivacyPreflight = profile.redirectMicrophone
            || (profile.redirectCamera && canRedirectCamera)
        let privacyPreflight = needsPrivacyPreflight
            ? try privacyPreflightURL()
            : nil
        processEnvironment = privacyPreflightEnvironment(
            from: processEnvironment,
            profile: profile,
            preflightLibrary: privacyPreflight
        )
        processEnvironment = cameraConfigurationEnvironment(
            from: processEnvironment,
            profile: profile
        )
        let logURL = try makeLogURL(profileID: profile.id)
        fileManager.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        var launchMarkers = ""
        if let smartSizing {
            launchMarkers += "[SelectiveRemote Host] Single-monitor fullscreen: "
                + "native Retina drawable, smart-sizing "
                + "\(smartSizing.width)x\(smartSizing.height), "
                + "wlroots fallback disabled\n"
        }
        if monitorLayout.count > 1 {
            launchMarkers += "[SelectiveRemote Host] Multi-monitor fullscreen: "
                + "native per-window pixel density, probe-only logical bounds, "
                + "wlroots fallback disabled\n"
        }
        launchMarkers += rdpQualityLaunchMarker(profile: profile)
        launchMarkers += keyboardLaunchMarker(profile: profile)
        if profile.redirectCamera && canRedirectCamera {
            launchMarkers += cameraLaunchMarker(profile: profile)
        }
        let requestedFolders = profile.redirectedFolders.filter { !$0.isEmpty }
        let availableFolders = accessibleRedirectedFolders(profile.redirectedFolders)
        let skippedFolderCount = requestedFolders.count - availableFolders.count
        if skippedFolderCount > 0 {
            launchMarkers += "[SelectiveRemote Host] Skipped inaccessible redirected folders: "
                + "\(skippedFolderCount)\n"
        }
        if !launchMarkers.isEmpty {
            logHandle.write(Data(launchMarkers.utf8))
        }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = bundledSessionFrameworksURL()
        // /args-from keeps the password and all connection details out of the
        // process list. FreeRDP expects exactly one argument per input line.
        process.arguments = ["/args-from:stdin"]
        process.standardOutput = logHandle
        process.standardError = logHandle
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        process.environment = processEnvironment

        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(stdinPayload)
            try? inputPipe.fileHandleForWriting.close()
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            try? logHandle.close()
            throw FreeRDPError.launchFailed(error.localizedDescription)
        }

        removeCommandPipeOnFailure = false
        return RunningRDPSession(
            process: process,
            logURL: logURL,
            logHandle: logHandle,
            commandPipeURL: commandPipeURL
        )
    }

    func connectionArguments(
        profile: ConnectionProfile,
        monitorIDs: [Int]?,
        smartSizing: RDPDesktopSize? = nil,
        gatewayPassword: String = ""
    ) throws -> [String] {
        let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw FreeRDPError.invalidHost }
        if let monitorIDs, monitorIDs.isEmpty {
            throw FreeRDPError.noSelectedMonitors
        }

        var arguments = ["/v:\(host)"]
        arguments.append("/title:\(sessionWindowTitle(for: profile))")
        arguments.append("/wm-class:local.selectiveremote.session")
        let username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !username.isEmpty {
            let components = username.split(separator: "\\", maxSplits: 1, omittingEmptySubsequences: false)
            if components.count == 2 {
                arguments.append("/d:\(components[0])")
                arguments.append("/u:\(components[1])")
            } else {
                arguments.append("/u:\(username)")
            }
        }

        if profile.rdpWindowMode == .fullScreen && profile.startFullScreen {
            arguments.append("/f")
            if monitorIDs == nil, let smartSizing {
                // Keep the native Retina backing and let SDL-FreeRDP scale the
                // complete Windows framebuffer to the actual fullscreen drawable
                // area. This preserves both the Windows taskbar and the macOS menu
                // bar instead of clipping one edge of the remote desktop.
                arguments.append(
                    "/smart-sizing:\(smartSizing.width)x\(smartSizing.height)"
                )
            }
        } else {
            arguments.append("/size:\(max(640, profile.windowWidth))x\(max(480, profile.windowHeight))")
            if profile.rdpWindowMode == .dynamicWindow {
                arguments.append("+dynamic-resolution")
            }
        }
        if let monitorIDs {
            arguments.append("/multimon")
            arguments.append("/monitors:\(monitorIDs.map(String.init).joined(separator: ","))")
        }
        arguments.append("/scale:\(profile.windowsScale.rawValue)")
        if let qualityArgument = profile.rdpQuality.freeRDPArgument {
            arguments.append(qualityArgument)
        }
        arguments += localInputReleaseArguments()

        switch profile.audioMode {
        case .local:
            arguments += ["/audio-mode:redirect", "/sound"]
        case .remote:
            arguments.append("/audio-mode:server")
        case .muted:
            arguments.append("/audio-mode:none")
        }

        switch profile.clipboardMode {
        case .bidirectional:
            arguments.append("/clipboard:direction-to:all")
        case .macToWindows:
            arguments.append("/clipboard:direction-to:remote")
        case .windowsToMac:
            arguments.append("/clipboard:direction-to:local")
        case .disabled:
            arguments.append("-clipboard")
        }
        // FreeRDP accepts at most two modern `/kbd:remap` entries. Physical
        // Command/Option mappings stay here because SDL handles them reliably;
        // Fn, the control panel and custom rules use the helper module.
        arguments.append(keyboardRemapArgument(profile: profile))
        if profile.redirectMicrophone { arguments.append("/microphone") }
        if profile.redirectCamera && canRedirectCamera { arguments.append("/dvc:rdpecam") }
        if profile.redirectPrinters { arguments.append("/printer") }
        if profile.autoReconnect { arguments.append("+auto-reconnect") }
        if profile.adminSession { arguments.append("/admin") }

        switch profile.certificatePolicy {
        case .trustOnFirstUse: arguments.append("/cert:tofu")
        case .strict: arguments.append("/cert:deny")
        case .ignore: arguments.append("/cert:ignore")
        }

        for (index, path) in accessibleRedirectedFolders(profile.redirectedFolders).enumerated() {
            arguments.append("/drive:Folder\(index + 1),\(path)")
        }

        let gateway = profile.gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !gateway.isEmpty {
            var value = "g:\(gateway)"
            let gatewayUser = profile.gatewayUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            if !gatewayUser.isEmpty { value += ",u:\(gatewayUser)" }
            if !gatewayPassword.isEmpty { value += ",p:\(gatewayPassword)" }
            arguments.append("/gateway:\(value)")
        }
        return arguments
    }

    /// Matches AppKit screens to SDL monitor IDs without depending on any
    /// particular monitor model. Exact names win, followed by logical/pixel
    /// resolution and physical left-to-right order. This also handles multiple
    /// displays with the same resolution by assigning each SDL ID only once.
    func matchDisplays(
        _ selected: [DisplayDescriptor],
        to monitors: [SDLMonitor],
        allDisplays: [DisplayDescriptor]
    ) throws -> [SDLDisplayMapping] {
        guard monitors.count >= selected.count else {
            throw FreeRDPError.monitorMappingFailed(selected.first?.name ?? "неизвестный дисплей")
        }

        let appKitOrder = allDisplays
            .sorted { $0.frame.minX == $1.frame.minX ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }
            .map(\.id)
        let sdlOrder = monitors
            .sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
            .map(\.id)
        let appKitIndices = Dictionary(
            uniqueKeysWithValues: appKitOrder.enumerated().map { ($0.element, $0.offset) }
        )
        let sdlIndices = Dictionary(
            uniqueKeysWithValues: sdlOrder.enumerated().map { ($0.element, $0.offset) }
        )
        var available = monitors
        var result: [SDLDisplayMapping] = []

        for display in selected.sorted(by: {
            $0.frame.minX == $1.frame.minX ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX
        }) {
            let appKitIndex = appKitIndices[display.id]
            let ranked = available.map { monitor -> (SDLMonitor, Int) in
                var score = 0
                if normalize(monitor.name) == normalize(display.name) { score += 1_000_000 }
                if monitor.width == display.rdpWidthHint && monitor.height == display.rdpHeightHint {
                    score += 100_000
                }
                if monitor.width == display.pixelWidth && monitor.height == display.pixelHeight {
                    score += 80_000
                }
                if display.isSystemMain == monitor.isSystemPrimary { score += 10_000 }
                if let appKitIndex, sdlIndices[monitor.id] == appKitIndex {
                    score += 5_000
                }
                let dimensionDelta = abs(monitor.width - display.rdpWidthHint)
                    + abs(monitor.height - display.rdpHeightHint)
                score -= min(dimensionDelta, 4_000)
                return (monitor, score)
            }
            guard let match = ranked.max(by: { $0.1 < $1.1 })?.0 else {
                throw FreeRDPError.monitorMappingFailed(display.name)
            }
            available.removeAll { $0.id == match.id }
            result.append(SDLDisplayMapping(displayID: display.id, monitor: match))
        }
        return result
    }

    func argumentsFromStdinPayload(_ arguments: [String], password: String) throws -> Data {
        var secureArguments = arguments
        if !password.isEmpty { secureArguments.append("/p:\(password)") }

        guard !secureArguments.contains(where: {
            $0.contains("\n") || $0.contains("\r")
        }) else {
            throw FreeRDPError.unsupportedArgumentLineBreak
        }

        return Data((secureArguments.joined(separator: "\n") + "\n").utf8)
    }

    func launchEnvironment(
        from base: [String: String],
        useMonitorProbeFallback: Bool = true
    ) -> [String: String] {
        // SDL-FreeRDP creates and destroys temporary fullscreen windows while
        // measuring every display. On macOS the last temporary window may emit
        // SDL_EVENT_QUIT and cancel an otherwise valid connection (exit 145).
        // This only disables that implicit event; Command-Q and signals remain
        // normal quit paths according to SDL's contract for this setting.
        var environment = base
        environment["SDL_QUIT_ON_LAST_WINDOW_CLOSE"] = "0"
        // SDL-FreeRDP contains a direct-bounds fallback intended for wlroots.
        // Our multi-monitor interposer also uses it for hidden 64x64 probe
        // windows. Never leak it into a normal single-monitor Retina session: it
        // replaces the real drawable pixel size with logical screen bounds.
        if useMonitorProbeFallback {
            environment["FREERDP_WLROOTS_HACK"] = "force"
        } else {
            environment.removeValue(forKey: "FREERDP_WLROOTS_HACK")
        }

        // Keep the normal macOS fullscreen menu available. Smart sizing now
        // adapts the complete Windows desktop to the real drawable area, so the
        // menu no longer pushes the remote taskbar below the screen.
        environment["SDL_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY"] = "1"
        environment["SDL_WINDOW_FRAME_USABLE_WHILE_CURSOR_HIDDEN"] = "1"

        // Community builds carry FreeRDP, SDL and their linked libraries in
        // Contents/Frameworks. Keep this path first for libraries opened at
        // runtime as well as those referenced directly by the Mach-O loader.
        if let frameworks = bundledSessionFrameworksURL() {
            environment["DYLD_LIBRARY_PATH"] = prependPath(
                frameworks.path,
                to: environment["DYLD_LIBRARY_PATH"]
            )

            // OpenSSL 3 implements MD4 in the loadable legacy provider.
            // FreeRDP requires it for NTLM/CredSSP. The provider's compiled-in
            // Homebrew path is not present on a recipient Mac, so portable
            // builds always resolve providers from the nested session bundle.
            let modules = frameworks.appendingPathComponent(
                "ossl-modules",
                isDirectory: true
            )
            let legacyProvider = modules.appendingPathComponent("legacy.dylib")
            if fileManager.fileExists(atPath: legacyProvider.path) {
                environment["OPENSSL_MODULES"] = modules.path
            }
        }

        // Homebrew's CA bundle is copied into portable builds. Do not replace
        // an explicitly supplied certificate location in development builds.
        if environment["SSL_CERT_FILE"] == nil,
           let certificateBundle = Bundle.main.url(
               forResource: "cacert",
               withExtension: "pem"
           ),
           fileManager.fileExists(atPath: certificateBundle.path) {
            environment["SSL_CERT_FILE"] = certificateBundle.path
        }
        return environment
    }

    func privacyPreflightEnvironment(
        from base: [String: String],
        profile: ConnectionProfile,
        preflightLibrary: URL?
    ) -> [String: String] {
        var environment = base
        environment.removeValue(forKey: "SELECTIVE_RDP_PREFLIGHT_MICROPHONE")
        environment.removeValue(forKey: "SELECTIVE_RDP_PREFLIGHT_CAMERA")

        let cameraEnabled = profile.redirectCamera && canRedirectCamera
        guard profile.redirectMicrophone || cameraEnabled,
              let preflightLibrary
        else { return environment }

        environment["DYLD_INSERT_LIBRARIES"] = prependPath(
            preflightLibrary.path,
            to: environment["DYLD_INSERT_LIBRARIES"]
        )
        if profile.redirectMicrophone {
            environment["SELECTIVE_RDP_PREFLIGHT_MICROPHONE"] = "1"
        }
        if cameraEnabled {
            environment["SELECTIVE_RDP_PREFLIGHT_CAMERA"] = "1"
        }
        return environment
    }

    func keyboardHotkeyEnvironment(
        from base: [String: String],
        profile: ConnectionProfile,
        shortcutModule: URL?,
        commandPipeURL: URL? = nil
    ) -> [String: String] {
        var environment = base
        environment.removeValue(forKey: "SELECTIVE_RDP_FN_LANGUAGE_SWITCH")
        environment.removeValue(forKey: "SELECTIVE_RDP_COMMAND_PIPE")
        environment.removeValue(forKey: "SELECTIVE_RDP_COMMAND_CONTROL")
        environment.removeValue(forKey: "SELECTIVE_RDP_RIGHT_COMMAND_WINDOWS")
        environment.removeValue(forKey: "SELECTIVE_RDP_RIGHT_COMMAND_CONTROL")
        environment.removeValue(forKey: "SELECTIVE_RDP_OPTION_WINDOWS")
        environment.removeValue(forKey: "SELECTIVE_RDP_DIRECT_WINDOWS_KEY")
        environment.removeValue(forKey: "SELECTIVE_RDP_CUSTOM_KEY_MAPPINGS")
        guard let shortcutModule else {
            return environment
        }

        environment["DYLD_INSERT_LIBRARIES"] = prependPath(
            shortcutModule.path,
            to: environment["DYLD_INSERT_LIBRARIES"]
        )
        if profile.fnSwitchesWindowsLanguage {
            environment["SELECTIVE_RDP_FN_LANGUAGE_SWITCH"] = "1"
        }
        if profile.mapCommandToControl && !profile.mapRightCommandToWindows {
            environment["SELECTIVE_RDP_RIGHT_COMMAND_CONTROL"] = "1"
        }
        if profile.mapCommandToControl && profile.mapOptionToWindows {
            // Both parser slots are occupied. Synthetic Windows commands use
            // Right GUI directly; only Left GUI is remapped to Control.
            environment["SELECTIVE_RDP_DIRECT_WINDOWS_KEY"] = "1"
        }
        let customMappings = profile.customKeyMappings
            .filter(\.isEnabled)
            .map { "\($0.source.rawValue)=\($0.target.rawValue)" }
        if !customMappings.isEmpty {
            environment["SELECTIVE_RDP_CUSTOM_KEY_MAPPINGS"] = customMappings.joined(separator: ";")
        }
        if let commandPipeURL {
            environment["SELECTIVE_RDP_COMMAND_PIPE"] = commandPipeURL.path
        }
        return environment
    }

    func keyboardRemapArgument(profile: ConnectionProfile) -> String {
        var rules: [String] = []
        if profile.mapCommandToControl {
            rules.append("remap:0x15b=0x1d")
        }
        if profile.mapOptionToWindows {
            rules.append("remap:0x38=0x15b")
        }
        if rules.count < 2 {
            // F24 is a private sentinel used by Fn and the RDP control panel.
            rules.append("remap:0x6f=0x15b")
        }
        return "/kbd:" + rules.joined(separator: ",")
    }

    func keyboardLaunchMarker(profile: ConnectionProfile) -> String {
        let command = profile.mapCommandToControl ? "Left Command→Ctrl" : "Command→Windows"
        let option = profile.mapOptionToWindows ? "Left Option→Windows" : "Option→Alt"
        let physicalRules = (profile.mapCommandToControl ? 1 : 0)
            + (profile.mapOptionToWindows ? 1 : 0)
        let remapCount = physicalRules + (physicalRules < 2 ? 1 : 0)
        return "[SelectiveRemote Host] Keyboard: \(command); \(option); "
            + "parser-safe remaps=\(remapCount)\n"
    }

    func accessibleRedirectedFolders(_ paths: [String]) -> [String] {
        paths.filter { path in
            guard !path.isEmpty else { return false }
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
                && fileManager.isReadableFile(atPath: path)
        }
    }

    func cameraConfigurationEnvironment(
        from base: [String: String],
        profile: ConnectionProfile
    ) -> [String: String] {
        let keys = [
            "SELECTIVE_RDP_CAMERA_SELECTION",
            "SELECTIVE_RDP_CAMERA_ID",
            "SELECTIVE_RDP_CAMERA_QUALITY",
            "SELECTIVE_RDP_CAMERA_MAX_WIDTH",
            "SELECTIVE_RDP_CAMERA_MAX_HEIGHT",
            "SELECTIVE_RDP_CAMERA_MAX_FPS",
            "SELECTIVE_RDP_CAMERA_MAX_BITRATE"
        ]
        var environment = base
        for key in keys {
            environment.removeValue(forKey: key)
        }
        guard profile.redirectCamera && canRedirectCamera else {
            return environment
        }

        environment["SELECTIVE_RDP_CAMERA_SELECTION"] =
            profile.cameraSelectionMode.rawValue
        environment["SELECTIVE_RDP_CAMERA_QUALITY"] = profile.cameraQuality.rawValue
        if profile.cameraSelectionMode == .specific,
           let deviceID = profile.cameraDeviceID,
           CameraDiscovery.isValidIdentifier(deviceID) {
            environment["SELECTIVE_RDP_CAMERA_ID"] = deviceID
        }
        if let width = profile.cameraQuality.maximumWidth {
            environment["SELECTIVE_RDP_CAMERA_MAX_WIDTH"] = String(width)
        }
        if let height = profile.cameraQuality.maximumHeight {
            environment["SELECTIVE_RDP_CAMERA_MAX_HEIGHT"] = String(height)
        }
        if let fps = profile.cameraQuality.maximumFramesPerSecond {
            environment["SELECTIVE_RDP_CAMERA_MAX_FPS"] = String(fps)
        }
        if let bitrate = profile.cameraQuality.maximumBitrate {
            environment["SELECTIVE_RDP_CAMERA_MAX_BITRATE"] = String(bitrate)
        }
        return environment
    }

    func cameraLaunchMarker(profile: ConnectionProfile) -> String {
        let source: String
        switch profile.cameraSelectionMode {
        case .builtIn:
            source = "built-in"
        case .automatic:
            source = "automatic"
        case .specific:
            let name = profile.cameraDeviceName ?? "unnamed"
            let id = profile.cameraDeviceID.flatMap {
                CameraDiscovery.isValidIdentifier($0) ? $0 : nil
            } ?? "invalid-or-missing-id"
            source = "specific name=\"\(sanitizedLogValue(name))\" id=\(id)"
        }
        return "[SelectiveRemote Host] Camera preference: \(source); "
            + "quality=\(profile.cameraQuality.rawValue); "
            + "\(profile.cameraQuality.details)\n"
    }

    func rdpQualityLaunchMarker(profile: ConnectionProfile) -> String {
        let network = profile.rdpQuality.freeRDPArgument ?? "FreeRDP default"
        return "[SelectiveRemote Host] RDP quality: \(profile.rdpQuality.rawValue); "
            + "network=\(network)\n"
    }

    func sessionWindowTitle(for profile: ConnectionProfile) -> String {
        let name = profile.friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? AppBrand.name : "\(AppBrand.name) — \(name)"
    }

    func localInputReleaseArguments() -> [String] {
        // Keep macOS shortcuts and the top screen edge available after the
        // user clicks inside the SDL window. Normal focused input still goes
        // to RDP; only exclusive keyboard/mouse capture is disabled.
        ["-grab-keyboard", "-grab-mouse"]
    }

    private func prependPath(_ path: String, to existing: String?) -> String {
        guard let existing, !existing.isEmpty else { return path }
        let components = existing.split(separator: ":").map(String.init)
        if components.contains(path) { return existing }
        return "\(path):\(existing)"
    }

    private func systemExecutableURL() throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/sdl-freerdp",
            "/usr/local/bin/sdl-freerdp"
        ]
        guard let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            throw FreeRDPError.executableNotFound
        }
        return URL(fileURLWithPath: path)
    }

    private func sessionExecutableURL() throws -> URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("Selective Remote Session.app", isDirectory: true)
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("SelectiveRemoteSession")
        if fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return try systemExecutableURL()
    }

    private func privacyPreflightURL() throws -> URL? {
        let sessionApp = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("Selective Remote Session.app", isDirectory: true)
        guard fileManager.fileExists(atPath: sessionApp.path) else {
            // `swift run` uses the system FreeRDP binary and has no packaged
            // preflight module. Production bundles always contain the module.
            return nil
        }

        let library = sessionApp
            .appendingPathComponent("Contents/Frameworks", isDirectory: true)
            .appendingPathComponent("SelectiveRemotePrivacyPreflight.dylib")
        guard fileManager.fileExists(atPath: library.path) else {
            throw FreeRDPError.privacyPreflightNotFound
        }
        return library
    }

    private func fnShortcutModuleURL() throws -> URL? {
        let sessionApp = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("Selective Remote Session.app", isDirectory: true)
        guard fileManager.fileExists(atPath: sessionApp.path) else {
            // Development through `swift run` uses the system FreeRDP binary.
            return nil
        }

        let library = sessionApp
            .appendingPathComponent("Contents/Frameworks", isDirectory: true)
            .appendingPathComponent("SelectiveRemoteFnShortcut.dylib")
        guard fileManager.fileExists(atPath: library.path) else {
            throw FreeRDPError.fnShortcutModuleNotFound
        }
        return library
    }

    private func bundledSessionFrameworksURL() -> URL? {
        let nested = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("Selective Remote Session.app", isDirectory: true)
            .appendingPathComponent("Contents/Frameworks", isDirectory: true)
        if fileManager.fileExists(atPath: nested.path) {
            return nested
        }
        // Compatibility with development and pre-0.5.1 package layouts.
        if let legacy = Bundle.main.privateFrameworksURL,
           fileManager.fileExists(atPath: legacy.path) {
            return legacy
        }
        return nil
    }

    private func makeLogURL(profileID: UUID) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("SelectiveRemote/Logs", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(
            "session-\(profileID.uuidString)-\(UUID().uuidString).log"
        )
    }

    private func monitorInterposerURL() throws -> URL {
        guard let frameworks = bundledSessionFrameworksURL() else {
            throw FreeRDPError.monitorInterposerNotFound
        }
        let url = frameworks.appendingPathComponent("SelectiveRemoteMonitorInterposer.dylib")
        guard fileManager.fileExists(atPath: url.path) else {
            throw FreeRDPError.monitorInterposerNotFound
        }
        return url
    }

    func parseMonitorList(_ text: String) -> [SDLMonitor] {
        let pattern = #"(?m)^\s*(\*)?\s*\[(\d+)\]\s*\[(.+?)\]\s*(\d+)x(\d+)\s*\+(-?\d+)\+(-?\d+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        return regex.matches(in: text, range: range).compactMap { match in
            func value(_ index: Int) -> String? {
                guard let range = Range(match.range(at: index), in: text) else { return nil }
                return String(text[range])
            }
            guard
                let idText = value(2), let id = Int(idText),
                let name = value(3),
                let widthText = value(4), let width = Int(widthText),
                let heightText = value(5), let height = Int(heightText),
                let xText = value(6), let x = Int(xText),
                let yText = value(7), let y = Int(yText)
            else { return nil }

            return SDLMonitor(
                id: id,
                name: name,
                width: width,
                height: height,
                x: x,
                y: y,
                isSystemPrimary: match.range(at: 1).location != NSNotFound
            )
        }
    }

    /// Some macOS builds of SDL-FreeRDP print a valid monitor list but still
    /// return a non-zero status. The listing is the useful result, so only
    /// treat the command as failed when its output cannot be parsed.
    func validatedMonitorList(_ text: String, terminationStatus: Int32) throws -> [SDLMonitor] {
        let monitors = parseMonitorList(text)
        if !monitors.isEmpty { return monitors }

        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if terminationStatus != 0, !message.isEmpty {
            throw FreeRDPError.monitorListFailed(message)
        }
        throw FreeRDPError.monitorListFailed("список пуст")
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizedLogValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
    }
}
