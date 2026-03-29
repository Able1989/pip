#import "PipView.h"

#import <AVFoundation/AVFoundation.h>
#include <string.h>

@interface PipView ()

@end

@implementation PipView

+ (Class)layerClass {
  return [AVSampleBufferDisplayLayer class];
}

- (AVSampleBufferDisplayLayer *)sampleBufferDisplayLayer {
  return (AVSampleBufferDisplayLayer *)self.layer;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    // 语音 PiP 需让 sample buffer 参与合成；透明度由像素 alpha 控制，不再整视图 alpha=0。
    self.alpha = 1.0;
    self.opaque = NO;
    self.sampleBufferDisplayLayer.opaque = NO;
  }
  return self;
}

- (void)updateFrameSize:(CGSize)frameSize
    transparentSampleBuffer:(BOOL)transparent {
  CMTimebaseRef timebase;
  CMTimebaseCreateWithSourceClock(nil, CMClockGetHostTimeClock(), &timebase);
  CMTimebaseSetTime(timebase, kCMTimeZero);
  CMTimebaseSetRate(timebase, 1);
  self.sampleBufferDisplayLayer.controlTimebase = timebase;
  self.sampleBufferDisplayLayer.opaque = NO;
  if (timebase) {
    CFRelease(timebase);
  }
  if (transparent) {
    self.backgroundColor = [UIColor clearColor];
  }

  CMSampleBufferRef sampleBuffer =
      [self makeSampleBufferWithFrameSize:frameSize transparent:transparent];
  if (sampleBuffer) {
    [self.sampleBufferDisplayLayer enqueueSampleBuffer:sampleBuffer];
    CFRelease(sampleBuffer);
  }
}

- (CMSampleBufferRef)makeSampleBufferWithFrameSize:(CGSize)frameSize
                                       transparent:(BOOL)transparent {
  size_t width = (size_t)frameSize.width;
  size_t height = (size_t)frameSize.height;

  CVPixelBufferRef pixelBuffer = NULL;
  CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_32BGRA,
                      (__bridge CFDictionaryRef)
                          @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}},
                      &pixelBuffer);
  CVPixelBufferLockBaseAddress(pixelBuffer, 0);
  void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
  size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
  if (transparent) {
    memset(base, 0, CVPixelBufferGetDataSize(pixelBuffer));
  } else {
    // kCVPixelFormatType_32BGRA：不透明白底（视频 PiP 等）。
    const uint32_t pixel = 0xFFFFFFFF;
    int *bytes = base;
    for (NSUInteger i = 0, length = height * bytesPerRow / 4; i < length;
         ++i) {
      bytes[i] = (int)pixel;
    }
  }
  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
  CMSampleBufferRef sampleBuffer =
      [self makeSampleBufferWithPixelBuffer:pixelBuffer];
  CVPixelBufferRelease(pixelBuffer);
  return sampleBuffer;
}

- (CMSampleBufferRef)makeSampleBufferWithPixelBuffer:
    (CVPixelBufferRef)pixelBuffer {
  CMSampleBufferRef sampleBuffer = NULL;
  OSStatus err = noErr;
  CMVideoFormatDescriptionRef formatDesc = NULL;
  err = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,
                                                     pixelBuffer, &formatDesc);

  if (err != noErr) {
    return nil;
  }

  CMSampleTimingInfo sampleTimingInfo = {
      .duration = CMTimeMakeWithSeconds(1, 600),
      .presentationTimeStamp =
          CMTimebaseGetTime(self.sampleBufferDisplayLayer.timebase),
      .decodeTimeStamp = kCMTimeInvalid};

  err = CMSampleBufferCreateReadyWithImageBuffer(
      kCFAllocatorDefault, pixelBuffer, formatDesc, &sampleTimingInfo,
      &sampleBuffer);

  if (err != noErr) {
    return nil;
  }

  CFRelease(formatDesc);

  return sampleBuffer;
}

@end