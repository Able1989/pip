#import "PipPlugin.h"

#import <UIKit/UIKit.h>

@interface PipPlugin ()

@property(nonatomic) FlutterMethodChannel *channel;

@property(nonatomic, strong) PipController *pipController;

@end

@implementation PipPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"pip"
                                  binaryMessenger:[registrar messenger]];
  PipPlugin *instance = [[PipPlugin alloc] init];

  instance.channel = channel;
  instance.pipController =
      [[PipController alloc] initWith:(id<PipStateChangedDelegate>)instance];

  [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call
                  result:(FlutterResult)result {
  if ([@"isSupported" isEqualToString:call.method]) {
    result([NSNumber numberWithBool:[self.pipController isSupported]]);
  } else if ([@"isAutoEnterSupported" isEqualToString:call.method]) {
    result([NSNumber numberWithBool:[self.pipController isAutoEnterSupported]]);
  } else if ([@"isActived" isEqualToString:call.method]) {
    result([NSNumber numberWithBool:[self.pipController isActived]]);
  } else if ([@"setup" isEqualToString:call.method]) {
    @autoreleasepool {
      // new options
      PipOptions *options = [[PipOptions alloc] init];

      // source content view
      if ([call.arguments objectForKey:@"sourceContentView"] &&
          [[call.arguments objectForKey:@"sourceContentView"]
              isKindOfClass:[NSNumber class]]) {
        options.sourceContentView = (__bridge UIView *)[[call.arguments
            objectForKey:@"sourceContentView"] pointerValue];
      }

      // content view
      if ([call.arguments objectForKey:@"contentView"] &&
          [[call.arguments objectForKey:@"contentView"]
              isKindOfClass:[NSNumber class]]) {
        options.contentView = (__bridge UIView *)[[call.arguments
            objectForKey:@"contentView"] pointerValue];
      }

      // auto enter
      if ([call.arguments objectForKey:@"autoEnterEnabled"]) {
        options.autoEnterEnabled =
            [[call.arguments objectForKey:@"autoEnterEnabled"] boolValue];
      }

      // preferred content size
      if ([call.arguments objectForKey:@"preferredContentWidth"] &&
          [call.arguments objectForKey:@"preferredContentHeight"]) {
        options.preferredContentSize = CGSizeMake(
            [[call.arguments objectForKey:@"preferredContentWidth"] floatValue],
            [[call.arguments objectForKey:@"preferredContentHeight"]
                floatValue]);
      }

      // control style
      if ([call.arguments objectForKey:@"controlStyle"]) {
        options.controlStyle =
            [[call.arguments objectForKey:@"controlStyle"] intValue];
      } else {
        // default to show all system controls
        options.controlStyle = 0;
      }

      id hostBg = [call.arguments objectForKey:@"iosPipHostBackgroundArgb"];
      if ([hostBg isKindOfClass:[NSNumber class]]) {
        options.iosPipHostBackgroundArgb = hostBg;
      }

      id transparentBuf =
          [call.arguments objectForKey:@"iosPipTransparentSampleBuffer"];
      if ([transparentBuf isKindOfClass:[NSNumber class]]) {
        options.iosPipTransparentSampleBuffer = [transparentBuf boolValue];
      }

      BOOL ok = [self.pipController setup:options];
      if (ok) {
        [self reportPipViewSizeToFlutter];
      }
      result([NSNumber numberWithBool:ok]);
    }
  } else if ([@"getPipView" isEqualToString:call.method]) {
    result([NSNumber
        numberWithUnsignedLongLong:(uint64_t)[self.pipController getPipView]]);
  } else if ([@"start" isEqualToString:call.method]) {
    result([NSNumber numberWithBool:[self.pipController start]]);
  } else if ([@"stop" isEqualToString:call.method]) {
    [self.pipController stop];
    result(nil);
  } else if ([@"dispose" isEqualToString:call.method]) {
    [self.pipController dispose];
    result(nil);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (void)pipStateChanged:(PipState)state error:(NSString *)error {
  NSDictionary *arguments = [[NSDictionary alloc]
      initWithObjectsAndKeys:[NSNumber numberWithLong:(long)state], @"state",
                             error, @"error", nil];
  [self.channel invokeMethod:@"stateChanged" arguments:arguments];
}

/// 下一帧再读 bounds，避免 Auto Layout 尚未完成时全为 0。
- (void)reportPipViewSizeToFlutter {
  dispatch_async(dispatch_get_main_queue(), ^{
    dispatch_async(dispatch_get_main_queue(), ^{
      UIView *pv = (UIView *)[self.pipController getPipView];
      if (pv == nil) {
        return;
      }
      CGRect b = pv.bounds;
      CGRect f = pv.frame;
      NSDictionary *args = @{
        @"width" : @(b.size.width),
        @"height" : @(b.size.height),
        @"frameWidth" : @(f.size.width),
        @"frameHeight" : @(f.size.height),
      };
      [self.channel invokeMethod:@"pipViewSizeDebug" arguments:args];
    });
  });
}

@end
