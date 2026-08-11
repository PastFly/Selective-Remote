#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#include <SDL3/SDL.h>
#include <dispatch/dispatch.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

static const long kPermissionTimeoutSeconds = 120;

static bool environmentFlagEnabled(const char* name)
{
    const char* value = getenv(name);
    return value && (strcmp(value, "1") == 0 || strcasecmp(value, "true") == 0);
}

static void writeMarker(const char* state, const char* permission)
{
    fprintf(stderr, "[SelectiveRemote Privacy] %s %s\n", state, permission);
    fflush(stderr);
}

static bool requestPermission(AVMediaType mediaType, const char* permission)
{
    AVAuthorizationStatus status =
        [AVCaptureDevice authorizationStatusForMediaType:mediaType];

    switch (status)
    {
        case AVAuthorizationStatusAuthorized:
            writeMarker("authorized", permission);
            return true;
        case AVAuthorizationStatusDenied:
            writeMarker("denied", permission);
            return false;
        case AVAuthorizationStatusRestricted:
            writeMarker("restricted", permission);
            return false;
        case AVAuthorizationStatusNotDetermined:
            break;
        default:
            writeMarker("unknown", permission);
            return false;
    }

    writeMarker("requesting", permission);
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block BOOL granted = NO;
    [AVCaptureDevice requestAccessForMediaType:mediaType
                             completionHandler:^(BOOL accessGranted) {
        granted = accessGranted;
        dispatch_semaphore_signal(completed);
    }];

    const dispatch_time_t deadline = dispatch_time(
        DISPATCH_TIME_NOW,
        kPermissionTimeoutSeconds * NSEC_PER_SEC
    );
    if (dispatch_semaphore_wait(completed, deadline) != 0)
    {
        writeMarker("timeout", permission);
        return false;
    }

    writeMarker(granted ? "granted" : "denied", permission);
    return granted;
}

static void runRequestedPrivacyPreflight(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @autoreleasepool
        {
            const bool microphone = environmentFlagEnabled(
                "SELECTIVE_RDP_PREFLIGHT_MICROPHONE"
            );
            const bool camera = environmentFlagEnabled(
                "SELECTIVE_RDP_PREFLIGHT_CAMERA"
            );
            if (!microphone && !camera)
                return;

            if (microphone && !requestPermission(AVMediaTypeAudio, "microphone"))
                writeMarker("disabled", "microphone");
            if (camera && !requestPermission(AVMediaTypeVideo, "camera"))
                writeMarker("disabled", "camera");

            // Camera, microphone and their macOS permissions are optional RDP
            // channels. A refusal disables only that channel; it must never
            // terminate the desktop session itself.
            writeMarker("ready", "capture");
        }
    });
}

bool selective_SDL_Init(SDL_InitFlags flags)
{
    const bool initialized = SDL_Init(flags);
    if (initialized)
        runRequestedPrivacyPreflight();
    return initialized;
}

bool selective_SDL_InitSubSystem(SDL_InitFlags flags)
{
    const bool initialized = SDL_InitSubSystem(flags);
    if (initialized)
        runRequestedPrivacyPreflight();
    return initialized;
}

// Inject into the real SelectiveRemote Session process, but wait until SDL has
// initialized AppKit before asking AVFoundation. This avoids doing asynchronous
// privacy work under dyld's initializer lock and gives the TCC permission to the
// exact nested app that later opens the microphone/camera.
#define SELECTIVE_DYLD_INTERPOSE(replacement, replacee)                                  \
    __attribute__((used)) static struct                                                   \
    {                                                                                     \
        const void* replacement;                                                          \
        const void* replacee;                                                             \
    } _selective_privacy_interpose_##replacee                                             \
        __attribute__((section("__DATA,__interpose"))) = {                               \
            (const void*)(uintptr_t)&replacement,                                         \
            (const void*)(uintptr_t)&replacee                                             \
        };

SELECTIVE_DYLD_INTERPOSE(selective_SDL_Init, SDL_Init)
SELECTIVE_DYLD_INTERPOSE(selective_SDL_InitSubSystem, SDL_InitSubSystem)
