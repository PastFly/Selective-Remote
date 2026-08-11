# SelectiveRemote isolated RDPECAM addin

SelectiveRemote 0.8.3 and later build these sources as an isolated FreeRDP dynamic-channel
addin named `librdpecam-client` and embeds it in the nested
`SelectiveRemote Session.app`. The normal monitor interposer does not replace or
interpose FreeRDP's global channel loader.

The channel implements MS-RDPECAM. The protocol and channel state machine are
copied from FreeRDP tag `3.30.0` (commit
`cc741756e3a07fe1e5f4661a59b2e4e85f1a148f`) under Apache-2.0. The Apple HAL,
profile-driven camera/quality selection and direct linked-HAL call in
`camera_device_enum_main.c` are SelectiveRemote integration changes.

`AVFoundationCamera.mm` implements the FreeRDP camera HAL with AVFoundation for
built-in, external and Continuity macOS capture devices. The selected profile
passes only one physical camera to Windows. Fixed quality presets expose the
best supported format within their resolution/FPS limits and pass a target
bitrate to FreeRDP; automatic mode keeps normal RDPECAM negotiation. The HAL
supplies NV12 frames and lets FreeRDP perform protocol-required conversion and
encoding.

The build script:

1. detects FreeRDP's actual addin suffix and effective compiled addin path
   through the public FreeRDP API (without relying on private CMake macros);
2. compiles the channel and AVFoundation HAL into one dylib/module;
3. embeds all recursive dependencies in the helper bundle;
4. makes the Homebrew addin path portable without a global loader hook;
5. verifies the exported `DVCPluginEntry` and loads it through FreeRDP's real
   dynamic addin API before creating the DMG.

At runtime the Swift client adds `/dvc:rdpecam` only when the packaged addin is
present. macOS camera permission belongs to `SelectiveRemote Session`, which has
`NSCameraUsageDescription`, `NSCameraUseContinuityCameraDeviceType` and the
camera entitlement. The main app only discovers device names for its profile
picker; it never opens a capture stream.
