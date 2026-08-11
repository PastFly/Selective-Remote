#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <iterator>
#include <limits>
#include <string>
#include <vector>

#include <winpr/assert.h>
#include <winpr/wlog.h>

#include "FreeRDP/camera.h"

#define TAG CHANNELS_TAG("rdpecam-avfoundation.client")

namespace
{
constexpr OSType kCapturePixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;

std::string cameraIdentifier(NSString* uniqueID)
{
    const char* bytes = uniqueID.UTF8String ?: "unknown-camera";
    std::uint64_t hash = 1469598103934665603ULL;
    for (const unsigned char* current = reinterpret_cast<const unsigned char*>(bytes);
         *current;
         ++current)
    {
        hash ^= *current;
        hash *= 1099511628211ULL;
    }

    char result[32] = {};
    std::snprintf(result, sizeof(result), "mac-%016llx", static_cast<unsigned long long>(hash));
    return result;
}

BOOL waitForCameraAuthorization()
{
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo])
    {
        case AVAuthorizationStatusAuthorized:
            return YES;
        case AVAuthorizationStatusDenied:
        case AVAuthorizationStatusRestricted:
            return NO;
        case AVAuthorizationStatusNotDetermined:
            break;
        default:
            return NO;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block BOOL granted = NO;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                             completionHandler:^(BOOL allowed) {
                                 granted = allowed;
                                 dispatch_semaphore_signal(semaphore);
                             }];

    const dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 120LL * NSEC_PER_SEC);
    if (dispatch_semaphore_wait(semaphore, timeout) != 0)
    {
        WLog_ERR(TAG, "Timed out while waiting for macOS camera permission");
        return NO;
    }
    return granted;
}

std::uint32_t environmentUnsignedInteger(NSString* key)
{
    NSString* value = NSProcessInfo.processInfo.environment[key];
    if (!value || value.length == 0)
        return 0;

    NSScanner* scanner = [NSScanner scannerWithString:value];
    unsigned long long parsed = 0;
    if (![scanner scanUnsignedLongLong:&parsed] || !scanner.isAtEnd ||
        (parsed > std::numeric_limits<std::uint32_t>::max()))
        return 0;
    return static_cast<std::uint32_t>(parsed);
}

NSArray<AVCaptureDevice*>* availableCameraDevices()
{
    AVCaptureDeviceDiscoverySession* discovery =
        [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[
                AVCaptureDeviceTypeBuiltInWideAngleCamera,
                AVCaptureDeviceTypeExternal,
                AVCaptureDeviceTypeContinuityCamera
            ]
                             mediaType:AVMediaTypeVideo
                              position:AVCaptureDevicePositionUnspecified];
    return discovery.devices;
}

BOOL isBuiltInCamera(AVCaptureDevice* device)
{
    return [device.deviceType isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera];
}

const char* cameraKind(AVCaptureDevice* device)
{
    if (isBuiltInCamera(device))
        return "built-in";
    if ([device.deviceType isEqualToString:AVCaptureDeviceTypeContinuityCamera])
        return "continuity";
    return "external";
}

double preferredFrameRate(AVCaptureDeviceFormat* format, double maximumFPS)
{
    const double target = maximumFPS > 0 ? maximumFPS : 30.0;
    double bestBelowTarget = 0;
    double bestAboveTarget = std::numeric_limits<double>::max();
    for (AVFrameRateRange* range in format.videoSupportedFrameRateRanges)
    {
        if ((range.minFrameRate <= target) && (range.maxFrameRate >= target))
            return target;
        if (range.maxFrameRate < target)
            bestBelowTarget = std::max(bestBelowTarget, range.maxFrameRate);
        if (range.minFrameRate > target)
            bestAboveTarget = std::min(bestAboveTarget, range.minFrameRate);
    }
    if (bestBelowTarget > 0)
        return bestBelowTarget;
    if (bestAboveTarget < std::numeric_limits<double>::max())
        return bestAboveTarget;
    return 0;
}

BOOL supportsFrameRate(AVCaptureDeviceFormat* format, double requested)
{
    for (AVFrameRateRange* range in format.videoSupportedFrameRateRanges)
    {
        if ((range.minFrameRate <= requested) && (range.maxFrameRate >= requested))
            return YES;
    }
    return NO;
}

struct CameraResolution
{
    std::uint32_t width;
    std::uint32_t height;
    std::uint32_t framesPerSecond;
};

int resolutionPreference(const CameraResolution& resolution)
{
    if ((resolution.width == 1280) && (resolution.height == 720))
        return 0;
    if ((resolution.width == 1920) && (resolution.height == 1080))
        return 1;
    if ((resolution.width == 640) && (resolution.height == 480))
        return 2;
    if ((resolution.width == 960) && (resolution.height == 540))
        return 3;
    return 10 + static_cast<int>(resolution.width * resolution.height / 100000);
}
}

@interface SelectiveRemoteCameraCapture : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

@property(atomic, assign) BOOL running;
@property(nonatomic, strong) AVCaptureSession* session;
@property(nonatomic, strong) AVCaptureVideoDataOutput* output;
@property(nonatomic, strong) NSMutableData* frameBuffer;
@property(nonatomic, strong) dispatch_queue_t sampleQueue;
@property(nonatomic, assign) CameraDevice* remoteDevice;
@property(nonatomic, assign) size_t streamIndex;
@property(nonatomic, assign) ICamHalSampleCapturedCallback sampleCallback;
@property(nonatomic, assign) std::uint32_t expectedWidth;
@property(nonatomic, assign) std::uint32_t expectedHeight;

- (BOOL)startWithDevice:(AVCaptureDevice*)device
              mediaType:(const CAM_MEDIA_TYPE_DESCRIPTION*)mediaType
            remoteDevice:(CameraDevice*)remoteDevice
             streamIndex:(size_t)streamIndex
                callback:(ICamHalSampleCapturedCallback)callback;
- (void)stop;

@end

@implementation SelectiveRemoteCameraCapture

- (BOOL)configureDevice:(AVCaptureDevice*)device
               mediaType:(const CAM_MEDIA_TYPE_DESCRIPTION*)mediaType
                    error:(NSError**)error
{
    AVCaptureDeviceFormat* selected = nil;
    const double requestedFPS = static_cast<double>(mediaType->FrameRateNumerator) /
                                static_cast<double>(mediaType->FrameRateDenominator);

    for (AVCaptureDeviceFormat* format in device.formats)
    {
        const CMVideoDimensions dimensions =
            CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        if ((dimensions.width != static_cast<int32_t>(mediaType->Width)) ||
            (dimensions.height != static_cast<int32_t>(mediaType->Height)))
            continue;

        if (!selected)
            selected = format;
        if (supportsFrameRate(format, requestedFPS))
        {
            selected = format;
            break;
        }
    }

    if (!selected)
    {
        WLog_ERR(TAG, "Requested camera resolution %ux%u is unavailable", mediaType->Width,
                 mediaType->Height);
        return NO;
    }

    if (![device lockForConfiguration:error])
        return NO;

    device.activeFormat = selected;
    if (!supportsFrameRate(selected, requestedFPS))
    {
        [device unlockForConfiguration];
        WLog_ERR(TAG, "Requested camera frame rate %.3f is unavailable", requestedFPS);
        return NO;
    }
    const CMTime duration = CMTimeMake(
        static_cast<int64_t>(mediaType->FrameRateDenominator),
        static_cast<int32_t>(mediaType->FrameRateNumerator)
    );
    device.activeVideoMinFrameDuration = duration;
    device.activeVideoMaxFrameDuration = duration;
    [device unlockForConfiguration];
    return YES;
}

- (BOOL)startWithDevice:(AVCaptureDevice*)device
              mediaType:(const CAM_MEDIA_TYPE_DESCRIPTION*)mediaType
            remoteDevice:(CameraDevice*)remoteDevice
             streamIndex:(size_t)streamIndex
                callback:(ICamHalSampleCapturedCallback)callback
{
    if (!device || !mediaType || !remoteDevice || !callback)
        return NO;
    if (!waitForCameraAuthorization())
    {
        WLog_ERR(TAG, "macOS denied camera access to SelectiveRemote Session");
        return NO;
    }

    NSError* error = nil;
    AVCaptureDeviceInput* input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input)
    {
        WLog_ERR(TAG, "Unable to open camera: %s", error.localizedDescription.UTF8String ?: "unknown");
        return NO;
    }

    AVCaptureSession* session = [[AVCaptureSession alloc] init];
    [session beginConfiguration];
    if (![session canAddInput:input])
    {
        [session commitConfiguration];
        WLog_ERR(TAG, "AVFoundation refused the selected camera input");
        return NO;
    }
    [session addInput:input];

    if (![self configureDevice:device mediaType:mediaType error:&error])
    {
        [session commitConfiguration];
        WLog_ERR(TAG, "Unable to configure camera: %s", error.localizedDescription.UTF8String ?: "unknown");
        return NO;
    }

    AVCaptureVideoDataOutput* output = [[AVCaptureVideoDataOutput alloc] init];
    output.alwaysDiscardsLateVideoFrames = YES;
    output.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCapturePixelFormat) };
    if (![session canAddOutput:output])
    {
        [session commitConfiguration];
        WLog_ERR(TAG, "AVFoundation refused the NV12 camera output");
        return NO;
    }
    [session addOutput:output];

    self.remoteDevice = remoteDevice;
    self.streamIndex = streamIndex;
    self.sampleCallback = callback;
    self.expectedWidth = mediaType->Width;
    self.expectedHeight = mediaType->Height;
    self.frameBuffer = [NSMutableData
        dataWithLength:static_cast<NSUInteger>(
            mediaType->Width * mediaType->Height * 3ULL / 2ULL
        )];
    if (!self.frameBuffer)
    {
        [session commitConfiguration];
        WLog_ERR(TAG, "Unable to allocate the reusable NV12 camera buffer");
        return NO;
    }
    self.sampleQueue = dispatch_queue_create("local.selectiveremote.camera.frames", DISPATCH_QUEUE_SERIAL);
    [output setSampleBufferDelegate:self queue:self.sampleQueue];
    [session commitConfiguration];

    self.output = output;
    self.session = session;
    self.running = YES;
    [session startRunning];
    if (!session.isRunning)
    {
        WLog_ERR(TAG, "AVFoundation camera session did not start");
        [self stop];
        return NO;
    }

    const std::string identifier = cameraIdentifier(device.uniqueID);
    WLog_INFO(
        TAG,
        "Camera started: id=%s name=\"%s\" %ux%u @ %u/%u fps",
        identifier.c_str(),
        device.localizedName.UTF8String ?: "Unnamed camera",
        mediaType->Width,
        mediaType->Height,
        mediaType->FrameRateNumerator,
        mediaType->FrameRateDenominator
    );
    return YES;
}

- (void)stop
{
    self.running = NO;
    [self.output setSampleBufferDelegate:nil queue:nullptr];
    if (self.session.isRunning)
        [self.session stopRunning];
    self.output = nil;
    self.session = nil;
    self.frameBuffer = nil;
    self.sampleQueue = nil;
    self.remoteDevice = nullptr;
    self.sampleCallback = nullptr;
}

- (void)captureOutput:(AVCaptureOutput*)captureOutput
 didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        fromConnection:(AVCaptureConnection*)connection
{
    (void)captureOutput;
    (void)connection;
    if (!self.running || !self.remoteDevice || !self.sampleCallback)
        return;

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer)
        return;

    const OSType pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
    if ((pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) &&
        (pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        return;

    const size_t width = CVPixelBufferGetWidth(imageBuffer);
    const size_t height = CVPixelBufferGetHeight(imageBuffer);
    if ((width != self.expectedWidth) || (height != self.expectedHeight) ||
        (CVPixelBufferGetPlaneCount(imageBuffer) != 2))
        return;

    if (CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
        return;

    NSMutableData* frameBuffer = self.frameBuffer;
    const size_t frameSize = width * height + width * (height / 2);
    if (!frameBuffer || frameBuffer.length != frameSize)
    {
        CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
        return;
    }
    BYTE* destination = static_cast<BYTE*>(frameBuffer.mutableBytes);

    const BYTE* luma = static_cast<const BYTE*>(CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0));
    const size_t lumaStride = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0);
    for (size_t row = 0; row < height; ++row)
    {
        std::memcpy(destination, luma + row * lumaStride, width);
        destination += width;
    }

    const BYTE* chroma = static_cast<const BYTE*>(CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 1));
    const size_t chromaStride = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 1);
    for (size_t row = 0; row < height / 2; ++row)
    {
        std::memcpy(destination, chroma + row * chromaStride, width);
        destination += width;
    }

    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    self.sampleCallback(
        self.remoteDevice,
        self.streamIndex,
        static_cast<const BYTE*>(frameBuffer.bytes),
        frameBuffer.length
    );
}

@end

@interface SelectiveRemoteCameraManager : NSObject

@property(nonatomic, strong) NSMutableDictionary<NSString*, AVCaptureDevice*>* devices;
@property(nonatomic, strong) NSMutableDictionary<NSString*, SelectiveRemoteCameraCapture*>* captures;
@property(nonatomic, strong) NSMutableSet<NSString*>* loggedDeviceIDs;
@property(nonatomic, copy) NSString* selectionMode;
@property(nonatomic, copy) NSString* preferredDeviceID;
@property(nonatomic, copy) NSString* quality;
@property(nonatomic, assign) std::uint32_t maximumWidth;
@property(nonatomic, assign) std::uint32_t maximumHeight;
@property(nonatomic, assign) std::uint32_t maximumFramesPerSecond;
- (void)refreshDevices;
- (AVCaptureDevice*)selectedDevice;

@end


@implementation SelectiveRemoteCameraManager

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _devices = [[NSMutableDictionary alloc] init];
        _captures = [[NSMutableDictionary alloc] init];
        _loggedDeviceIDs = [[NSMutableSet alloc] init];
        NSDictionary<NSString*, NSString*>* environment = NSProcessInfo.processInfo.environment;
        _selectionMode = environment[@"SELECTIVE_RDP_CAMERA_SELECTION"] ?: @"builtIn";
        if (![_selectionMode isEqualToString:@"builtIn"] &&
            ![_selectionMode isEqualToString:@"automatic"] &&
            ![_selectionMode isEqualToString:@"specific"])
            _selectionMode = @"builtIn";
        _preferredDeviceID = environment[@"SELECTIVE_RDP_CAMERA_ID"] ?: @"";
        _quality = environment[@"SELECTIVE_RDP_CAMERA_QUALITY"] ?: @"automatic";
        _maximumWidth = environmentUnsignedInteger(@"SELECTIVE_RDP_CAMERA_MAX_WIDTH");
        _maximumHeight = environmentUnsignedInteger(@"SELECTIVE_RDP_CAMERA_MAX_HEIGHT");
        _maximumFramesPerSecond =
            environmentUnsignedInteger(@"SELECTIVE_RDP_CAMERA_MAX_FPS");
        [self refreshDevices];
    }
    return self;
}

- (void)refreshDevices
{
    @synchronized(self)
    {
        [self.devices removeAllObjects];
        for (AVCaptureDevice* device in availableCameraDevices())
        {
            const std::string identifier = cameraIdentifier(device.uniqueID);
            NSString* key = [NSString stringWithUTF8String:identifier.c_str()];
            if (key)
            {
                self.devices[key] = device;
                if (![self.loggedDeviceIDs containsObject:key])
                {
                    [self.loggedDeviceIDs addObject:key];
                    WLog_INFO(
                        TAG,
                        "Discovered camera: id=%s name=\"%s\" type=%s",
                        identifier.c_str(),
                        device.localizedName.UTF8String ?: "Unnamed camera",
                        cameraKind(device)
                    );
                }
            }
        }
    }
}

- (AVCaptureDevice*)selectedDevice
{
    @synchronized(self)
    {
        NSArray<AVCaptureDevice*>* ordered = [self.devices.allValues
            sortedArrayUsingComparator:^NSComparisonResult(
                id lhsValue,
                id rhsValue
            ) {
                AVCaptureDevice* lhs = (AVCaptureDevice*)lhsValue;
                AVCaptureDevice* rhs = (AVCaptureDevice*)rhsValue;
                if (isBuiltInCamera(lhs) != isBuiltInCamera(rhs))
                    return isBuiltInCamera(lhs) ? NSOrderedAscending : NSOrderedDescending;
                const NSComparisonResult nameOrder =
                    [lhs.localizedName localizedCaseInsensitiveCompare:rhs.localizedName];
                if (nameOrder != NSOrderedSame)
                    return nameOrder;
                return [lhs.uniqueID compare:rhs.uniqueID];
            }];
        if (ordered.count == 0)
            return nil;

        AVCaptureDevice* builtIn = nil;
        for (AVCaptureDevice* device in ordered)
        {
            if (isBuiltInCamera(device))
            {
                builtIn = device;
                break;
            }
        }

        AVCaptureDevice* selected = nil;
        NSString* reason = self.selectionMode;
        if ([self.selectionMode isEqualToString:@"specific"] &&
            self.preferredDeviceID.length > 0)
        {
            selected = self.devices[self.preferredDeviceID];
            if (!selected)
            {
                WLog_WARN(
                    TAG,
                    "Preferred camera %s is unavailable; falling back to built-in/system camera",
                    self.preferredDeviceID.UTF8String
                );
                reason = @"specific-fallback";
            }
        }
        else if ([self.selectionMode isEqualToString:@"automatic"])
        {
            AVCaptureDevice* system = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
            if (system)
            {
                const std::string identifier = cameraIdentifier(system.uniqueID);
                NSString* key = [NSString stringWithUTF8String:identifier.c_str()];
                selected = key ? self.devices[key] : nil;
            }
            if (!selected)
                reason = @"automatic-fallback";
        }
        else
        {
            selected = builtIn;
            if (!selected)
                reason = @"builtIn-fallback";
        }

        if (!selected)
            selected = builtIn;
        if (!selected)
        {
            AVCaptureDevice* system = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
            if (system)
            {
                const std::string identifier = cameraIdentifier(system.uniqueID);
                NSString* key = [NSString stringWithUTF8String:identifier.c_str()];
                selected = key ? self.devices[key] : nil;
            }
        }
        if (!selected)
            selected = ordered.firstObject;

        const std::string identifier = cameraIdentifier(selected.uniqueID);
        WLog_INFO(
            TAG,
            "Selected camera: id=%s name=\"%s\" type=%s mode=%s quality=%s",
            identifier.c_str(),
            selected.localizedName.UTF8String ?: "Unnamed camera",
            cameraKind(selected),
            reason.UTF8String,
            self.quality.UTF8String
        );
        return selected;
    }
}

@end


typedef struct
{
    ICamHal iHal;
    void* manager;
} CamAVFoundationHal;

static SelectiveRemoteCameraManager* cameraManager(CamAVFoundationHal* hal)
{
    return (__bridge SelectiveRemoteCameraManager*)hal->manager;
}

static AVCaptureDevice* cameraDevice(CamAVFoundationHal* hal, const char* deviceId)
{
    if (!hal || !deviceId)
        return nil;
    NSString* key = [NSString stringWithUTF8String:deviceId];
    if (!key)
        return nil;
    SelectiveRemoteCameraManager* manager = cameraManager(hal);
    @synchronized(manager)
    {
        AVCaptureDevice* device = manager.devices[key];
        if (!device)
        {
            [manager refreshDevices];
            device = manager.devices[key];
        }
        return device;
    }
}

static UINT cam_avfoundation_enumerate(ICamHal* ihal, ICamHalEnumCallback callback,
                                       CameraPlugin* ecam, GENERIC_CHANNEL_CALLBACK* hchannel)
{
    CamAVFoundationHal* hal = reinterpret_cast<CamAVFoundationHal*>(ihal);
    SelectiveRemoteCameraManager* manager = cameraManager(hal);
    [manager refreshDevices];

    AVCaptureDevice* device = [manager selectedDevice];
    if (!device)
    {
        WLog_ERR(TAG, "No macOS camera is available for RDPECAM");
        return 0;
    }

    const std::string identifier = cameraIdentifier(device.uniqueID);
    const char* deviceName = device.localizedName.UTF8String ?: "macOS Camera";
    IFCALL(callback, ecam, hchannel, identifier.c_str(), deviceName);
    WLog_INFO(
        TAG,
        "Enumerated 1 selected macOS camera (available=%zu)",
        static_cast<size_t>(manager.devices.count)
    );
    return 1;
}

static BOOL cam_avfoundation_activate(ICamHal* ihal, const char* deviceId,
                                      CAM_ERROR_CODE* errorCode)
{
    CamAVFoundationHal* hal = reinterpret_cast<CamAVFoundationHal*>(ihal);
    const BOOL found = cameraDevice(hal, deviceId) != nil;
    *errorCode = found ? CAM_ERROR_CODE_None : CAM_ERROR_CODE_ItemNotFound;
    return found;
}

static BOOL cam_avfoundation_deactivate(ICamHal* ihal, const char* deviceId,
                                        CAM_ERROR_CODE* errorCode)
{
    (void)ihal;
    (void)deviceId;
    *errorCode = CAM_ERROR_CODE_None;
    return TRUE;
}

static INT16 cam_avfoundation_get_media_types(
    ICamHal* ihal,
    const char* deviceId,
    size_t streamIndex,
    const CAM_MEDIA_FORMAT_INFO* supportedFormats,
    size_t nSupportedFormats,
    CAM_MEDIA_TYPE_DESCRIPTION* mediaTypes,
    size_t* nMediaTypes)
{
    (void)streamIndex;
    CamAVFoundationHal* hal = reinterpret_cast<CamAVFoundationHal*>(ihal);
    AVCaptureDevice* device = cameraDevice(hal, deviceId);
    if (!device || !supportedFormats || !mediaTypes || !nMediaTypes)
        return -1;

    size_t formatIndex = 0;
    for (; formatIndex < nSupportedFormats; ++formatIndex)
    {
        if (supportedFormats[formatIndex].inputFormat == CAM_MEDIA_FORMAT_NV12)
            break;
    }
    if (formatIndex >= nSupportedFormats || formatIndex > INT16_MAX)
        return -1;

    std::vector<CameraResolution> resolutions;
    SelectiveRemoteCameraManager* manager = cameraManager(hal);
    const double maximumFPS = static_cast<double>(manager.maximumFramesPerSecond);
    for (AVCaptureDeviceFormat* format in device.formats)
    {
        const CMVideoDimensions dimensions =
            CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        if ((dimensions.width <= 0) || (dimensions.height <= 0) ||
            (dimensions.width > 1920) || (dimensions.height > 1080))
            continue;

        const double selectedFPS = preferredFrameRate(format, maximumFPS);
        if (selectedFPS < 1)
            continue;

        CameraResolution candidate = {
            static_cast<std::uint32_t>(dimensions.width),
            static_cast<std::uint32_t>(dimensions.height),
            static_cast<std::uint32_t>(std::max(1.0, std::floor(selectedFPS)))
        };
        const auto existing = std::find_if(
            resolutions.begin(),
            resolutions.end(),
            [&](const CameraResolution& current) {
                return (current.width == candidate.width) && (current.height == candidate.height);
            }
        );
        if (existing == resolutions.end())
            resolutions.emplace_back(candidate);
        else
            existing->framesPerSecond = std::max(existing->framesPerSecond, candidate.framesPerSecond);
    }

    if ((manager.maximumWidth > 0) && (manager.maximumHeight > 0) &&
        !resolutions.empty())
    {
        std::vector<CameraResolution> withinPreset;
        std::copy_if(
            resolutions.begin(),
            resolutions.end(),
            std::back_inserter(withinPreset),
            [&](const CameraResolution& resolution) {
                return (resolution.width <= manager.maximumWidth) &&
                       (resolution.height <= manager.maximumHeight);
            }
        );

        CameraResolution selected = {};
        if (!withinPreset.empty())
        {
            selected = *std::max_element(
                withinPreset.begin(),
                withinPreset.end(),
                [](const CameraResolution& lhs, const CameraResolution& rhs) {
                    const std::uint64_t lhsPixels =
                        static_cast<std::uint64_t>(lhs.width) * lhs.height;
                    const std::uint64_t rhsPixels =
                        static_cast<std::uint64_t>(rhs.width) * rhs.height;
                    if (lhsPixels != rhsPixels)
                        return lhsPixels < rhsPixels;
                    return lhs.framesPerSecond < rhs.framesPerSecond;
                }
            );
        }
        else
        {
            selected = *std::min_element(
                resolutions.begin(),
                resolutions.end(),
                [](const CameraResolution& lhs, const CameraResolution& rhs) {
                    const std::uint64_t lhsPixels =
                        static_cast<std::uint64_t>(lhs.width) * lhs.height;
                    const std::uint64_t rhsPixels =
                        static_cast<std::uint64_t>(rhs.width) * rhs.height;
                    return lhsPixels < rhsPixels;
                }
            );
            WLog_WARN(
                TAG,
                "Camera does not expose a format within %ux%u; using %ux%u",
                manager.maximumWidth,
                manager.maximumHeight,
                selected.width,
                selected.height
            );
        }
        resolutions.assign(1, selected);
    }

    std::sort(resolutions.begin(), resolutions.end(), [](const auto& lhs, const auto& rhs) {
        const int lhsPreference = resolutionPreference(lhs);
        const int rhsPreference = resolutionPreference(rhs);
        if (lhsPreference != rhsPreference)
            return lhsPreference < rhsPreference;
        return (lhs.width * lhs.height) < (rhs.width * rhs.height);
    });

    const size_t capacity = *nMediaTypes;
    const size_t count = std::min(capacity, resolutions.size());
    for (size_t index = 0; index < count; ++index)
    {
        mediaTypes[index].Format = CAM_MEDIA_FORMAT_NV12;
        mediaTypes[index].Width = resolutions[index].width;
        mediaTypes[index].Height = resolutions[index].height;
        mediaTypes[index].FrameRateNumerator = resolutions[index].framesPerSecond;
        mediaTypes[index].FrameRateDenominator = 1;
        mediaTypes[index].PixelAspectRatioNumerator = 1;
        mediaTypes[index].PixelAspectRatioDenominator = 1;
        mediaTypes[index].Flags = AM_MEDIA_TYPE_DESCRIPTION_FLAG_Invalid;
    }
    *nMediaTypes = count;
    WLog_INFO(
        TAG,
        "Camera %s exposes %zu compatible media type(s) for quality=%s",
        deviceId,
        count,
        manager.quality.UTF8String
    );
    return count > 0 ? static_cast<INT16>(formatIndex) : -1;
}

static CAM_ERROR_CODE cam_avfoundation_start(ICamHal* ihal, CameraDevice* dev,
                                              size_t streamIndex,
                                              const CAM_MEDIA_TYPE_DESCRIPTION* mediaType,
                                              ICamHalSampleCapturedCallback callback)
{
    CamAVFoundationHal* hal = reinterpret_cast<CamAVFoundationHal*>(ihal);
    AVCaptureDevice* device = cameraDevice(hal, dev ? dev->deviceId : nullptr);
    if (!device)
        return CAM_ERROR_CODE_ItemNotFound;

    NSString* key = [NSString stringWithUTF8String:dev->deviceId];
    SelectiveRemoteCameraManager* manager = cameraManager(hal);
    @synchronized(manager)
    {
        SelectiveRemoteCameraCapture* previous = manager.captures[key];
        if (previous)
        {
            [previous stop];
            [manager.captures removeObjectForKey:key];
        }

        SelectiveRemoteCameraCapture* capture = [[SelectiveRemoteCameraCapture alloc] init];
        if (![capture startWithDevice:device
                           mediaType:mediaType
                         remoteDevice:dev
                          streamIndex:streamIndex
                             callback:callback])
            return CAM_ERROR_CODE_UnexpectedError;
        manager.captures[key] = capture;
    }
    return CAM_ERROR_CODE_None;
}

static CAM_ERROR_CODE cam_avfoundation_stop(ICamHal* ihal, const char* deviceId,
                                             size_t streamIndex)
{
    (void)streamIndex;
    CamAVFoundationHal* hal = reinterpret_cast<CamAVFoundationHal*>(ihal);
    if (!hal || !deviceId)
        return CAM_ERROR_CODE_NotInitialized;

    NSString* key = [NSString stringWithUTF8String:deviceId];
    SelectiveRemoteCameraManager* manager = cameraManager(hal);
    @synchronized(manager)
    {
        SelectiveRemoteCameraCapture* capture = manager.captures[key];
        if (!capture)
            return CAM_ERROR_CODE_NotInitialized;
        [capture stop];
        [manager.captures removeObjectForKey:key];
    }
    return CAM_ERROR_CODE_None;
}

static CAM_ERROR_CODE cam_avfoundation_free(ICamHal* ihal)
{
    CamAVFoundationHal* hal = reinterpret_cast<CamAVFoundationHal*>(ihal);
    if (!hal)
        return CAM_ERROR_CODE_NotInitialized;

    SelectiveRemoteCameraManager* manager = cameraManager(hal);
    @synchronized(manager)
    {
        for (SelectiveRemoteCameraCapture* capture in manager.captures.allValues)
            [capture stop];
        [manager.captures removeAllObjects];
    }
    CFBridgingRelease(hal->manager);
    hal->manager = nullptr;
    std::free(hal);
    return CAM_ERROR_CODE_None;
}

extern "C" UINT VCAPITYPE avfoundation_freerdp_rdpecam_client_subsystem_entry(
    PFREERDP_CAMERA_HAL_ENTRY_POINTS entryPoints)
{
    if (!entryPoints || !entryPoints->pRegisterCameraHal)
        return ERROR_INVALID_PARAMETER;

    CamAVFoundationHal* hal = static_cast<CamAVFoundationHal*>(std::calloc(1, sizeof(*hal)));
    if (!hal)
        return CHANNEL_RC_NO_MEMORY;

    hal->iHal.Enumerate = cam_avfoundation_enumerate;
    hal->iHal.Activate = cam_avfoundation_activate;
    hal->iHal.Deactivate = cam_avfoundation_deactivate;
    hal->iHal.GetMediaTypeDescriptions = cam_avfoundation_get_media_types;
    hal->iHal.StartStream = cam_avfoundation_start;
    hal->iHal.StopStream = cam_avfoundation_stop;
    hal->iHal.Free = cam_avfoundation_free;
    hal->manager = (__bridge_retained void*)[[SelectiveRemoteCameraManager alloc] init];

    const UINT result = entryPoints->pRegisterCameraHal(entryPoints->plugin, &hal->iHal);
    if (result != CHANNEL_RC_OK)
    {
        cam_avfoundation_free(&hal->iHal);
        return result;
    }
    WLog_INFO(TAG, "Registered SelectiveRemote AVFoundation camera backend");
    return CHANNEL_RC_OK;
}
