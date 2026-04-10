#import "PipController.h"
#import "PipView.h"
#include <Foundation/Foundation.h>
#include <objc/objc.h>

#import <AVKit/AVKit.h>
#import <UIKit/UIKit.h>

// 始终打日志，便于真机连 Xcode / Console 排查 PiP 窗口与捏合模拟（上线前若嫌多可改回仅 DEBUG）。
#define PIP_LOG(fmt, ...)                                                      \
  NSLog((@"[PIP] %s L%d " fmt), __func__, __LINE__, ##__VA_ARGS__)

#define USE_PIP_VIEW_CONTROLLER 0

/// 覆盖 `preferredContentSize`，避免仅写属性在部分系统版本上被忽略（参考 Apple 视频通话 PiP 文档与社区实践）。
API_AVAILABLE(ios(15.0))
@interface RtcPipVideoCallContentViewController
    : AVPictureInPictureVideoCallViewController
@property(nonatomic, assign) CGSize rtcPipPreferredContentSize;
/// 语音 PiP：系统在 PiP 期间常把根 view 刷成不透明白/黑，需在布局周期反复拉回透明。
@property(nonatomic, assign) BOOL rtcForceTransparentHost;
- (void)rtc_refreshTransparentHostIfNeeded;
@end

@implementation RtcPipVideoCallContentViewController

- (CGSize)preferredContentSize {
  CGSize s = self.rtcPipPreferredContentSize;
  if (s.width < 1.0 || s.height < 1.0) {
    return CGSizeMake(80.0, 80.0);
  }
  return s;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  [self rtc_refreshTransparentHostIfNeeded];
}

- (void)viewWillLayoutSubviews {
  [super viewWillLayoutSubviews];
  [self rtc_refreshTransparentHostIfNeeded];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  [self rtc_refreshTransparentHostIfNeeded];
}

- (void)rtc_refreshTransparentHostIfNeeded {
  if (!self.rtcForceTransparentHost) {
    return;
  }
  UIView *v = self.view;
  v.backgroundColor = [UIColor clearColor];
  v.opaque = NO;
  CALayer *l = v.layer;
  l.opaque = NO;
  l.backgroundColor = [[UIColor clearColor] CGColor];
}

@end

@implementation PipOptions {
}
@end

static void RtcApplyPipHostBackground(UIView *view, NSNumber *argb) {
  if (view == nil) {
    return;
  }
  if (argb == nil) {
    view.backgroundColor = [UIColor clearColor];
    view.opaque = NO;
    return;
  }
  uint32_t c = (uint32_t)[argb unsignedLongValue];
  CGFloat a = ((c >> 24) & 0xFF) / 255.0;
  CGFloat r = ((c >> 16) & 0xFF) / 255.0;
  CGFloat g = ((c >> 8) & 0xFF) / 255.0;
  CGFloat b = (c & 0xFF) / 255.0;
  view.backgroundColor = [UIColor colorWithRed:r green:g blue:b alpha:a];
  view.opaque = (a >= 0.999);
}

@interface PipController () <AVPictureInPictureControllerDelegate>

// delegate
@property(nonatomic, weak) id<PipStateChangedDelegate> pipStateDelegate;

/// 最近一次 setup 传入的宿主背景，PiP 启动后系统可能重置，需在 didStart 再刷一层。
@property(nonatomic, strong, nullable) NSNumber *savedIosPipHostBackgroundArgb;

/// YES = 视频通话，NO = 语音通话；用于 PiP 启动后调整宽高比与尺寸。
@property(nonatomic, assign) BOOL savedIsVideoCall;

// is actived
@property(atomic, assign) BOOL isPipActived;

#pragma mark - content view
// content view
@property(nonatomic, assign) UIView *contentView;

// content view original index
@property(nonatomic, assign) NSUInteger contentViewOriginalIndex;

// content view original frame
@property(nonatomic, assign) CGRect contentViewOriginalFrame;

// content view original constraints
@property(nonatomic, strong) NSMutableArray *contentViewOriginalConstraints;

// content view original translatesAutoresizingMaskIntoConstraints
@property(nonatomic, assign)
    bool contentViewOriginalTranslatesAutoresizingMaskIntoConstraints;

// content view original parent view
@property(nonatomic, assign) UIView *contentViewOriginalParentView;

// content view original parent view constraints
@property(nonatomic, strong)
    NSMutableArray *contentViewOriginalParentViewConstraints;

#pragma mark - pip view
/// 视频：即 PipView；语音：透明全屏 UIView + 角上极小 PipView（满足系统对 sample buffer 层的要求，又避免整屏黑底）。
@property(nonatomic, strong) UIView *pipBackdropView;

// pip controller
@property(nonatomic, strong) AVPictureInPictureController *pipController;

/// iOS 15+ 视频通话 PiP：`preferredContentSize` 影响系统小窗比例与尺寸。
@property(nonatomic, strong) RtcPipVideoCallContentViewController
    *pipVideoCallViewController;

#if USE_PIP_VIEW_CONTROLLER
// Do not use this anymore, it is dangerous to use it and do not have the best
// user experience(we have to call bringToFront in didStart which make the
// truely pip view not visible for a while ).
// pip view controller, weak reference
@property(nonatomic) UIViewController *pipViewController;
#endif

@end

/// 旧版 Xcode 的 UIKit 未声明 `setNeedsUpdateOfPreferredContentSize`，不能直接发消息。
/// 运行时按名字调用：仅在 iOS 16+ 且系统实现存在时生效。
static void RtcPipNotifyPreferredContentSizeChanged(
    RtcPipVideoCallContentViewController *_Nullable vc) API_AVAILABLE(ios(15.0)) {
  if (vc == nil) {
    return;
  }
  if (@available(iOS 16.0, *)) {
    SEL sel = NSSelectorFromString(@"setNeedsUpdateOfPreferredContentSize");
    UIViewController *uiVc = (UIViewController *)vc;
    if ([uiVc respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      [uiVc performSelector:sel];
#pragma clang diagnostic pop
    }
  }
}

/// 视频 9:16。语音 1:1：用较小但非退化的点数（48×48）表达正方形，避免 (1,1) 在部分系统上被当成无效，
/// 同时给系统一个「内容尺幅偏小」的提示；真正最小化仍依赖用户捏合或下方 pinch 模拟（后者在真机上不可靠）。
static CGSize RtcPipAspectPreferredSize(BOOL isVideoCall) {
  return isVideoCall ? CGSizeMake(9.0, 16.0) : CGSizeMake(48.0, 48.0);
}

/// 语音 PiP：底层全透明 UIView，避免整屏 AVSampleBufferDisplayLayer 被合成成大块黑底；
/// 角上保留极小透明 PipView，满足视频通话 PiP 对 sample buffer 子层的要求。
static void RtcInstallPipBackdrop(UIView *hostView, CGSize pref,
                                  PipOptions *options,
                                  UIView *__strong *outSlot) {
  if (*outSlot != nil) {
    [*outSlot removeFromSuperview];
    *outSlot = nil;
  }

  UIView *root = nil;

  if (options.iosPipTransparentSampleBuffer) {
    UIView *stack = [[UIView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.backgroundColor = [UIColor clearColor];
    stack.opaque = NO;
    stack.userInteractionEnabled = NO;

    PipView *tinyTrack = [[PipView alloc] init];
    tinyTrack.translatesAutoresizingMaskIntoConstraints = NO;
    tinyTrack.userInteractionEnabled = NO;
    tinyTrack.alpha = 0.01;
    [tinyTrack updateFrameSize:CGSizeMake(16, 16)
        transparentSampleBuffer:YES];

    UIView *fill = [[UIView alloc] init];
    fill.translatesAutoresizingMaskIntoConstraints = NO;
    fill.backgroundColor = [UIColor clearColor];
    fill.opaque = NO;
    fill.userInteractionEnabled = NO;

    [stack addSubview:tinyTrack];
    [stack addSubview:fill];

    [NSLayoutConstraint activateConstraints:@[
      [tinyTrack.widthAnchor constraintEqualToConstant:16],
      [tinyTrack.heightAnchor constraintEqualToConstant:16],
      [tinyTrack.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor],
      [tinyTrack.topAnchor constraintEqualToAnchor:stack.topAnchor],
      [fill.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor],
      [fill.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor],
      [fill.topAnchor constraintEqualToAnchor:stack.topAnchor],
      [fill.bottomAnchor constraintEqualToAnchor:stack.bottomAnchor],
    ]];

    root = stack;
  } else {
    PipView *pv = [[PipView alloc] init];
    pv.translatesAutoresizingMaskIntoConstraints = NO;
    [pv updateFrameSize:pref transparentSampleBuffer:NO];
    root = pv;
  }

  root.translatesAutoresizingMaskIntoConstraints = NO;
  UIView *cv = (UIView *)options.contentView;
  if (cv != nil && [hostView.subviews containsObject:cv]) {
    [hostView insertSubview:root belowSubview:cv];
  } else {
    [hostView addSubview:root];
  }
  [NSLayoutConstraint activateConstraints:@[
    [root.leadingAnchor constraintEqualToAnchor:hostView.leadingAnchor],
    [root.trailingAnchor constraintEqualToAnchor:hostView.trailingAnchor],
    [root.topAnchor constraintEqualToAnchor:hostView.topAnchor],
    [root.bottomAnchor constraintEqualToAnchor:hostView.bottomAnchor],
  ]];

  *outSlot = root;
}

@implementation PipController

- (instancetype)initWith:(id<PipStateChangedDelegate>)delegate {
  self = [super init];
  if (self) {
    _pipStateDelegate = delegate;
    _contentViewOriginalConstraints = [[NSMutableArray alloc] init];
    _contentViewOriginalParentViewConstraints = [[NSMutableArray alloc] init];
  }
  return self;
}

- (BOOL)isSupported {
  // In iOS 15 and later, AVKit provides PiP support for video-calling apps,
  // which enables you to deliver a familiar video-calling experience that
  // behaves like FaceTime.
  // https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/ispictureinpicturesupported()?language=objc
  // https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-for-video-calls?language=objc
  //
  if (__builtin_available(iOS 15.0, *)) {
    return [AVPictureInPictureController isPictureInPictureSupported];
  }

  return NO;
}

- (BOOL)isAutoEnterSupported {
  // canStartPictureInPictureAutomaticallyFromInline is only available on iOS
  // after 14.2, so we just need to check if pip is supported.
  // https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/canstartpictureinpictureautomaticallyfrominline?language=objc
  //
  return [self isSupported];
}

- (BOOL)isActived {
  return _isPipActived;
}

- (BOOL)setup:(PipOptions *)options {
  PIP_LOG(@"PipController setup with preferredContentSize: %@, "
          @"autoEnterEnabled: %d",
          NSStringFromCGSize(options.preferredContentSize),
          options.autoEnterEnabled);
  if (![self isSupported]) {
    [_pipStateDelegate pipStateChanged:PipStateFailed
                                 error:@"Pip is not supported"];
    return NO;
  }

  self.savedIosPipHostBackgroundArgb = options.iosPipHostBackgroundArgb;
  self.savedIsVideoCall = options.isVideoCall;

  if (__builtin_available(iOS 15.0, *)) {
    // we allow the videoCanvas to be nil, which means to use the root view
    // of the app as the source view and do not render the video for now.
    UIView *currentVideoSourceView =
        (options.sourceContentView != nil)
            ? options.sourceContentView
            : [UIApplication.sharedApplication.keyWindow rootViewController]
                  .view;

    _contentView = (UIView *)options.contentView;

    // We need to setup or re-setup the pip controller if:
    // 1. The pip controller hasn't been initialized yet (_pipController == nil)
    // 2. The content source is missing (_pipController.contentSource == nil)
    // view(which
    //    may caused by function dispose or call setup with different video
    //    source view)
    //    (_pipController.contentSource.activeVideoCallSourceView !=
    //    currentVideoSourceView)
    // This ensures the pip controller is properly configured with the current
    // video source with a good user experience.
    if (_pipController == nil || _pipController.contentSource == nil) {
      CFAbsoluteTime setupT0 = CFAbsoluteTimeGetCurrent();

      CGSize pref = options.preferredContentSize;
      if (pref.width <= 0 || pref.height <= 0) {
        pref = CGSizeMake(80, 80);
      }

      _pipVideoCallViewController =
          [[RtcPipVideoCallContentViewController alloc] init];
      _pipVideoCallViewController.rtcPipPreferredContentSize =
          RtcPipAspectPreferredSize(options.isVideoCall);
      _pipVideoCallViewController.rtcForceTransparentHost =
          options.iosPipTransparentSampleBuffer;
      RtcPipNotifyPreferredContentSizeChanged(_pipVideoCallViewController);

      UIView *hostView = _pipVideoCallViewController.view;

      CFAbsoluteTime setupT1 = CFAbsoluteTimeGetCurrent();
      PIP_LOG(@"setup: VC 创建 %.0fms", (setupT1 - setupT0) * 1000);

      RtcInstallPipBackdrop(hostView, pref, options, &_pipBackdropView);

      CFAbsoluteTime setupT2 = CFAbsoluteTimeGetCurrent();
      PIP_LOG(@"setup: PipBackdrop 安装 %.0fms", (setupT2 - setupT1) * 1000);

      RtcApplyPipHostBackground(hostView, self.savedIosPipHostBackgroundArgb);
      if (_pipBackdropView != nil) {
        RtcApplyPipHostBackground(_pipBackdropView.superview,
                                  self.savedIosPipHostBackgroundArgb);
      }

      AVPictureInPictureControllerContentSource *contentSource =
          [[AVPictureInPictureControllerContentSource alloc]
              initWithActiveVideoCallSourceView:currentVideoSourceView
                        contentViewController:_pipVideoCallViewController];

      CFAbsoluteTime setupT3 = CFAbsoluteTimeGetCurrent();
      PIP_LOG(@"setup: contentSource 创建 %.0fms", (setupT3 - setupT2) * 1000);

      _pipController = [[AVPictureInPictureController alloc]
          initWithContentSource:contentSource];

      CFAbsoluteTime setupT4 = CFAbsoluteTimeGetCurrent();
      PIP_LOG(@"setup: AVPictureInPictureController init %.0fms",
              (setupT4 - setupT3) * 1000);

      _pipController.delegate = self;
      _pipController.canStartPictureInPictureAutomaticallyFromInline =
          options.autoEnterEnabled;

      if (options.controlStyle >= 1) {
        _pipController.requiresLinearPlayback = YES;
      }

      if (options.controlStyle == 2) {
        [_pipController setValue:[NSNumber numberWithInt:1]
                          forKey:@"controlsStyle"];
      } else if (options.controlStyle == 3) {
        [_pipController setValue:[NSNumber numberWithInt:2]
                          forKey:@"controlsStyle"];
      }

      PIP_LOG(@"setup: 首次初始化总耗时 %.0fms",
              (CFAbsoluteTimeGetCurrent() - setupT0) * 1000);

#if USE_PIP_VIEW_CONTROLLER
      NSString *pipVCName =
          [NSString stringWithFormat:@"pictureInPictureViewController"];
      _pipViewController = [_pipController valueForKey:pipVCName];
#endif
    } else {
      // pip controller is already initialized, so we need to update the options

      // if the content view is set, will add it to the pip view controller in
      // the method of pictureInPictureControllerDidStartPictureInPicture.
      //
      // if _contentView is not equal to options.contentView, it means the
      // content view has been changed, so we need to remove the old content
      // view and add the new one.
      if (_contentView != options.contentView) {
        if (_contentView != nil) {
          [self restoreContentViewIfNeeded];
        }

        _contentView = (UIView *)options.contentView;
      }

      if (_pipVideoCallViewController != nil) {
        _pipVideoCallViewController.rtcPipPreferredContentSize =
            RtcPipAspectPreferredSize(options.isVideoCall);
        _pipVideoCallViewController.rtcForceTransparentHost =
            options.iosPipTransparentSampleBuffer;
        RtcPipNotifyPreferredContentSizeChanged(_pipVideoCallViewController);
      }

      if (_pipVideoCallViewController != nil &&
          options.preferredContentSize.width > 0 &&
          options.preferredContentSize.height > 0) {
        CGSize pref = options.preferredContentSize;
        BOOL wantVoiceBackdrop = options.iosPipTransparentSampleBuffer;
        BOOL haveVoiceBackdrop =
            (_pipBackdropView != nil &&
             ![_pipBackdropView isKindOfClass:[PipView class]]);
        if (wantVoiceBackdrop != haveVoiceBackdrop) {
          RtcInstallPipBackdrop(_pipVideoCallViewController.view, pref, options,
                                &_pipBackdropView);
        } else if (!wantVoiceBackdrop &&
                   [_pipBackdropView isKindOfClass:[PipView class]]) {
          [(PipView *)_pipBackdropView updateFrameSize:pref
              transparentSampleBuffer:NO];
        }
      }

      if (_pipVideoCallViewController != nil) {
        RtcApplyPipHostBackground(_pipVideoCallViewController.view,
                                  self.savedIosPipHostBackgroundArgb);
        if (_pipBackdropView != nil) {
          RtcApplyPipHostBackground(_pipBackdropView.superview,
                                    self.savedIosPipHostBackgroundArgb);
        }
      }

      if (options.autoEnterEnabled !=
          _pipController.canStartPictureInPictureAutomaticallyFromInline) {
        _pipController.canStartPictureInPictureAutomaticallyFromInline =
            options.autoEnterEnabled;
      }
    }

    return YES;
  }

  return NO;
}

- (UIView *_Nullable __weak)getPipView {
  return _pipBackdropView;
}

- (BOOL)start {
  PIP_LOG(@"PipController start");

  if (![self isSupported]) {
    [_pipStateDelegate pipStateChanged:PipStateFailed
                                 error:@"Pip is not supported"];
    return NO;
  }

  // call startPictureInPicture too fast will make no effect.
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 0.1),
      dispatch_get_main_queue(), ^{
        if (self->_pipController == nil) {
          [self->_pipStateDelegate
              pipStateChanged:PipStateFailed
                        error:@"Pip controller is not initialized"];
          return;
        }

        if (![self->_pipController isPictureInPicturePossible]) {
          [self->_pipStateDelegate pipStateChanged:PipStateFailed
                                             error:@"Pip is not possible"];
        } else if (![self->_pipController isPictureInPictureActive]) {
          [self->_pipController startPictureInPicture];
        }
      });

  return YES;
}

- (void)stop {
  PIP_LOG(@"PipController stop");

  if (![self isSupported]) {
    [_pipStateDelegate pipStateChanged:PipStateFailed
                                 error:@"Pip is not supported"];
    return;
  }

  if (self->_pipController == nil ||
      ![self->_pipController isPictureInPictureActive]) {
    // no need to call pipStateChanged since the pip controller is not
    // initialized.
    return;
  }

  [self->_pipController stopPictureInPicture];
}

// insert the content view to the new parent view
// you should call this method in the method of
// pictureInPictureControllerDidStartPictureInPicture or
// pictureInPictureControllerWillStartPictureInPicture, but bringSubViewToFront
// only take effect in the method of
// pictureInPictureControllerDidStartPictureInPicture, so if you call this
// method in the method of pictureInPictureControllerWillStartPictureInPicture,
// you should addtionaly call bringSubViewToFront in
// pictureInPictureControllerDidStartPictureInPicture.
- (void)insertContentViewIfNeeded:(UIView *)newParentView {
  // if the content view is not set or the new parent view is not set, just
  // return
  if (_contentView == nil || newParentView == nil) {
    PIP_LOG(@"insertContentViewIfNeeded: contentView or newParentView is nil");
    return;
  }

  // if the content view is already in the new parent view, just return
  if ([newParentView.subviews containsObject:_contentView]) {
    PIP_LOG(@"insertContentViewIfNeeded: contentView is already in the new "
            @"parent view");
    return;
  }

  // save the original content view properties
  _contentViewOriginalParentView = _contentView.superview;
  if (_contentViewOriginalParentView != nil) {
    _contentViewOriginalIndex =
        [_contentViewOriginalParentView.subviews indexOfObject:_contentView];
    _contentViewOriginalFrame = _contentView.frame;
    _contentViewOriginalTranslatesAutoresizingMaskIntoConstraints =
        _contentView.translatesAutoresizingMaskIntoConstraints;
    [_contentViewOriginalConstraints
        addObjectsFromArray:_contentView.constraints.mutableCopy];
    [_contentViewOriginalParentViewConstraints
        addObjectsFromArray:_contentViewOriginalParentView.constraints
                                .mutableCopy];

    // remove the content view from the original parent view
    [_contentView removeFromSuperview];

    PIP_LOG(
        @"insertContentViewIfNeeded: contentView is removed from the original "
        @"parent view");
  }

  // add the content view to the new parent view
  [newParentView insertSubview:_contentView
                       atIndex:newParentView.subviews.count];

  // no need to bring the content view to the front, because the content view
  // will be added to the front of the new parent view.
  // // bring the content view to the front
  // [newParentView bringSubviewToFront:_contentView];

  // update the content view constraints（用 bounds，避免父视图 frame 非原点时错位）
  _contentView.translatesAutoresizingMaskIntoConstraints = YES;
  _contentView.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _contentView.frame = newParentView.bounds;

  // It seems like no need to do so.
  // [newParentView addConstraints:@[
  //   [_contentView.leadingAnchor
  //       constraintEqualToAnchor:newParentView.leadingAnchor],
  //   [_contentView.trailingAnchor
  //       constraintEqualToAnchor:newParentView.trailingAnchor],
  //   [_contentView.topAnchor constraintEqualToAnchor:newParentView.topAnchor],
  //   [_contentView.bottomAnchor
  //       constraintEqualToAnchor:newParentView.bottomAnchor],
  // ]];

  PIP_LOG(@"insertContentViewIfNeeded: contentView is added to the new parent "
          @"view");
}

- (void)restoreContentViewIfNeeded {
  // only restore the content view if it is not nil and the original parent
  // view is not nil and the content view is already in the original parent view
  if (_contentView == nil || _contentViewOriginalParentView == nil ||
      [_contentViewOriginalParentView.subviews containsObject:_contentView]) {
    PIP_LOG(
        @"restoreContentViewIfNeeded: _contentViewOriginalParentView is nil or "
        @"contentView is already in the original parent view");
    return;
  }

  [_contentView removeFromSuperview];
  PIP_LOG(
      @"restoreContentViewIfNeeded: contentView is removed from the original "
      @"parent view");

  // in case that the subviews of _contentViewOriginalParentView has been
  // changed, we need to get the real index of the content view.
  NSUInteger trueIndex = MIN(_contentViewOriginalParentView.subviews.count,
                             _contentViewOriginalIndex);
  [_contentViewOriginalParentView insertSubview:_contentView atIndex:trueIndex];

  PIP_LOG(@"restoreContentViewIfNeeded: contentView is added to the original "
          @"parent view "
          @"at index: %lu",
          trueIndex);

  // restore the original frame
  _contentView.frame = _contentViewOriginalFrame;

  // restore the original constraints
  [_contentView removeConstraints:_contentView.constraints.copy];
  [_contentView addConstraints:_contentViewOriginalConstraints];

  // restore the original translatesAutoresizingMaskIntoConstraints
  _contentView.translatesAutoresizingMaskIntoConstraints =
      _contentViewOriginalTranslatesAutoresizingMaskIntoConstraints;

  // restore the original parent view
  [_contentViewOriginalParentView
      removeConstraints:_contentViewOriginalParentView.constraints.copy];
  [_contentViewOriginalParentView
      addConstraints:_contentViewOriginalParentViewConstraints];
}

- (void)dispose {
  PIP_LOG(@"PipController dispose");

  if (self->_pipController != nil) {
    // restore the content view if it is in the pip view controller
    [self restoreContentViewIfNeeded];

    // if ([self->_pipController isPictureInPictureActive]) {
    //   [self->_pipController stopPictureInPicture];
    // }
    //
    // set contentSource to nil will make pip stop immediately without any
    // animation, which is more adaptive to the function of dispose, so we
    // use this method to stop pip not to call stopPictureInPicture.
    //
    // Below is the official document of contentSource property:
    // https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.property?language=objc

    if (__builtin_available(iOS 15.0, *)) {
      self->_pipController.contentSource = nil;
    }

    // Note: do not set self->_pipController and self->_pipBackdropView to nil,
    // coz this will make the pip view do not disappear immediately with
    // unknown reason, which is not expected.
    //
    // self->_pipController = nil;
    // self->_pipBackdropView = nil;
  }

  if (self->_isPipActived) {
    self->_isPipActived = NO;
    [self->_pipStateDelegate pipStateChanged:PipStateStopped error:nil];
  }

}

#pragma mark - AVPictureInPictureControllerDelegate

- (void)pictureInPictureControllerWillStartPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
  PIP_LOG(@"pictureInPictureControllerWillStartPictureInPicture");

  if (_pipVideoCallViewController.view != nil) {
    RtcApplyPipHostBackground(_pipVideoCallViewController.view,
                              self.savedIosPipHostBackgroundArgb);
    [_pipVideoCallViewController rtc_refreshTransparentHostIfNeeded];
  }

#if USE_PIP_VIEW_CONTROLLER
  if (_pipViewController) {
    [self insertContentViewIfNeeded:_pipViewController.view];
  }
#endif
}

- (void)pictureInPictureControllerDidStartPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
  PIP_LOG(@"pictureInPictureControllerDidStartPictureInPicture");

#if USE_PIP_VIEW_CONTROLLER
  if (_pipViewController) {
    [_pipViewController.view bringSubviewToFront:_contentView];
  }
#else
  UIView *pipHost = self->_pipVideoCallViewController.view;
  if (pipHost != nil) {
    [self insertContentViewIfNeeded:pipHost];
    [pipHost bringSubviewToFront:_contentView];
    RtcApplyPipHostBackground(pipHost, self.savedIosPipHostBackgroundArgb);
    if (_pipBackdropView != nil) {
      RtcApplyPipHostBackground(_pipBackdropView.superview,
                                self.savedIosPipHostBackgroundArgb);
    }
    RtcApplyPipHostBackground(_contentView.superview,
                              self.savedIosPipHostBackgroundArgb);
    [_pipVideoCallViewController rtc_refreshTransparentHostIfNeeded];
    if (_pipVideoCallViewController.rtcForceTransparentHost) {
      __weak RtcPipVideoCallContentViewController *weakVc =
          _pipVideoCallViewController;
      for (NSNumber *d in @[ @0.05, @0.15, @0.35 ]) {
        double delay = [d doubleValue];
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(delay * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
              [weakVc rtc_refreshTransparentHostIfNeeded];
            });
      }
    }
  } else {
    UIWindow *window = [[UIApplication sharedApplication] windows].firstObject;
    if (window) {
      UIViewController *rootViewController = window.rootViewController;
      UIView *superview = rootViewController.view.superview;
      [self insertContentViewIfNeeded:superview];
    }
  }
#endif

  _isPipActived = YES;
  [_pipStateDelegate pipStateChanged:PipStateStarted error:nil];

  [self rtc_adjustPipSizeForCallType];
}

/// 根据 isVideoCall 调整 PiP 宽高比并模拟 pinch 手势让系统将窗口放到最大或缩到最小。
- (void)rtc_adjustPipSizeForCallType {
  if (_pipVideoCallViewController == nil) {
    PIP_LOG(@"rtc_adjustPipSizeForCallType: skip, pipVideoCallViewController=nil");
    return;
  }

  NSString *ver = [[UIDevice currentDevice] systemVersion];
  CGSize newPref = RtcPipAspectPreferredSize(self.savedIsVideoCall);
  PIP_LOG(@"iOS=%@ isVideoCall=%d preferredContentSize=%.0fx%.0f ratio=%@",
          ver, (int)self.savedIsVideoCall, newPref.width, newPref.height,
          self.savedIsVideoCall ? @"9:16" : @"1:1");

  _pipVideoCallViewController.rtcPipPreferredContentSize = newPref;
  RtcPipNotifyPreferredContentSizeChanged(_pipVideoCallViewController);

  [self rtc_schedulePipPinchSimulationRetries];
}

/// PiP 动画后手势就绪需要一点时间；只在一段时间后尝试一次捏合模拟，不再多轮延迟重试。
- (void)rtc_schedulePipPinchSimulationRetries {
  const NSTimeInterval kDelay = 0.45;
  PIP_LOG(@"schedule pinch: single attempt after %.2fs", kDelay);
  __weak PipController *weakSelf = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDelay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [weakSelf rtc_simulatePinchOnPipWindow];
      });
}

/// 在系统 PiP 窗口上查找并驱动 UIPinchGestureRecognizer：视频通话放大到最大，语音通话缩小到最小。
- (void)rtc_simulatePinchOnPipWindow {
  UIWindow *pipWindow = [self rtc_findPipWindow];
  if (pipWindow == nil) {
    PIP_LOG(@"rtc_simulatePinchOnPipWindow: PiP window not found");
    return;
  }

  PIP_LOG(@"rtc_simulatePinchOnPipWindow: %@ on window %@",
          self.savedIsVideoCall ? @"pinch-out(max)" : @"pinch-in(min)",
          pipWindow);

  [self rtc_sendPinchOnView:pipWindow];
}

/// 是否具备 pinch 的 scale 属性（含系统私有子类，未必继承 UIPinchGestureRecognizer）。
- (BOOL)rtc_recognizerHasPinchScale:(UIGestureRecognizer *)gr {
  if (gr == nil) {
    return NO;
  }
  if ([gr isKindOfClass:[UIPinchGestureRecognizer class]]) {
    return YES;
  }
  @try {
    [gr valueForKey:@"scale"];
    return YES;
  } @catch (__unused NSException *e) {
    return NO;
  }
}

/// 同一 `rtc_sendPinchOnView` 内对同一 view 只打一次日志（避免 hitTest 多点重复刷屏）。
- (void)rtc_logGestureRecognizersIfAny:(UIView *)v
                                    tag:(NSString *)tag
                              dedupeSet:(NSMutableSet<NSNumber *> *)dedupeSet {
  if (v.gestureRecognizers.count == 0) {
    return;
  }
  if (dedupeSet != nil) {
    NSNumber *key = @((uintptr_t)(__bridge void *)v);
    if ([dedupeSet containsObject:key]) {
      return;
    }
    [dedupeSet addObject:key];
  }
  for (UIGestureRecognizer *gr in v.gestureRecognizers) {
    BOOL hasScale = [self rtc_recognizerHasPinchScale:gr];
    PIP_LOG(@"%@ on %@: GR class=%@ hasScaleAPI=%d", tag,
            NSStringFromClass([v class]), NSStringFromClass([gr class]),
            (int)hasScale);
  }
}

/// 在若干 GR 里优先选类名含 Pinch/Zoom 且带 scale 的，否则任一带 scale 的。
- (nullable UIGestureRecognizer *)rtc_pickBestPinchLikeFromArray:
    (NSArray<UIGestureRecognizer *> *)grs {
  UIGestureRecognizer *pinchNamed = nil;
  UIGestureRecognizer *anyScale = nil;
  for (UIGestureRecognizer *gr in grs) {
    if (![self rtc_recognizerHasPinchScale:gr]) {
      continue;
    }
    if (anyScale == nil) {
      anyScale = gr;
    }
    NSString *cn = NSStringFromClass([gr class]);
    NSRange r1 = [cn rangeOfString:@"Pinch" options:NSCaseInsensitiveSearch];
    NSRange r2 = [cn rangeOfString:@"Zoom" options:NSCaseInsensitiveSearch];
    if (r1.location != NSNotFound || r2.location != NSNotFound) {
      if (pinchNamed == nil) {
        pinchNamed = gr;
      }
    }
  }
  return pinchNamed != nil ? pinchNamed : anyScale;
}

/// BFS 整棵子树，含根视图（PiP 的 pinch 常直接挂在 UIWindow.gestureRecognizers）。
- (nullable UIGestureRecognizer *)rtc_findPinchLikeGestureRecognizer:(UIView *)root
                                                           dedupeSet:(NSMutableSet<NSNumber *> *)dedupeSet
                                                            logViews:(BOOL)logViews {
  if (root == nil) {
    return nil;
  }
  NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
  while (queue.count > 0) {
    UIView *v = queue.firstObject;
    [queue removeObjectAtIndex:0];
    if (logViews) {
      [self rtc_logGestureRecognizersIfAny:v tag:@"[scan]" dedupeSet:dedupeSet];
    }
    UIGestureRecognizer *p =
        [self rtc_pickBestPinchLikeFromArray:v.gestureRecognizers];
    if (p != nil) {
      PIP_LOG(@"findPinchLike: picked class=%@ on %@", NSStringFromClass([p class]),
              NSStringFromClass([v class]));
      return p;
    }
    for (UIView *sub in v.subviews) {
      [queue addObject:sub];
    }
  }
  return nil;
}

/// 在其他「小窗口」（非全屏）上静默找 pinch，部分系统把捏合挂在 PiP 配套遮罩窗上。
- (nullable UIGestureRecognizer *)rtc_findPinchLikeInOtherSmallWindowsExcluding:
    (UIWindow *)pipWin {
  if (pipWin == nil) {
    return nil;
  }
  CGRect screen = [UIScreen mainScreen].bounds;
  CGFloat screenArea = MAX(screen.size.width * screen.size.height, 1.0);
  const CGFloat kMaxAreaRatio = 0.42;
  for (UIWindow *w in [UIApplication sharedApplication].windows) {
    if (w == pipWin || w.hidden || w.alpha < 0.01) {
      continue;
    }
    CGFloat a = w.frame.size.width * w.frame.size.height;
    if (a > screenArea * kMaxAreaRatio || a < 2000.0) {
      continue;
    }
    UIGestureRecognizer *p =
        [self rtc_findPinchLikeGestureRecognizer:w dedupeSet:nil logViews:NO];
    if (p != nil) {
      PIP_LOG(@"findPinchLike: small window %@ area=%.0f -> GR %@",
              NSStringFromCGRect(w.frame), a, NSStringFromClass([p class]));
      return p;
    }
  }
  return nil;
}

/// 收集子树内标准 UIPinchGestureRecognizer（兜底）。
- (NSArray<UIPinchGestureRecognizer *> *)rtc_collectPinchGesturesUnderView:(UIView *)root {
  NSMutableArray<UIPinchGestureRecognizer *> *list =
      [NSMutableArray array];
  if (root == nil) {
    return list;
  }
  NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
  while (stack.count > 0) {
    UIView *v = stack.lastObject;
    [stack removeLastObject];
    for (UIGestureRecognizer *gr in v.gestureRecognizers) {
      if ([gr isKindOfClass:[UIPinchGestureRecognizer class]]) {
        [list addObject:(UIPinchGestureRecognizer *)gr];
      }
    }
    for (UIView *sub in v.subviews) {
      [stack addObject:sub];
    }
  }
  PIP_LOG(@"collectPinch: root=%@ UIPinchGestureRecognizer count=%lu",
          NSStringFromClass([root class]), (unsigned long)list.count);
  return list;
}

/// hitTest 链上找带 scale 的捏合类手势。
- (nullable UIGestureRecognizer *)rtc_findPinchByHitTestingWindow:(UIWindow *)win
                                                        dedupeSet:(NSMutableSet<NSNumber *> *)dedupeSet {
  if (win.bounds.size.width < 1 || win.bounds.size.height < 1) {
    return nil;
  }
  NSArray<NSValue *> *points = @[
    [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(win.bounds),
                                            CGRectGetMidY(win.bounds))],
    [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(win.bounds),
                                            CGRectGetMinY(win.bounds) + 28)],
    [NSValue valueWithCGPoint:CGPointMake(CGRectGetMinX(win.bounds) + 28,
                                            CGRectGetMidY(win.bounds))],
    [NSValue valueWithCGPoint:CGPointMake(CGRectGetMaxX(win.bounds) - 28,
                                            CGRectGetMidY(win.bounds))],
  ];
  for (NSValue *pv in points) {
    CGPoint pt = pv.CGPointValue;
    UIView *hit = [win hitTest:pt withEvent:nil];
    for (UIView *v = hit; v != nil; v = v.superview) {
      [self rtc_logGestureRecognizersIfAny:v tag:@"[hitTest]" dedupeSet:dedupeSet];
      UIGestureRecognizer *p =
          [self rtc_pickBestPinchLikeFromArray:v.gestureRecognizers];
      if (p != nil) {
        PIP_LOG(@"findPinchByHitTest: hit=%@ -> %@", hit, NSStringFromClass([p class]));
        return p;
      }
    }
  }
  return nil;
}

/// 在 PiP 窗口上查找可驱动的 pinch（含私有类），再模拟缩放。
- (void)rtc_sendPinchOnView:(UIView *)targetView {
  NSMutableSet<NSNumber *> *dedupe = [NSMutableSet set];
  [self rtc_logGestureRecognizersIfAny:targetView tag:@"[pipTarget]" dedupeSet:dedupe];

  UIGestureRecognizer *gr =
      [self rtc_findPinchLikeGestureRecognizer:targetView dedupeSet:dedupe logViews:YES];
  if (gr == nil && [targetView isKindOfClass:[UIWindow class]]) {
    gr = [self rtc_findPinchByHitTestingWindow:(UIWindow *)targetView dedupeSet:dedupe];
  }
  if (gr == nil && [targetView isKindOfClass:[UIWindow class]]) {
    gr = [self rtc_findPinchLikeInOtherSmallWindowsExcluding:(UIWindow *)targetView];
  }
  if (gr == nil) {
    NSArray<UIPinchGestureRecognizer *> *legacy =
        [self rtc_collectPinchGesturesUnderView:targetView];
    gr = legacy.lastObject;
  }
  if (gr == nil) {
    gr = [self rtc_findPinchGestureRecursive:targetView];
  }

  if (gr != nil) {
    PIP_LOG(@"rtc_sendPinchOnView: drive class=%@", NSStringFromClass([gr class]));
    BOOL zoomIn = self.savedIsVideoCall;
    if (zoomIn) {
      [self rtc_drivePinchGesture:gr scale:4.0 zoomIn:YES];
    } else {
      [self rtc_drivePinchGesture:gr scale:0.14 zoomIn:NO];
      __weak PipController *weakSelf = self;
      __weak UIGestureRecognizer *weakGr = gr;
      NSTimeInterval secondRoundDelay = 0.032 * 27 + 0.1;
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW,
                        (int64_t)(secondRoundDelay * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
            PipController *strongSelf = weakSelf;
            UIGestureRecognizer *p = weakGr;
            if (strongSelf == nil || p == nil || strongSelf.savedIsVideoCall) {
              return;
            }
            [strongSelf rtc_drivePinchGesture:p scale:0.06 zoomIn:NO];
          });
    }
    return;
  }

  PIP_LOG(@"rtc_sendPinchOnView: 无 UIPinch/scale；仅依赖 preferredContentSize 与用户双指捏合。");
}

/// 查找 targetView 直接的 pinch gesture recognizer。
- (nullable UIPinchGestureRecognizer *)rtc_findPinchGestureInView:(UIView *)view {
  for (UIGestureRecognizer *gr in view.gestureRecognizers) {
    if ([gr isKindOfClass:[UIPinchGestureRecognizer class]]) {
      return (UIPinchGestureRecognizer *)gr;
    }
  }
  return nil;
}

/// 递归查找子视图树中的 UIPinchGestureRecognizer。
- (nullable UIPinchGestureRecognizer *)rtc_findPinchGestureRecursive:(UIView *)view {
  for (UIGestureRecognizer *gr in view.gestureRecognizers) {
    if ([gr isKindOfClass:[UIPinchGestureRecognizer class]]) {
      return (UIPinchGestureRecognizer *)gr;
    }
  }
  for (UIView *sub in view.subviews) {
    UIPinchGestureRecognizer *found = [self rtc_findPinchGestureRecursive:sub];
    if (found != nil) {
      return found;
    }
  }
  return nil;
}

- (void)rtc_setRecognizerScale:(UIGestureRecognizer *)gr scale:(CGFloat)s {
  @try {
    if ([gr isKindOfClass:[UIPinchGestureRecognizer class]]) {
      ((UIPinchGestureRecognizer *)gr).scale = s;
    } else {
      [gr setValue:@(s) forKey:@"scale"];
    }
  } @catch (__unused NSException *e) {
    PIP_LOG(@"setRecognizerScale failed for %@", NSStringFromClass([gr class]));
  }
}

- (CGFloat)rtc_getRecognizerScale:(UIGestureRecognizer *)gr {
  @try {
    if ([gr isKindOfClass:[UIPinchGestureRecognizer class]]) {
      return ((UIPinchGestureRecognizer *)gr).scale;
    }
    id v = [gr valueForKey:@"scale"];
    if ([v isKindOfClass:[NSNumber class]]) {
      return [(NSNumber *)v doubleValue];
    }
  } @catch (__unused NSException *e) {
  }
  return NAN;
}

/// 通过 KVC 写入手势状态并更新 scale（支持私有 pinch 子类）。
- (void)rtc_drivePinchGesture:(UIGestureRecognizer *)pinchGR
                         scale:(CGFloat)targetScale
                       zoomIn:(BOOL)zoomIn {
  int totalSteps = zoomIn ? 18 : 26;
  NSTimeInterval stepInterval = zoomIn ? 0.028 : 0.032;
  CGFloat startScale = 1.0;
  PIP_LOG(@"drivePinch begin zoomIn=%d targetScale=%.3f steps=%d interval=%.3f "
          @"gr=%@ class=%@ view=%@",
          (int)zoomIn, targetScale, totalSteps, stepInterval, pinchGR,
          NSStringFromClass([pinchGR class]), pinchGR.view);

  void (^setGRState)(NSInteger) = ^(NSInteger st) {
    @try {
      [pinchGR setValue:@(st) forKey:@"state"];
    } @catch (__unused NSException *e) {
      @try {
        [pinchGR setValue:@(st) forKey:@"_state"];
      } @catch (__unused NSException *e2) {
        PIP_LOG(@"rtc_drivePinchGesture: cannot set state %ld", (long)st);
      }
    }
  };

  setGRState(UIGestureRecognizerStatePossible);
  setGRState(UIGestureRecognizerStateBegan);
  [self rtc_setRecognizerScale:pinchGR scale:startScale];

  for (int i = 1; i <= totalSteps; i++) {
    CGFloat fraction = (CGFloat)i / (CGFloat)totalSteps;
    CGFloat curScale = startScale + (targetScale - startScale) * fraction;
    __block CGFloat captured = curScale;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(stepInterval * i * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          setGRState(UIGestureRecognizerStateChanged);
          [self rtc_setRecognizerScale:pinchGR scale:captured];
        });
  }

  __weak PipController *weakSelf = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(stepInterval * (totalSteps + 1) * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        PipController *s = weakSelf;
        if (s == nil) {
          return;
        }
        setGRState(UIGestureRecognizerStateEnded);
        CGFloat endS = zoomIn ? MAX(targetScale, 1.0) : MIN(targetScale, 1.0);
        [s rtc_setRecognizerScale:pinchGR scale:endS];
        CGFloat readBack = [s rtc_getRecognizerScale:pinchGR];
        PIP_LOG(@"drivePinch ended zoomIn=%d readBackScale=%.3f", (int)zoomIn,
                readBack);
      });
}

/// 类名子串匹配（不区分大小写）。
static BOOL RtcPipClassNameMatches(NSString *cls, NSArray<NSString *> *parts) {
  if (cls.length == 0) {
    return NO;
  }
  NSString *lower = cls.lowercaseString;
  for (NSString *p in parts) {
    if ([lower containsString:p.lowercaseString]) {
      return YES;
    }
  }
  return NO;
}

/// 排除明显不是 PiP 的系统窗口（iOS 新版本类名可能很普通，靠排除缩小范围）。
static BOOL RtcPipWindowClassExcluded(NSString *cls) {
  if (cls.length == 0) {
    return YES;
  }
  NSString *l = cls.lowercaseString;
  NSArray<NSString *> *bad = @[
    @"keyboard",
    @"texteffects",
    @"statusbar",
    @"input",
    @"remote",
    @"springboard",
    @"drag",
    @"shutter",
    @"controlcenter",
    @"banner",
    @"alert",
    @"popover",
  ];
  for (NSString *b in bad) {
    if ([l containsString:b]) {
      return YES;
    }
  }
  return NO;
}

static CGFloat RtcPipWindowArea(UIWindow *w) {
  return CGRectGetWidth(w.bounds) * CGRectGetHeight(w.bounds);
}

/// PiP 激活时打印当前所有窗口，便于对照 iOS 26+ 等新系统上的真实类名与 frame。
- (void)rtc_logAllWindowsDiagnostic {
  PIP_LOG(@"--- dump windows (PiP active=%d) ---",
          (int)self->_pipController.isPictureInPictureActive);
  for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
      continue;
    }
    UIWindowScene *ws = (UIWindowScene *)scene;
    for (UIWindow *w in ws.windows) {
      PIP_LOG(
          @"  win class=%@ key=%d hidden=%d alpha=%.2f bounds=%@ frame=%@ "
          @"level=%.1f",
          NSStringFromClass([w class]), (int)w.isKeyWindow, (int)w.hidden,
          w.alpha, NSStringFromCGRect(w.bounds), NSStringFromCGRect(w.frame),
          w.windowLevel);
    }
  }
  NSArray<UIWindow *> *legacy = [UIApplication sharedApplication].windows;
  if (legacy.count > 0) {
    PIP_LOG(@"  UIApplication.windows count=%lu", (unsigned long)legacy.count);
  }
  PIP_LOG(@"--- dump end ---");
}

/// 收集当前进程内可见窗口（去重指针）。
- (NSMutableArray<UIWindow *> *)rtc_collectAllVisibleWindowsUnique {
  NSMutableOrderedSet<UIWindow *> *set = [NSMutableOrderedSet orderedSet];
  for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
      continue;
    }
    for (UIWindow *w in ((UIWindowScene *)scene).windows) {
      if (w != nil) {
        [set addObject:w];
      }
    }
  }
  for (UIWindow *w in [UIApplication sharedApplication].windows) {
    if (w != nil) {
      [set addObject:w];
    }
  }
  NSMutableArray<UIWindow *> *arr = [NSMutableArray array];
  for (UIWindow *w in set) {
    [arr addObject:w];
  }
  return arr;
}

/// 查找系统 PiP 窗口：类名关键字 → 非全屏小窗 → 非 key 的最小面积窗（适配 iOS 18+ / 26 等类名泛化）。
- (nullable UIWindow *)rtc_findPipWindow {
  NSArray<NSString *> *nameHints = @[
    @"PictureInPicture",
    @"AVPiP",
    @"PiP",
    @"pip",
    @"Floating",
    @"Portal",
    @"Hosted",
    @"AVPlayer",
    @"Inline",
    @"Compact",
  ];

  CGRect screenRect = [UIScreen mainScreen].bounds;
  CGFloat screenArea =
      CGRectGetWidth(screenRect) * CGRectGetHeight(screenRect);
  if (screenArea < 1) {
    screenArea = 1;
  }

  UIWindow *keyWin = nil;
  for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
      continue;
    }
    UIWindowScene *ws = (UIWindowScene *)scene;
    if (ws.keyWindow != nil) {
      keyWin = ws.keyWindow;
      break;
    }
  }

  NSMutableArray<UIWindow *> *hintMatched = [NSMutableArray array];
  NSMutableArray<UIWindow *> *nonFullNonKey = [NSMutableArray array];
  NSMutableArray<UIWindow *> *nonFullAny = [NSMutableArray array];
  UIWindow *smallestNonKey = nil;
  CGFloat smallestNonKeyArea = CGFLOAT_MAX;

  NSArray<UIWindow *> *all = [self rtc_collectAllVisibleWindowsUnique];
  for (UIWindow *w in all) {
    if (w.hidden || w.alpha < 0.02) {
      continue;
    }
    NSString *cls = NSStringFromClass([w class]);
    if (RtcPipWindowClassExcluded(cls)) {
      continue;
    }

    CGFloat bw = CGRectGetWidth(w.bounds);
    CGFloat bh = CGRectGetHeight(w.bounds);
    CGFloat a = bw * bh;
    if (a < 800) {
      continue;
    }

    if (RtcPipClassNameMatches(cls, nameHints)) {
      [hintMatched addObject:w];
    }

    BOOL fullLike =
        (bw >= CGRectGetWidth(screenRect) - 12 &&
         bh >= CGRectGetHeight(screenRect) - 12);
    if (fullLike) {
      continue;
    }

    [nonFullAny addObject:w];
    if (!w.isKeyWindow) {
      [nonFullNonKey addObject:w];
      if (a < smallestNonKeyArea) {
        smallestNonKeyArea = a;
        smallestNonKey = w;
      }
    }
  }

  if (hintMatched.count == 1) {
    UIWindow *w = hintMatched.firstObject;
    PIP_LOG(@"findPipWindow: hint single class=%@ frame=%@",
            NSStringFromClass([w class]), NSStringFromCGRect(w.frame));
    return w;
  }
  if (hintMatched.count > 1) {
    UIWindow *best = nil;
    CGFloat bestArea = CGFLOAT_MAX;
    for (UIWindow *w in hintMatched) {
      CGFloat ar = RtcPipWindowArea(w);
      if (ar > 400 && ar < bestArea) {
        bestArea = ar;
        best = w;
      }
    }
    UIWindow *picked = best != nil ? best : hintMatched.firstObject;
    PIP_LOG(@"findPipWindow: hint multi picked class=%@ frame=%@",
            NSStringFromClass([picked class]), NSStringFromCGRect(picked.frame));
    return picked;
  }

  // 非全屏且非 key：典型 PiP（新系统常为普通 UIWindow）；同档内取面积最小更像小窗
  UIWindow *bandBest = nil;
  CGFloat bandBestArea = CGFLOAT_MAX;
  for (UIWindow *w in nonFullNonKey) {
    CGFloat ar = RtcPipWindowArea(w);
    if (ar >= screenArea * 0.08 && ar <= screenArea * 0.65 && ar < bandBestArea) {
      bandBestArea = ar;
      bandBest = w;
    }
  }
  if (bandBest != nil) {
    PIP_LOG(@"findPipWindow: nonFull+nonKey class=%@ area=%.0f frame=%@",
            NSStringFromClass([bandBest class]), bandBestArea,
            NSStringFromCGRect(bandBest.frame));
    return bandBest;
  }

  if (smallestNonKey != nil && smallestNonKeyArea <= screenArea * 0.72) {
    PIP_LOG(@"findPipWindow: smallestNonKey class=%@ area=%.0f frame=%@",
            NSStringFromClass([smallestNonKey class]), smallestNonKeyArea,
            NSStringFromCGRect(smallestNonKey.frame));
    return smallestNonKey;
  }

  // 最后：任意非全屏窗口里面积最小的（PiP 可能短暂被标成 key）
  UIWindow *minW = nil;
  CGFloat minA = CGFLOAT_MAX;
  for (UIWindow *w in nonFullAny) {
    CGFloat ar = RtcPipWindowArea(w);
    if (ar >= 1200 && ar < minA && ar <= screenArea * 0.75) {
      minA = ar;
      minW = w;
    }
  }
  if (minW != nil) {
    PIP_LOG(@"findPipWindow: fallback smallest non-fullscreen class=%@ "
            @"area=%.0f frame=%@",
            NSStringFromClass([minW class]), minA,
            NSStringFromCGRect(minW.frame));
    return minW;
  }

  PIP_LOG(@"findPipWindow: no match; keyWin=%@ keyArea=%.0f",
          keyWin != nil ? NSStringFromClass([keyWin class]) : @"(nil)",
          keyWin != nil ? RtcPipWindowArea(keyWin) : 0.0);
  [self rtc_logAllWindowsDiagnostic];
  return nil;
}

- (void)pictureInPictureController:
            (AVPictureInPictureController *)pictureInPictureController
    failedToStartPictureInPictureWithError:(NSError *)error {
  PIP_LOG(
      @"pictureInPictureController failedToStartPictureInPictureWithError: %@",
      error);
  [_pipStateDelegate pipStateChanged:PipStateFailed error:error.description];
}

- (void)pictureInPictureControllerWillStopPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
  PIP_LOG(@"pictureInPictureControllerWillStopPictureInPicture");

  // you can restore the content view in this method, but it will have a not so
  // good user experience. you will see the content view is not visible
  // immediately, but the pip window is still showing with a black background,
  // then animation to the settled contentSourceView. [self
  // restoreContentViewIfNeeded];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
  PIP_LOG(@"pictureInPictureControllerDidStopPictureInPicture");

  // restore the content view in
  // pictureInPictureControllerDidStopPictureInPicture will have the best user
  // experience.
  [self restoreContentViewIfNeeded];

  _isPipActived = NO;
  [_pipStateDelegate pipStateChanged:PipStateStopped error:nil];
}

@end
