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
  // 占位 buffer 只需提供正确宽高比，不需要与 preferredContentSize 等大。
  // 将最长边缩到 4px 保持比例，大幅减少内存分配和像素填充耗时。
  CGFloat maxEdge = MAX(frameSize.width, frameSize.height);
  CGFloat scale = (maxEdge > 4.0) ? (4.0 / maxEdge) : 1.0;
  size_t width = MAX(1, (size_t)(frameSize.width * scale));
  size_t height = MAX(1, (size_t)(frameSize.height * scale));

  CVPixelBufferRef pixelBuffer = NULL;
  CVReturn cvRet =
      CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_32BGRA,
                          (__bridge CFDictionaryRef)
                              @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}},
                          &pixelBuffer);
  if (cvRet != kCVReturnSuccess || pixelBuffer == NULL) {
    return NULL;
  }
  CVPixelBufferLockBaseAddress(pixelBuffer, 0);
  void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
  if (base == NULL) {
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    CVPixelBufferRelease(pixelBuffer);
    return NULL;
  }
  if (transparent) {
    memset(base, 0, CVPixelBufferGetDataSize(pixelBuffer));
  } else {
    memset(base, 0xFF, CVPixelBufferGetDataSize(pixelBuffer));
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

  CFRelease(formatDesc);

  if (err != noErr) {
    return nil;
  }

  return sampleBuffer;
}

@end