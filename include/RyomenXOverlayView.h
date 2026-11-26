#pragma once

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#ifdef __cplusplus
namespace IosUIBridge {
struct IHostBackend;
}
#endif

NS_ASSUME_NONNULL_BEGIN

@interface RyomenXOverlayView : MTKView <MTKViewDelegate>

@property (nonatomic, strong, nullable) id<MTLCommandQueue> command_queue;
@property (nonatomic, strong, nullable) id<MTLTexture> brand_texture;
@property (nonatomic, strong, nullable) UITouch* primary_touch;
@property (nonatomic, assign) CFTimeInterval last_frame;
@property (nonatomic, strong, nullable) UIVisualEffectView* menu_backdrop;
@property (nonatomic, strong, nullable) UIVisualEffectView* hub_backdrop;
@property (nonatomic, assign) BOOL reduce_transparency;
@property (nonatomic, assign) BOOL restore_menu;

- (instancetype)initWithFrame:(CGRect)frameRect device:(nullable id<MTLDevice>)device;
- (void)updateMenuBackdrop;

@end

// Wrap/unwrap overlay inside CaptureContainerView for screen-capture hiding.
void RyomenXSetCaptureProtectionEnabled(RyomenXOverlayView* overlay, BOOL enabled);

// Standalone dylib lifecycle helpers (attaches directly to the active key window).
#ifdef __cplusplus
extern "C" {
#endif
void RyomenXAttachOverlayToKeyWindow(void);
void RyomenXDetachOverlay(void);
RyomenXOverlayView* _Nullable RyomenXGetOverlayView(void);
#ifdef __cplusplus
}
void RyomenXSetHostBackend(IosUIBridge::IHostBackend* _Nullable backend);
#endif

NS_ASSUME_NONNULL_END
