#import "PipController.h"
#import "PipView.h"
#include <Foundation/Foundation.h>
#include <objc/objc.h>

#import <AVKit/AVKit.h>
#import <UIKit/UIKit.h>

#ifdef DEBUG
#define ENABLE_LOG 1
#else
#define ENABLE_LOG 0
#endif

#if ENABLE_LOG
#define PIP_LOG(fmt, ...) NSLog((@"[PIP] " fmt), ##__VA_ARGS__)
#else
#define PIP_LOG(fmt, ...)
#endif

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

      CGSize pref = options.preferredContentSize;
      if (pref.width <= 0 || pref.height <= 0) {
        pref = CGSizeMake(80, 80);
      }

      _pipVideoCallViewController =
          [[RtcPipVideoCallContentViewController alloc] init];
      _pipVideoCallViewController.rtcPipPreferredContentSize = pref;
      _pipVideoCallViewController.rtcForceTransparentHost =
          options.iosPipTransparentSampleBuffer;
      RtcPipNotifyPreferredContentSizeChanged(_pipVideoCallViewController);

      UIView *hostView = _pipVideoCallViewController.view;

      RtcInstallPipBackdrop(hostView, pref, options, &_pipBackdropView);

      RtcApplyPipHostBackground(hostView, self.savedIosPipHostBackgroundArgb);
      if (_pipBackdropView != nil) {
        RtcApplyPipHostBackground(_pipBackdropView.superview,
                                  self.savedIosPipHostBackgroundArgb);
      }

      AVPictureInPictureControllerContentSource *contentSource =
          [[AVPictureInPictureControllerContentSource alloc]
              initWithActiveVideoCallSourceView:currentVideoSourceView
                        contentViewController:_pipVideoCallViewController];

      _pipController = [[AVPictureInPictureController alloc]
          initWithContentSource:contentSource];
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

      if (options.preferredContentSize.width > 0 &&
          options.preferredContentSize.height > 0) {
        CGSize pref = options.preferredContentSize;
        if (_pipVideoCallViewController != nil) {
          _pipVideoCallViewController.rtcPipPreferredContentSize = pref;
          _pipVideoCallViewController.rtcForceTransparentHost =
              options.iosPipTransparentSampleBuffer;
          RtcPipNotifyPreferredContentSizeChanged(_pipVideoCallViewController);
        }
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
