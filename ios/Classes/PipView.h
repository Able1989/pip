#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class AVSampleBufferDisplayLayer;

@interface PipView : UIView

@property (nonatomic) AVSampleBufferDisplayLayer *sampleBufferDisplayLayer;

/// @param transparent YES 时填充全透明像素（仅语音小卡片场景），避免整窗不透明白底显得「窗体巨大」。
- (void)updateFrameSize:(CGSize)frameSize
    transparentSampleBuffer:(BOOL)transparent;

@end

NS_ASSUME_NONNULL_END