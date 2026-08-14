import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import SelectiveRemote

@Test("Несмежные физические дисплеи становятся соседними в RDP")
func compactsNonAdjacentDisplays() {
    let left = display("left", x: 0, width: 2560, height: 1440)
    let builtIn = display("built-in", x: 2560, width: 1728, height: 1117)
    let right = display("right", x: 4288, width: 2560, height: 1440)

    let result = VirtualTopologyMapper.compact(
        displays: [left, builtIn, right],
        selectedIDs: [left.id, right.id],
        primaryID: left.id
    )

    #expect(result.count == 2)
    #expect(result[0].virtualFrame == CGRect(x: 0, y: 0, width: 2560, height: 1440))
    #expect(result[1].virtualFrame == CGRect(x: 2560, y: 0, width: 2560, height: 1440))
    #expect(result[0].isPrimary)
    #expect(!result[1].isPrimary)
}

@Test("Основной дисплей всегда входит в выбранный набор")
func repairsMissingPrimary() {
    let first = display("first", x: 0, width: 1920, height: 1080)
    let second = display("second", x: 1920, width: 1920, height: 1080)

    let result = VirtualTopologyMapper.compact(
        displays: [first, second],
        selectedIDs: [second.id],
        primaryID: first.id
    )

    #expect(result.count == 1)
    #expect(result[0].id == second.id)
    #expect(result[0].isPrimary)
}

@Test("Единственный доступный монитор используется вместо старых UUID профиля")
func resolvesSingleDisplayFallback() {
    let builtIn = display("built-in", x: 0, width: 2056, height: 1329)
    var profile = ConnectionProfile()
    profile.selectedDisplayIDs = ["old-left", "old-right"]
    profile.primaryDisplayID = "old-left"
    profile.displayLayoutMode = .custom
    profile.virtualDisplayOrigins = [
        "old-left": VirtualDisplayPosition(x: 0, y: 0),
        "old-right": VirtualDisplayPosition(x: 2560, y: 0)
    ]

    let resolved = DisplaySelectionResolver.runtimeProfile(
        from: profile,
        displays: [builtIn]
    )

    #expect(resolved?.selectedDisplayIDs == [builtIn.id])
    #expect(resolved?.primaryDisplayID == builtIn.id)
    #expect(resolved?.displayLayoutMode == .automatic)
    #expect(resolved?.virtualDisplayOrigins.isEmpty == true)
    #expect(profile.selectedDisplayIDs == ["old-left", "old-right"])
}

@Test("Недоступные UUID не мешают запуску на доступном выбранном мониторе")
func filtersUnavailableDisplaysForRuntime() {
    let builtIn = display("built-in", x: 0, width: 2056, height: 1329)
    var profile = ConnectionProfile()
    profile.selectedDisplayIDs = [builtIn.id, "old-left", "old-right"]
    profile.primaryDisplayID = "old-left"

    let resolved = DisplaySelectionResolver.runtimeProfile(
        from: profile,
        displays: [builtIn]
    )

    #expect(resolved?.selectedDisplayIDs == [builtIn.id])
    #expect(resolved?.primaryDisplayID == builtIn.id)
}

@Test("Основной правый дисплей получает начало координат RDP")
func placesRightPrimaryAtOrigin() {
    let left = display("left", x: 0, width: 2560, height: 1440)
    let right = display("right", x: 5000, width: 2560, height: 1440)

    let result = VirtualTopologyMapper.compact(
        displays: [left, right],
        selectedIDs: [left.id, right.id],
        primaryID: right.id
    )

    #expect(result[0].virtualFrame.minX == -2560)
    #expect(result[1].virtualFrame.minX == 0)
    #expect(result[1].isPrimary)
}

@Test("Парсер читает реальные координаты SDL-FreeRDP на macOS")
func parsesSDLMonitorList() {
    let monitors = FreeRDPService().parseMonitorList(realSDLMonitorOutput)

    #expect(monitors.count == 3)
    #expect(monitors[0].id == 1)
    #expect(monitors[0].isSystemPrimary)
    #expect(monitors[1].id == 2)
    #expect(monitors[1].x == -2560)
    #expect(monitors[1].y == -111)
    #expect(monitors[2].name == "Mi Monitor")
}

@Test("Корректный список принимается даже при ненулевом коде SDL-FreeRDP")
func acceptsMonitorListDespiteNonzeroExit() throws {
    let monitors = try FreeRDPService().validatedMonitorList(
        realSDLMonitorOutput,
        terminationStatus: 1
    )

    #expect(monitors.map(\.id) == [1, 2, 3])
}

@Test("SDL-топология удаляет промежуточный невыбранный дисплей")
func compactsSDLMonitorGap() {
    let mappings = [
        SDLDisplayMapping(
            displayID: "left",
            monitor: sdlMonitor(id: 2, x: -2560, width: 2560)
        ),
        SDLDisplayMapping(
            displayID: "right",
            monitor: sdlMonitor(id: 3, x: 2056, width: 2560)
        )
    ]

    let result = SDLTopologyMapper.compact(mappings: mappings, primaryDisplayID: "left")

    #expect(result == [
        SDLMonitorPlacement(monitorID: 2, x: 0, y: 0, isPrimary: true),
        SDLMonitorPlacement(monitorID: 3, x: 2560, y: 0, isPrimary: false)
    ])
    #expect(SDLTopologyMapper.environmentValue(result) == "2:0:0:1;3:2560:0:0")
}

@Test("Основной правый SDL-дисплей идёт первым, а левый получает отрицательную координату")
func ordersPrimarySDLMonitorFirst() {
    let mappings = [
        SDLDisplayMapping(
            displayID: "left",
            monitor: sdlMonitor(id: 2, x: -2560, width: 2560)
        ),
        SDLDisplayMapping(
            displayID: "right",
            monitor: sdlMonitor(id: 3, x: 2056, width: 2560)
        )
    ]

    let result = SDLTopologyMapper.compact(mappings: mappings, primaryDisplayID: "right")

    #expect(result == [
        SDLMonitorPlacement(monitorID: 3, x: 0, y: 0, isPrimary: true),
        SDLMonitorPlacement(monitorID: 2, x: -2560, y: 0, isPrimary: false)
    ])
}

@Test("Аргументы и пароль передаются FreeRDP построчно через stdin")
func buildsSecureStdinArguments() throws {
    let payload = try FreeRDPService().argumentsFromStdinPayload(
        ["/v:pc.example.local", "/d:DOMAIN", "/u:user", "/multimon"],
        password: "secret"
    )

    #expect(
        String(data: payload, encoding: .utf8)
            == "/v:pc.example.local\n/d:DOMAIN\n/u:user\n/multimon\n/p:secret\n"
    )
}

@Test("Один fullscreen монитор использует нативный размер без smart-sizing")
func buildsNativeSingleMonitorFullscreenArguments() throws {
    var profile = ConnectionProfile()
    profile.host = "pc.example.local"

    let arguments = try FreeRDPService().connectionArguments(
        profile: profile,
        monitorIDs: nil,
        smartSizing: RDPDesktopSize(width: 2056, height: 1329)
    )

    #expect(arguments.contains("/f"))
    #expect(!arguments.contains(where: { $0.hasPrefix("/smart-sizing") }))
    #expect(!arguments.contains("/multimon"))
    #expect(!arguments.contains(where: { $0.hasPrefix("/monitors:") }))
}

@Test("Один выбранный монитор среди нескольких не включает multimon")
func buildsSelectedSingleMonitorFullscreenArguments() throws {
    var profile = ConnectionProfile()
    profile.host = "pc.example.local"

    let arguments = try FreeRDPService().connectionArguments(
        profile: profile,
        monitorIDs: [7],
        smartSizing: RDPDesktopSize(width: 2560, height: 1440)
    )

    #expect(arguments.contains("/f"))
    #expect(arguments.contains("/monitors:7"))
    #expect(!arguments.contains("/multimon"))
    #expect(!arguments.contains(where: { $0.hasPrefix("/smart-sizing") }))
}

@Test("Несколько выбранных fullscreen мониторов включают multimon")
func buildsTrueMultiMonitorFullscreenArguments() throws {
    var profile = ConnectionProfile()
    profile.host = "pc.example.local"

    let arguments = try FreeRDPService().connectionArguments(
        profile: profile,
        monitorIDs: [2, 4]
    )

    #expect(arguments.contains("/f"))
    #expect(arguments.contains("/multimon"))
    #expect(arguments.contains("/monitors:2,4"))
}

@Test("Оконный режим одного монитора не включает multimon")
func buildsNativeSingleMonitorWindowedArguments() throws {
    var profile = ConnectionProfile()
    profile.host = "pc.example.local"
    profile.startFullScreen = false

    let arguments = try FreeRDPService().connectionArguments(
        profile: profile,
        monitorIDs: nil,
        smartSizing: RDPDesktopSize(width: 2056, height: 1329)
    )

    #expect(!arguments.contains("/f"))
    #expect(!arguments.contains(where: { $0.hasPrefix("/smart-sizing:") }))
    #expect(!arguments.contains("/multimon"))
    #expect(!arguments.contains(where: { $0.hasPrefix("/monitors:") }))
}

@Test("Служебные окна SDL скрыты, а верхнее меню доступно в полном экране")
func configuresSDLSessionEnvironment() {
    let environment = FreeRDPService().launchEnvironment(from: ["KEEP": "value"])

    #expect(environment["SDL_QUIT_ON_LAST_WINDOW_CLOSE"] == "0")
    #expect(environment["FREERDP_WLROOTS_HACK"] == "force")
    #expect(environment["SDL_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY"] == "1")
    #expect(environment["SDL_WINDOW_FRAME_USABLE_WHILE_CURSOR_HIDDEN"] == "1")
    #expect(environment["KEEP"] == "value")
}

@Test("Боевой RDP-сеанс не использует глобальный wlroots fallback")
func keepsNativeRetinaDrawableSizeForSessionWindows() {
    let environment = FreeRDPService().launchEnvironment(
        from: [
            "KEEP": "value",
            "FREERDP_WLROOTS_HACK": "inherited"
        ],
        useMonitorProbeFallback: false
    )

    #expect(environment["FREERDP_WLROOTS_HACK"] == nil)
    #expect(environment["SDL_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY"] == "1")
    #expect(environment["SDL_WINDOW_FRAME_USABLE_WHILE_CURSOR_HIDDEN"] == "1")
    #expect(environment["KEEP"] == "value")
}

@Test("FreeRDP получает не более двух штатных remap")
func keepsFreeRDPKeyboardRemapWithinParserLimit() throws {
    var profile = ConnectionProfile()
    profile.host = "pc.example.local"

    let mapped = try FreeRDPService().connectionArguments(
        profile: profile,
        monitorIDs: nil
    )
    #expect(
        mapped.filter { $0.hasPrefix("/kbd:") }
            == ["/kbd:remap:0x15b=0x1d,remap:0x6f=0x15b"]
    )

    profile.mapCommandToControl = false
    profile.mapOptionToWindows = true
    profile.customKeyMappings = [
        RDPKeyMapping(source: .capsLock, target: .escape)
    ]
    let fnOnly = try FreeRDPService().connectionArguments(
        profile: profile,
        monitorIDs: nil
    )
    #expect(
        fnOnly.filter { $0.hasPrefix("/kbd:") }
            == ["/kbd:remap:0x38=0x15b,remap:0x6f=0x15b"]
    )

    profile.mapCommandToControl = true
    profile.fnSwitchesWindowsLanguage = false
    let panelOnly = try FreeRDPService().connectionArguments(
        profile: profile,
        monitorIDs: nil
    )
    #expect(
        panelOnly.filter { $0.hasPrefix("/kbd:") }
            == ["/kbd:remap:0x15b=0x1d,remap:0x38=0x15b"]
    )
}

@Test("Динамическое окно передаёт начальный размер и меняет разрешение при resize")
func buildsDynamicWindowArguments() throws {
    var profile = ConnectionProfile()
    profile.host = "pc.example.local"
    profile.startFullScreen = false
    profile.rdpWindowMode = .dynamicWindow
    profile.windowWidth = 1600
    profile.windowHeight = 1000

    let arguments = try FreeRDPService().connectionArguments(profile: profile, monitorIDs: nil)
    #expect(arguments.contains("/size:1600x1000"))
    #expect(arguments.contains("+dynamic-resolution"))
    #expect(!arguments.contains("/f"))
}

@Test("Fn подключает модуль очереди SDL без изменения модулей FreeRDP")
func configuresFnLanguageShortcut() {
    var profile = ConnectionProfile()
    profile.mapOptionToWindows = true
    profile.customKeyMappings = [
        RDPKeyMapping(source: .capsLock, target: .escape),
        RDPKeyMapping(source: .leftOption, target: .leftWindows, isEnabled: false)
    ]
    let module = URL(fileURLWithPath: "/Applications/SelectiveRemoteFnShortcut.dylib")
    let service = FreeRDPService()

    let enabled = service.keyboardHotkeyEnvironment(
        from: ["DYLD_INSERT_LIBRARIES": "/tmp/monitor.dylib"],
        profile: profile,
        shortcutModule: module
    )
    #expect(enabled["SELECTIVE_RDP_FN_LANGUAGE_SWITCH"] == "1")
    #expect(enabled["SELECTIVE_RDP_COMMAND_CONTROL"] == nil)
    #expect(enabled["SELECTIVE_RDP_RIGHT_COMMAND_WINDOWS"] == nil)
    #expect(enabled["SELECTIVE_RDP_OPTION_WINDOWS"] == nil)
    #expect(enabled["SELECTIVE_RDP_DIRECT_WINDOWS_KEY"] == "1")
    #expect(enabled["SELECTIVE_RDP_CUSTOM_KEY_MAPPINGS"] == "capsLock=escape")
    #expect(
        enabled["DYLD_INSERT_LIBRARIES"]
            == "\(module.path):/tmp/monitor.dylib"
    )

    profile.fnSwitchesWindowsLanguage = false
    let disabled = service.keyboardHotkeyEnvironment(
        from: [
            "DYLD_INSERT_LIBRARIES": "/tmp/monitor.dylib",
            "SELECTIVE_RDP_FN_LANGUAGE_SWITCH": "1"
        ],
        profile: profile,
        shortcutModule: module,
        commandPipeURL: URL(fileURLWithPath: "/tmp/rdp-control.fifo")
    )
    #expect(disabled["SELECTIVE_RDP_FN_LANGUAGE_SWITCH"] == nil)
    #expect(disabled["SELECTIVE_RDP_COMMAND_PIPE"] == "/tmp/rdp-control.fifo")
    #expect(disabled["DYLD_INSERT_LIBRARIES"] == "\(module.path):/tmp/monitor.dylib")
}

@Test("Микрофон и камера проверяются внутри SelectiveRemote Session до FreeRDP")
func configuresCapturePermissionPreflight() {
    var profile = ConnectionProfile()
    profile.redirectMicrophone = true
    profile.redirectCamera = true
    let library = URL(
        fileURLWithPath: "/Applications/SelectiveRemotePrivacyPreflight.dylib"
    )

    let environment = FreeRDPService(cameraRedirectionAvailable: true)
        .privacyPreflightEnvironment(
            from: ["DYLD_INSERT_LIBRARIES": "/tmp/monitor.dylib"],
            profile: profile,
            preflightLibrary: library
        )

    #expect(
        environment["DYLD_INSERT_LIBRARIES"]
            == "\(library.path):/tmp/monitor.dylib"
    )
    #expect(environment["SELECTIVE_RDP_PREFLIGHT_MICROPHONE"] == "1")
    #expect(environment["SELECTIVE_RDP_PREFLIGHT_CAMERA"] == "1")
}

@Test("Недоступный camera addin не запрашивает системное разрешение")
func omitsCameraPermissionPreflightWithoutAddin() {
    var profile = ConnectionProfile()
    profile.redirectCamera = true

    let environment = FreeRDPService(cameraRedirectionAvailable: false)
        .privacyPreflightEnvironment(
            from: [
                "SELECTIVE_RDP_PREFLIGHT_MICROPHONE": "1",
                "SELECTIVE_RDP_PREFLIGHT_CAMERA": "1"
            ],
            profile: profile,
            preflightLibrary: URL(fileURLWithPath: "/tmp/privacy.dylib")
        )

    #expect(environment["DYLD_INSERT_LIBRARIES"] == nil)
    #expect(environment["SELECTIVE_RDP_PREFLIGHT_MICROPHONE"] == nil)
    #expect(environment["SELECTIVE_RDP_PREFLIGHT_CAMERA"] == nil)
}

@Test("Выбранная камера и высокий пресет передаются только в RDPECAM-процесс")
func configuresSelectedCameraAndQuality() {
    var profile = ConnectionProfile()
    profile.redirectCamera = true
    profile.cameraSelectionMode = .specific
    profile.cameraDeviceID = "mac-0123456789abcdef"
    profile.cameraDeviceName = "USB Camera"
    profile.cameraQuality = .high

    let environment = FreeRDPService(cameraRedirectionAvailable: true)
        .cameraConfigurationEnvironment(
            from: ["KEEP": "value"],
            profile: profile
        )

    #expect(environment["KEEP"] == "value")
    #expect(environment["SELECTIVE_RDP_CAMERA_SELECTION"] == "specific")
    #expect(environment["SELECTIVE_RDP_CAMERA_ID"] == "mac-0123456789abcdef")
    #expect(environment["SELECTIVE_RDP_CAMERA_QUALITY"] == "high")
    #expect(environment["SELECTIVE_RDP_CAMERA_MAX_WIDTH"] == "1920")
    #expect(environment["SELECTIVE_RDP_CAMERA_MAX_HEIGHT"] == "1080")
    #expect(environment["SELECTIVE_RDP_CAMERA_MAX_FPS"] == "30")
    #expect(environment["SELECTIVE_RDP_CAMERA_MAX_BITRATE"] == "2700000")
}

@Test("Автоматическое качество удаляет унаследованные ограничения камеры")
func clearsInheritedCameraLimitsForAutomaticQuality() {
    var profile = ConnectionProfile()
    profile.redirectCamera = true
    profile.cameraSelectionMode = .automatic
    profile.cameraQuality = .automatic

    let environment = FreeRDPService(cameraRedirectionAvailable: true)
        .cameraConfigurationEnvironment(
            from: [
                "SELECTIVE_RDP_CAMERA_ID": "stale",
                "SELECTIVE_RDP_CAMERA_MAX_WIDTH": "640",
                "SELECTIVE_RDP_CAMERA_MAX_BITRATE": "1"
            ],
            profile: profile
        )

    #expect(environment["SELECTIVE_RDP_CAMERA_SELECTION"] == "automatic")
    #expect(environment["SELECTIVE_RDP_CAMERA_QUALITY"] == "automatic")
    #expect(environment["SELECTIVE_RDP_CAMERA_ID"] == nil)
    #expect(environment["SELECTIVE_RDP_CAMERA_MAX_WIDTH"] == nil)
    #expect(environment["SELECTIVE_RDP_CAMERA_MAX_BITRATE"] == nil)
}

@Test("Идентификатор камеры совпадает с FNV-1a RDPECAM-бэкенда")
func hashesCameraIdentifierConsistently() {
    #expect(
        CameraDiscovery.identifier(for: "FaceTime-HD-Camera-123")
            == "mac-cd22785ae3914993"
    )
    #expect(CameraDiscovery.isValidIdentifier("mac-cd22785ae3914993"))
    #expect(!CameraDiscovery.isValidIdentifier("mac-invalid\nvalue"))
}

@Test("Закрытие окна FreeRDP с кодом 131 считается штатным")
func acceptsSDLWindowCloseAsNormalExit() {
    let log = """
    ERRCONNECT_CONNECT_CANCELLED [0x0002000B]
    Connection aborted by user
    """

    #expect(SessionTerminationClassifier.isExpected(
        status: 131,
        log: log,
        disconnectRequested: false
    ))
    #expect(!SessionTerminationClassifier.isExpected(
        status: 131,
        log: "ERRCONNECT_CONNECT_CANCELLED [0x0002000B]",
        disconnectRequested: false
    ))
    #expect(!SessionTerminationClassifier.isExpected(
        status: 131,
        log: "ERRCONNECT_LOGON_FAILURE",
        disconnectRequested: false
    ))
}

@Test("Предупреждения запуска не выдаются за готовую RDP-сессию")
func detectsEstablishedRemoteDesktopFromLog() {
    let startupOnly = """
    [SelectiveRemote Host] Single-monitor fullscreen
    [WARN][com.freerdp.core.rdp] This build is using experimental build options
    """
    let connected = startupOnly + """

    [INFO][com.freerdp.gdi] Local framebuffer format PIXEL_FORMAT_BGRA32
    """

    #expect(!SessionLogClassifier.hasEstablishedDesktop(startupOnly))
    #expect(SessionLogClassifier.hasEstablishedDesktop(connected))
}

@Test("Окно RDP определяется независимо от буферизованного INFO-журнала")
func detectsRDPWindowWhenFreeRDPInfoIsBuffered() {
    let processID: Int32 = 18_196
    let sessionWindow: [String: Any] = [
        kCGWindowOwnerPID as String: NSNumber(value: processID),
        kCGWindowLayer as String: NSNumber(value: 0),
        kCGWindowAlpha as String: NSNumber(value: 1),
        kCGWindowBounds as String: [
            "Width": NSNumber(value: 2_056),
            "Height": NSNumber(value: 1_329)
        ] as NSDictionary
    ]
    let smallDialog: [String: Any] = [
        kCGWindowOwnerPID as String: NSNumber(value: processID),
        kCGWindowLayer as String: NSNumber(value: 0),
        kCGWindowAlpha as String: NSNumber(value: 1),
        kCGWindowBounds as String: [
            "Width": NSNumber(value: 420),
            "Height": NSNumber(value: 280)
        ] as NSDictionary
    ]
    let otherProcessWindow: [String: Any] = [
        kCGWindowOwnerPID as String: NSNumber(value: processID + 1),
        kCGWindowLayer as String: NSNumber(value: 0),
        kCGWindowAlpha as String: NSNumber(value: 1),
        kCGWindowBounds as String: [
            "Width": NSNumber(value: 2_056),
            "Height": NSNumber(value: 1_329)
        ] as NSDictionary
    ]

    #expect(SessionWindowDetector.hasSessionWindow(
        processIdentifier: processID,
        windows: [smallDialog, otherProcessWindow, sessionWindow]
    ))
    #expect(!SessionWindowDetector.hasSessionWindow(
        processIdentifier: processID,
        windows: [smallDialog, otherProcessWindow]
    ))
}

@Test("Отказ macOS в доступе к микрофону распознаётся по реальному логу")
func detectsMicrophonePermissionFailure() {
    let freeRDPLog = """
    [ERROR][com.freerdp.channels.audin.client] - [audin_mac_close]: not authorized
    ERRCONNECT_CONNECT_CANCELLED [0x0002000B]
    """
    let preflightLog = "[SelectiveRemote Privacy] denied microphone"

    #expect(
        SessionLogClassifier.deniedCapturePermission(freeRDPLog)
            == .microphone
    )
    #expect(
        SessionLogClassifier.deniedCapturePermission(preflightLog)
            == .microphone
    )

    let tccCrash = """
    [SelectiveRemote Privacy] requesting microphone
    [ERROR][com.freerdp.utils.signal.posix] - [fatal_handler]: Caught signal 'Abort trap: 6'
    __TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__
    """
    #expect(
        SessionLogClassifier.deniedCapturePermission(tccCrash)
            == .microphone
    )
}

@Test("Отказ macOS в доступе к камере распознаётся отдельно")
func detectsCameraPermissionFailure() {
    #expect(
        SessionLogClassifier.deniedCapturePermission(
            "[SelectiveRemote Privacy] restricted camera"
        ) == .camera
    )

    let tccCrash = """
    [SelectiveRemote Privacy] authorized microphone
    [SelectiveRemote Privacy] requesting camera
    __TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__
    """
    #expect(
        SessionLogClassifier.deniedCapturePermission(tccCrash)
            == .camera
    )
}

@Test("Ожидание privacy-диалога не считается зависанием FreeRDP")
func detectsPendingCapturePermission() {
    let pending = """
    [SelectiveRemote Privacy] authorized microphone
    [SelectiveRemote Privacy] requesting camera
    """
    let completed = pending + """

    [SelectiveRemote Privacy] granted camera
    [SelectiveRemote Privacy] ready capture
    """

    #expect(
        SessionLogClassifier.pendingCapturePermission(pending) == .camera
    )
    #expect(SessionLogClassifier.pendingCapturePermission(completed) == nil)
    #expect(
        SessionLogClassifier.hasCompletedCapturePermissionPreflight(completed)
    )
}

@Test("Отказ в камере и микрофоне завершает preflight, но отключает только каналы")
func treatsDeniedCapturePermissionsAsOptional() {
    let completed = """
    [SelectiveRemote Privacy] denied microphone
    [SelectiveRemote Privacy] disabled microphone
    [SelectiveRemote Privacy] restricted camera
    [SelectiveRemote Privacy] disabled camera
    [SelectiveRemote Privacy] ready capture
    """

    #expect(SessionLogClassifier.pendingCapturePermission(completed) == nil)
    #expect(SessionLogClassifier.hasCompletedCapturePermissionPreflight(completed))
    #expect(
        SessionLogClassifier.disabledCapturePermissions(completed)
            == [.microphone, .camera]
    )
}

@Test("Недоступные папки пропускаются без отмены RDP")
func skipsInaccessibleRedirectedFolders() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("SelectiveRemote-folder-test-\(UUID().uuidString)")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let missing = root.appendingPathComponent("missing")
    let service = FreeRDPService(fileManager: fileManager)

    #expect(
        service.accessibleRedirectedFolders([root.path, missing.path, ""])
            == [root.path]
    )

    var profile = ConnectionProfile()
    profile.host = "pc.example.local"
    profile.redirectedFolders = [missing.path, root.path]
    let arguments = try service.connectionArguments(profile: profile, monitorIDs: nil)
    #expect(arguments.contains("/drive:Folder1,\(root.path)"))
    #expect(!arguments.contains(where: { $0.contains(missing.path) }))
}

@Test("Статусы разрешений AVFoundation отображаются без потери состояний")
func mapsCapturePermissionStates() {
    #expect(
        CapturePermissionState(status: .notDetermined) == .notDetermined
    )
    #expect(CapturePermissionState(status: .authorized) == .authorized)
    #expect(CapturePermissionState(status: .denied) == .denied)
    #expect(CapturePermissionState(status: .restricted) == .restricted)
    #expect(
        CapturePermissionKind.camera.usageDescriptionKey
            == "NSCameraUsageDescription"
    )
    #expect(
        CapturePermissionKind.microphone.usageDescriptionKey
            == "NSMicrophoneUsageDescription"
    )
}

@Test("Качество профиля задаёт ожидаемое разрешение предпросмотра")
func mapsCameraQualityToPreviewPreset() {
    #expect(
        CameraQualityPreset.economy.previewSessionPreset == .vga640x480
    )
    #expect(
        CameraQualityPreset.balanced.previewSessionPreset == .hd1280x720
    )
    #expect(
        CameraQualityPreset.high.previewSessionPreset == .hd1920x1080
    )
    #expect(
        CameraQualityPreset.automatic.previewSessionPreset == .hd1920x1080
    )
}

@Test("Необъяснимый SIGTERM не скрывается как штатное завершение")
func reportsUnexpectedTerminationSignal() {
    #expect(!SessionTerminationClassifier.isExpected(
        status: 15,
        log: "FreeRDP startup",
        disconnectRequested: false
    ))
    #expect(SessionTerminationClassifier.isExpected(
        status: 15,
        log: "[SelectiveRemote Host] SIGTERM: Монитор отключён",
        disconnectRequested: false
    ))
}

@Test("Окно RDP получает новое имя бренда и название профиля")
func buildsSelectiveRemoteWindowTitle() {
    var profile = ConnectionProfile()
    profile.friendlyName = "Рабочий компьютер"

    #expect(
        FreeRDPService().sessionWindowTitle(for: profile)
            == "Selective Remote — Рабочий компьютер"
    )
}

@Test("RDP не захватывает системные клавиши и мышь монопольно")
func keepsLocalInputReleaseAvailable() {
    #expect(
        FreeRDPService().localInputReleaseArguments()
            == ["-grab-keyboard", "-grab-mouse"]
    )
}

@Test("Ручная схема сохраняет вертикальные и отрицательные координаты")
func appliesCustomVirtualTopology() {
    let left = display("left", x: 0, width: 2560, height: 1440)
    let primary = display("primary", x: 2560, width: 2056, height: 1329)
    let upper = display("upper", x: 4616, width: 1920, height: 1080)

    let result = VirtualTopologyMapper.layout(
        displays: [left, primary, upper],
        selectedIDs: [left.id, primary.id, upper.id],
        primaryID: primary.id,
        mode: .custom,
        customOrigins: [
            left.id: VirtualDisplayPosition(x: -2060, y: 300),
            primary.id: VirtualDisplayPosition(x: 500, y: 300),
            upper.id: VirtualDisplayPosition(x: 500, y: -780)
        ]
    )
    let frames = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0.virtualFrame) })

    #expect(frames[primary.id]?.origin == CGPoint(x: 0, y: 0))
    #expect(frames[left.id]?.origin == CGPoint(x: -2560, y: 0))
    #expect(frames[upper.id]?.origin == CGPoint(x: 0, y: -1080))
    #expect(!VirtualTopologyMapper.hasOverlaps(result))
}

@Test("Перекрывающиеся мониторы определяются до запуска RDP")
func detectsOverlappingVirtualDisplays() {
    let first = display("first", x: 0, width: 1920, height: 1080)
    let second = display("second", x: 1920, width: 1920, height: 1080)
    let result = VirtualTopologyMapper.layout(
        displays: [first, second],
        selectedIDs: [first.id, second.id],
        primaryID: first.id,
        mode: .custom,
        customOrigins: [
            first.id: VirtualDisplayPosition(x: 0, y: 0),
            second.id: VirtualDisplayPosition(x: 100, y: 100)
        ]
    )

    #expect(VirtualTopologyMapper.hasOverlaps(result))
}

@Test("Ручная SDL-схема нормализует перекрывающиеся координаты к смежным")
func normalizesCustomTopologyBeforeSDLFreeRDP() {
    let mappings = [
        SDLDisplayMapping(displayID: "primary", monitor: sdlMonitor(id: 7, x: 0, width: 2056)),
        SDLDisplayMapping(displayID: "upper", monitor: sdlMonitor(id: 9, x: 2056, width: 1920))
    ]
    let result = SDLTopologyMapper.arrange(
        mappings: mappings,
        primaryDisplayID: "primary",
        mode: .custom,
        customOrigins: [
            "primary": VirtualDisplayPosition(x: 0, y: 0),
            "upper": VirtualDisplayPosition(x: 0, y: -1080)
        ]
    )

    #expect(result == [
        SDLMonitorPlacement(monitorID: 7, x: 0, y: 0, isPrimary: true),
        SDLMonitorPlacement(monitorID: 9, x: 0, y: -1440, isPrimary: false)
    ])
}

@Test("Ручная SDL-схема автоматически закрывает микрозазор между мониторами")
func repairsCustomSDLMonitorGap() {
    let mappings = [
        SDLDisplayMapping(
            displayID: "primary",
            monitor: SDLMonitor(
                id: 2,
                name: "External",
                width: 1920,
                height: 1080,
                x: 0,
                y: 0,
                isSystemPrimary: true
            )
        ),
        SDLDisplayMapping(
            displayID: "retina",
            monitor: SDLMonitor(
                id: 1,
                name: "Built-in Retina",
                width: 2056,
                height: 1329,
                x: -2056,
                y: -20,
                isSystemPrimary: false
            )
        )
    ]

    let result = SDLTopologyMapper.arrange(
        mappings: mappings,
        primaryDisplayID: "primary",
        mode: .custom,
        customOrigins: [
            "primary": VirtualDisplayPosition(x: 0, y: 0),
            "retina": VirtualDisplayPosition(x: -2060, y: -20)
        ]
    )

    #expect(result == [
        SDLMonitorPlacement(
            monitorID: 2,
            x: 0,
            y: 0,
            isPrimary: true
        ),
        SDLMonitorPlacement(
            monitorID: 1,
            x: -2056,
            y: -20,
            isPrimary: false
        )
    ])
}

@Test("RDP true fullscreen сохраняет safe-area и нативную верхнюю панель macOS")
func keepsRDPInTrueFullscreenWithNativeTopEdge() throws {
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
    #expect(service.contains("SELECTIVE_RDP_FULLSCREEN_SAFE_TOP_IDS"))
    #expect(service.contains("SDL_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY"))
    #expect(interposer.contains("SDL_GetDisplayUsableBounds"))
    #expect(interposer.contains("fullscreen-safe"))
    #expect(!interposer.contains("exclusive fullscreen suppressed"))
}

@Test("Профиль 0.4.x мигрирует старый флаг буфера обмена")
func migratesLegacyClipboardFlag() throws {
    let data = Data(#"{"friendlyName":"Legacy","host":"server.local","redirectClipboard":false}"#.utf8)
    let profile = try JSONDecoder().decode(ConnectionProfile.self, from: data)

    #expect(profile.host == "server.local")
    #expect(profile.clipboardMode == .disabled)
    #expect(profile.windowsScale == .percent100)
    #expect(profile.displayLayoutMode == .automatic)
    #expect(profile.rdpQuality == .automatic)
    #expect(profile.cameraSelectionMode == .builtIn)
    #expect(profile.cameraQuality == .balanced)
    #expect(profile.mapCommandToControl)
    #expect(profile.mapRightCommandToWindows)
    #expect(profile.fnSwitchesWindowsLanguage)
    #expect(profile.rdpWindowMode == .fullScreen)
}

@Test("Архив SelectiveRemote переносит профили без паролей")
func roundTripsPasswordFreeProfileArchive() throws {
    var profile = ConnectionProfile()
    profile.friendlyName = "Work"
    profile.host = "work.example.local"
    profile.group = "Office"
    profile.windowsScale = .percent180
    profile.rdpQuality = .balanced
    profile.clipboardMode = .macToWindows
    profile.mapOptionToWindows = true
    profile.customKeyMappings = [
        RDPKeyMapping(source: .capsLock, target: .escape)
    ]
    profile.startFullScreen = false
    profile.rdpWindowMode = .dynamicWindow
    profile.windowWidth = 1680
    profile.windowHeight = 1050
    profile.redirectCamera = true
    profile.cameraSelectionMode = .specific
    profile.cameraDeviceID = "mac-0123456789abcdef"
    profile.cameraDeviceName = "Studio Camera"
    profile.cameraQuality = .economy
    profile.createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    let data = try SelectiveRemoteProfileCodec.encode([profile])
    let text = String(decoding: data, as: UTF8.self)
    let decoded = try SelectiveRemoteProfileCodec.decode(data)

    #expect(decoded == [profile])
    #expect(!text.lowercased().contains("password"))
}

@Test(".rdp импортирует масштаб, Gateway и буфер без паролей")
func roundTripsRDPFileWithoutPasswords() throws {
    var profile = ConnectionProfile()
    profile.host = "pc.example.local"
    profile.username = "DOMAIN\\user"
    profile.gatewayHost = "gateway.example.local"
    profile.gatewayUsername = "DOMAIN\\gateway-user"
    profile.windowsScale = .percent140
    profile.clipboardMode = .bidirectional
    profile.redirectMicrophone = true
    profile.redirectCamera = true

    let data = RDPFileCodec.encode(profile)
    let text = String(decoding: data, as: UTF8.self)
    let decoded = try RDPFileCodec.decode(data)

    #expect(decoded.host == profile.host)
    #expect(decoded.gatewayHost == profile.gatewayHost)
    #expect(decoded.gatewayUsername == profile.gatewayUsername)
    #expect(decoded.windowsScale == .percent140)
    #expect(decoded.clipboardMode == .bidirectional)
    #expect(decoded.redirectCamera)
    #expect(!text.lowercased().contains("password"))
}

@Test("Аргументы FreeRDP учитывают масштаб, направление clipboard и Gateway")
func buildsExtendedFreeRDPArguments() throws {
    var profile = ConnectionProfile()
    profile.host = "pc.example.local"
    profile.username = "EXAMPLE\\user"
    profile.gatewayHost = "gateway.example.local"
    profile.gatewayUsername = "EXAMPLE\\gateway-user"
    profile.windowsScale = .percent180
    profile.clipboardMode = .windowsToMac
    profile.redirectMicrophone = true
    profile.redirectCamera = true
    profile.redirectPrinters = true

    let arguments = try FreeRDPService(cameraRedirectionAvailable: true).connectionArguments(
        profile: profile,
        monitorIDs: [2, 4],
        gatewayPassword: "gateway-secret"
    )

    #expect(arguments.contains("/d:EXAMPLE"))
    #expect(arguments.contains("/u:user"))
    #expect(arguments.contains("/monitors:2,4"))
    #expect(arguments.contains("/scale:180"))
    #expect(arguments.contains("/clipboard:direction-to:local"))
    #expect(arguments.contains("/microphone"))
    #expect(arguments.contains("/dvc:rdpecam"))
    #expect(arguments.contains("/printer"))
    #expect(arguments.contains(
        "/gateway:g:gateway.example.local,u:EXAMPLE\\gateway-user,p:gateway-secret"
    ))
}

@Test("Профили качества RDP передаются штатным параметром сети FreeRDP")
func mapsRDPQualityPresetsToFreeRDPNetworkArguments() throws {
    let cases: [(RDPQualityPreset, String?)] = [
        (.automatic, nil),
        (.high, "/network:lan"),
        (.balanced, "/network:broadband-high"),
        (.economy, "/network:broadband-low")
    ]

    for (preset, expectedArgument) in cases {
        var profile = ConnectionProfile()
        profile.host = "pc.example.local"
        profile.rdpQuality = preset

        let arguments = try FreeRDPService().connectionArguments(
            profile: profile,
            monitorIDs: [0]
        )
        let networkArguments = arguments.filter { $0.hasPrefix("/network:") }

        if let expectedArgument {
            #expect(networkArguments == [expectedArgument])
        } else {
            #expect(networkArguments.isEmpty)
        }
    }
}

@Test("Журнал запуска фиксирует выбранный профиль качества RDP")
func logsSelectedRDPQualityPreset() {
    var profile = ConnectionProfile()
    profile.rdpQuality = .economy

    let marker = FreeRDPService().rdpQualityLaunchMarker(profile: profile)

    #expect(marker.contains("RDP quality: economy"))
    #expect(marker.contains("network=/network:broadband-low"))
}

@Test("Камера не включается без упакованного RDPECAM addin")
func omitsCameraArgumentWhenAddinIsMissing() throws {
    var profile = ConnectionProfile()
    profile.host = "pc.example.local"
    profile.redirectCamera = true

    let arguments = try FreeRDPService(cameraRedirectionAvailable: false).connectionArguments(
        profile: profile,
        monitorIDs: [0]
    )

    #expect(!arguments.contains("/dvc:rdpecam"))
}

@Test("Сопоставление мониторов не зависит от конкретных моделей")
func matchesPreviouslyUnknownMonitorModels() throws {
    let studio = namedDisplay(
        id: "studio",
        name: "Future UltraWide 8K",
        x: -3440,
        width: 3440,
        height: 1440
    )
    let portrait = namedDisplay(
        id: "portrait",
        name: "Acme Portrait Panel",
        x: 0,
        width: 1200,
        height: 1920
    )
    let monitors = [
        SDLMonitor(
            id: 17,
            name: "Future UltraWide 8K",
            width: 3440,
            height: 1440,
            x: -3440,
            y: 0,
            isSystemPrimary: false
        ),
        SDLMonitor(
            id: 23,
            name: "Acme Portrait Panel",
            width: 1200,
            height: 1920,
            x: 0,
            y: 0,
            isSystemPrimary: true
        )
    ]

    let result = try FreeRDPService().matchDisplays(
        [studio, portrait],
        to: monitors,
        allDisplays: [studio, portrait]
    )

    #expect(result.first(where: { $0.displayID == studio.id })?.monitor.id == 17)
    #expect(result.first(where: { $0.displayID == portrait.id })?.monitor.id == 23)
}

@Test("Проверка обновлений сравнивает версию и build")
func comparesUpdateVersions() {
    #expect(UpdateService.isNewer(
        candidateVersion: "0.5.1",
        candidateBuild: 1,
        currentVersion: "0.5.0",
        currentBuild: 20
    ))
    #expect(UpdateService.isNewer(
        candidateVersion: "0.5.0",
        candidateBuild: 21,
        currentVersion: "0.5.0",
        currentBuild: 20
    ))
    #expect(!UpdateService.isNewer(
        candidateVersion: "0.4.9",
        candidateBuild: 99,
        currentVersion: "0.5.0",
        currentBuild: 20
    ))
}

@Test("Обновление не предлагается на неподдерживаемой версии macOS")
func checksMinimumMacOSForUpdate() {
    let macOS15 = OperatingSystemVersion(
        majorVersion: 15,
        minorVersion: 6,
        patchVersion: 0
    )

    #expect(UpdateService.isMacOSSupported(minimumVersion: "15.0", currentVersion: macOS15))
    #expect(!UpdateService.isMacOSSupported(minimumVersion: "26.0", currentVersion: macOS15))
    #expect(UpdateService.isMacOSSupported(minimumVersion: nil, currentVersion: macOS15))
}

@Test("Полноэкранный переход не считается отключением монитора")
func ignoresTransientDisplayRemoval() {
    let removed = DisplaySnapshotStability.confirmedRemoved(
        previous: ["left", "built-in", "right"],
        first: ["built-in"],
        second: ["left", "built-in", "right"]
    )

    #expect(removed.isEmpty)
}

@Test("Физически отключённый монитор подтверждается двумя снимками")
func confirmsStableDisplayRemoval() {
    let removed = DisplaySnapshotStability.confirmedRemoved(
        previous: ["left", "built-in", "right"],
        first: ["left", "built-in"],
        second: ["left", "built-in"]
    )

    #expect(removed == ["right"])
}

@Test("Multimon Retina использует единый logical SDL backing")
func usesLogicalBackingForFullscreenAndMultimonWindows() throws {
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

    #expect(service.contains("fullscreenLogicalBacking"))
    #expect(service.contains("SELECTIVE_RDP_FORCE_LOGICAL_FULLSCREEN"))
    #expect(service.contains("logical 1x SDL backing"))

    #expect(interposer.contains("requestedFullscreen || requestedBorderless"))
    #expect(interposer.contains("SDL_PROP_WINDOW_CREATE_HIGH_PIXEL_DENSITY_BOOLEAN"))
    #expect(interposer.contains("Logical RDP backing active:"))
}

private let realSDLMonitorOutput = """
listing 3 monitors:
     * [1] [Built-in Retina Display] 2056x1329\t+0+0
       [2] [G27X Flex Pro] 2560x1440\t+-2560+-111
       [3] [Mi Monitor] 2560x1440\t+2056+-111
"""

private func sdlMonitor(id: Int, x: Int, width: Int) -> SDLMonitor {
    SDLMonitor(
        id: id,
        name: "monitor-\(id)",
        width: width,
        height: 1440,
        x: x,
        y: -111,
        isSystemPrimary: false
    )
}

private func display(_ id: String, x: CGFloat, width: Int, height: Int) -> DisplayDescriptor {
    DisplayDescriptor(
        id: id,
        systemID: 0,
        name: id,
        frame: CGRect(x: x, y: 0, width: CGFloat(width), height: CGFloat(height)),
        pixelWidth: width,
        pixelHeight: height,
        refreshRate: 60,
        isBuiltIn: id == "built-in",
        isSystemMain: id == "built-in"
    )
}

private func namedDisplay(
    id: String,
    name: String,
    x: CGFloat,
    width: Int,
    height: Int
) -> DisplayDescriptor {
    DisplayDescriptor(
        id: id,
        systemID: 0,
        name: name,
        frame: CGRect(x: x, y: 0, width: CGFloat(width), height: CGFloat(height)),
        pixelWidth: width,
        pixelHeight: height,
        refreshRate: 60,
        isBuiltIn: false,
        isSystemMain: x == 0
    )
}
