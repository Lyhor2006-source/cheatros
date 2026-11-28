#import "RyomenXOverlayView.h"
#import "CaptureContainerView.h"
#import "BrandAssets.h"
#import "IosGameBridge.h"
#import "IosUI.h"
#import "IosUIBridge.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include "imgui.h"
#include "imgui_internal.h"
#include "imgui_impl_metal.h"

#include <algorithm>
#include <cstring>

@interface RyomenXOverlayView () {
    BOOL _prevMenuBackdropActive;
}
@end

static CaptureContainerView* _Nullable FindCaptureContainerForOverlay(RyomenXOverlayView* overlay) {
    if (!overlay) return nil;
    for (UIView* parent = overlay.superview; parent; parent = parent.superview) {
        if ([parent isKindOfClass:[CaptureContainerView class]]) {
            return (CaptureContainerView*)parent;
        }
    }
    return nil;
}

static CaptureContainerView* _Nullable EnsureCaptureContainerForOverlay(RyomenXOverlayView* overlay) {
    if (!overlay || !overlay.superview) return nil;
    if (CaptureContainerView* existing = FindCaptureContainerForOverlay(overlay)) return existing;
    UIView* host = overlay.superview;
    CaptureContainerView* container = [[CaptureContainerView alloc] initWithFrame:host.bounds];
    [host addSubview:container];
    [container attachContent:overlay];
    [host bringSubviewToFront:container];
    return container;
}

static void DetachCaptureContainerIfNeeded(RyomenXOverlayView* overlay) {
    if (!overlay) return;
    CaptureContainerView* container = FindCaptureContainerForOverlay(overlay);
    if (!container || !container.superview) return;

    UIView* host = container.superview;
    [overlay removeFromSuperview];
    overlay.frame = host.bounds;
    [host addSubview:overlay];
    [host bringSubviewToFront:overlay];
    [container removeFromSuperview];
}

void RyomenXSetCaptureProtectionEnabled(RyomenXOverlayView* overlay, BOOL enabled) {
    if (enabled) {
        EnsureCaptureContainerForOverlay(overlay);
    } else {
        DetachCaptureContainerIfNeeded(overlay);
    }
}

@implementation RyomenXOverlayView

- (instancetype)initWithFrame:(CGRect)frameRect device:(nullable id<MTLDevice>)device {
    id<MTLDevice> dev = device ?: MTLCreateSystemDefaultDevice();
    self = [super initWithFrame:frameRect device:dev];
    if (!self) return nil;

    _command_queue = [dev newCommandQueue];
    _last_frame = 0.0;
    _prevMenuBackdropActive = NO;

    self.opaque = NO;
    self.backgroundColor = [UIColor clearColor];
    self.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.framebufferOnly = YES;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.multipleTouchEnabled = YES;

    if ([self.layer isKindOfClass:[CAMetalLayer class]]) {
        CAMetalLayer* ml = (CAMetalLayer*)self.layer;
        if ([ml respondsToSelector:@selector(setMaximumDrawableCount:)]) {
            ml.maximumDrawableCount = 3;
        }
        ml.presentsWithTransaction = NO;
    }

    NSInteger maxFps = [UIScreen mainScreen].maximumFramesPerSecond;
    self.preferredFramesPerSecond = std::min<NSInteger>(maxFps > 0 ? maxFps : 60, 120);
    self.contentScaleFactor = std::min<CGFloat>([UIScreen mainScreen].scale, 2.0);
    self.autoResizeDrawable = YES;
    self.delegate = self;

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.LogFilename = nullptr;

    // Primary UI font: Roboto Medium @ 32px scaled 0.5x + merged FontAwesome (0xF000..0xFFF8)
    ImFontConfig primaryCfg;
    primaryCfg.FontDataOwnedByAtlas = false;
    primaryCfg.OversampleH = 2;
    primaryCfg.OversampleV = 2;
    primaryCfg.PixelSnapH = false;

    NSData* primaryTtf = BrandAssets::LoadAssetData(@"primary_font.ttf");
    if (primaryTtf.length > 0) {
        ImFont* font0 = io.Fonts->AddFontFromMemoryTTF(
            const_cast<void*>(primaryTtf.bytes),
            static_cast<int>(primaryTtf.length),
            32.0f, &primaryCfg, nullptr);
        if (font0) {
            font0->Scale = 0.5f;
            io.FontDefault = font0;
        }

        NSData* faComp = BrandAssets::LoadAssetData(@"fontawesome_compressed.bin");
        if (faComp.length > 0) {
            ImFontConfig faCfg;
            faCfg.MergeMode = true;
            faCfg.FontDataOwnedByAtlas = false;
            faCfg.PixelSnapH = false;
            faCfg.OversampleH = 2;
            faCfg.OversampleV = 2;
            io.Fonts->AddFontFromMemoryCompressedTTF(
                faComp.bytes,
                static_cast<int>(faComp.length),
                32.0f, &faCfg, BrandAssets::kFontAwesomeGlyphRanges);
        }

        ImFontConfig titleCfg = primaryCfg;
        titleCfg.RasterizerMultiply = 1.25f;
        ImFont* titleFont = io.Fonts->AddFontFromMemoryTTF(
            const_cast<void*>(primaryTtf.bytes),
            static_cast<int>(primaryTtf.length),
            36.0f, &titleCfg, nullptr);
        if (titleFont) {
            titleFont->Scale = 0.5f;
            IosUI::SetHeaderTitleFont(titleFont);
        }
    } else {
        io.Fonts->AddFontDefault();
    }
    io.Fonts->Build();

    // Brand avatar texture (640x640 PNG)
    NSData* brandPng = BrandAssets::LoadAssetData(@"brand_texture.png");
    if (brandPng.length > 0) {
        MTKTextureLoader* loader = [[MTKTextureLoader alloc] initWithDevice:dev];
        NSDictionary* opts = @{
            MTKTextureLoaderOptionSRGB: @NO,
            MTKTextureLoaderOptionGenerateMipmaps: @YES
        };
        _brand_texture = [loader newTextureWithData:brandPng options:opts error:nil];
        IosUIBridge::GetContext().brandTextureId = (__bridge void*)_brand_texture;
    }

    // Menu & Dynamic Island UIVisualEffectView backdrops
    UIBlurEffect* blur = [UIBlurEffect effectWithStyle:(UIBlurEffectStyle)16];
    _menu_backdrop = [[UIVisualEffectView alloc] initWithEffect:blur];
    _menu_backdrop.userInteractionEnabled = NO;
    _menu_backdrop.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.035];
    _menu_backdrop.layer.cornerRadius = 18.0;
    if (@available(iOS 13.0, *)) {
        _menu_backdrop.layer.cornerCurve = kCACornerCurveContinuous;
    }
    _menu_backdrop.clipsToBounds = YES;
    _menu_backdrop.hidden = YES;
    _menu_backdrop.alpha = 1.0;

    _hub_backdrop = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:(UIBlurEffectStyle)16]];
    _hub_backdrop.userInteractionEnabled = NO;
    _hub_backdrop.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
    if (@available(iOS 13.0, *)) {
        _hub_backdrop.layer.cornerCurve = kCACornerCurveContinuous;
    }
    _hub_backdrop.clipsToBounds = YES;
    _hub_backdrop.hidden = YES;

    ImGui_ImplMetal_Init(dev);
    IosUI::LoadSettings();

    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(applicationSuspended:) name:UIApplicationWillResignActiveNotification object:nil];
    [nc addObserver:self selector:@selector(applicationSuspended:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(applicationResumed:) name:UIApplicationDidBecomeActiveNotification object:nil];

    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_menu_backdrop removeFromSuperview];
    [_hub_backdrop removeFromSuperview];
    ImGui_ImplMetal_Shutdown();
    ImGui::DestroyContext();
}

- (void)applicationSuspended:(NSNotification*)note {
    (void)note;
    IosUI::SaveSettings();
    self.paused = YES;
}

- (void)applicationResumed:(NSNotification*)note {
    (void)note;
    self.paused = NO;
    self.last_frame = 0.0;
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    [self.menu_backdrop removeFromSuperview];
    [self.hub_backdrop removeFromSuperview];
    if (self.superview) {
        [self.superview insertSubview:self.menu_backdrop belowSubview:self];
        [self.superview insertSubview:self.hub_backdrop belowSubview:self];
    }
}

- (void)updateMenuBackdrop {
    if (!self.superview) return;

    BOOL reduceTransp = UIAccessibilityIsReduceTransparencyEnabled();
    if (reduceTransp != self.reduce_transparency) {
        self.reduce_transparency = reduceTransp;
        if (reduceTransp) {
            self.menu_backdrop.effect = nil;
            self.menu_backdrop.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
            self.hub_backdrop.effect = nil;
            self.hub_backdrop.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
        } else {
            self.menu_backdrop.effect = [UIBlurEffect effectWithStyle:(UIBlurEffectStyle)16];
            self.menu_backdrop.backgroundColor = [UIColor clearColor];
            self.hub_backdrop.effect = [UIBlurEffect effectWithStyle:(UIBlurEffectStyle)16];
            self.hub_backdrop.backgroundColor = [UIColor clearColor];
        }
    }

    auto& layout = IosUIBridge::GetContext().layout;

    auto syncBackdrop = [&](UIVisualEffectView* v, BOOL active, CGRect localRect, CGFloat radius) {
        if (!v) return;
        if (!active || CGRectIsEmpty(localRect)) {
            v.hidden = YES;
            return;
        }
        v.hidden = NO;
        CGRect mapped = [self convertRect:localRect toView:self.superview];
        if (!CGRectEqualToRect(v.frame, mapped)) {
            v.frame = mapped;
        }
        if (radius > 0.0) {
            v.layer.cornerRadius = radius;
        }
        if (v.superview != self.superview) {
            [self.superview insertSubview:v belowSubview:self];
        }
    };

    syncBackdrop(
        self.menu_backdrop,
        layout.menuBackdropActive,
        CGRectMake(layout.menuBackdropX, layout.menuBackdropY, layout.menuBackdropW, layout.menuBackdropH),
        18.0);

    syncBackdrop(
        self.hub_backdrop,
        layout.hubBackdropActive,
        CGRectMake(layout.hubBackdropX, layout.hubBackdropY, layout.hubBackdropW, layout.hubBackdropH),
        layout.hubBackdropH * 0.5);
}

- (BOOL)pointInside:(CGPoint)point withEvent:(nullable UIEvent*)event {
    (void)event;
    if (!ImGui::GetCurrentContext()) return NO;

    float ptX = static_cast<float>(point.x);
    float ptY = static_cast<float>(point.y);
    float viewW = static_cast<float>(self.bounds.size.width);
    float viewH = static_cast<float>(self.bounds.size.height);

    if (IosUI::IsPointInMenuOrFloatingHUD(ptX, ptY, viewW, viewH)) {
        return YES;
    }
    return NO;
}

- (nullable UIView*)hitTest:(CGPoint)point withEvent:(nullable UIEvent*)event {
    return [self pointInside:point withEvent:event] ? self : nil;
}

- (void)updateTouch:(nullable UITouch*)touch down:(BOOL)down {
    if (!ImGui::GetCurrentContext()) return;
    ImGuiIO& io = ImGui::GetIO();
    if (touch) {
        CGPoint pt = [touch locationInView:self];
        io.MousePos = ImVec2(static_cast<float>(pt.x), static_cast<float>(pt.y));
    }
    io.MouseDown[0] = down;
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(nullable UIEvent*)event {
    (void)event;
    if (!self.primary_touch) {
        self.primary_touch = touches.anyObject;
    }
    if (self.primary_touch) {
        CGPoint pt = [self.primary_touch locationInView:self];
        IosUI::OnTouchBegan(static_cast<float>(pt.x), static_cast<float>(pt.y),
                            static_cast<float>(self.bounds.size.width),
                            static_cast<float>(self.bounds.size.height));
        [self updateTouch:self.primary_touch down:YES];
    }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(nullable UIEvent*)event {
    (void)event;
    if (self.primary_touch && [touches containsObject:self.primary_touch]) {
        CGPoint pt = [self.primary_touch locationInView:self];
        IosUI::OnTouchMoved(static_cast<float>(pt.x), static_cast<float>(pt.y),
                            static_cast<float>(self.bounds.size.width),
                            static_cast<float>(self.bounds.size.height));
        [self updateTouch:self.primary_touch down:YES];
    }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(nullable UIEvent*)event {
    (void)event;
    if (self.primary_touch && [touches containsObject:self.primary_touch]) {
        CGPoint pt = [self.primary_touch locationInView:self];
        IosUI::OnTouchEnded(static_cast<float>(pt.x), static_cast<float>(pt.y),
                            static_cast<float>(self.bounds.size.width),
                            static_cast<float>(self.bounds.size.height));
        [self updateTouch:self.primary_touch down:NO];
        self.primary_touch = nil;
    }
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(nullable UIEvent*)event {
    (void)touches;
    (void)event;
    IosUI::OnTouchCancelled();
    [self updateTouch:nil down:NO];
    self.primary_touch = nil;
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {
    (void)view;
    (void)size;
}

- (void)drawInMTKView:(MTKView*)view {
    @autoreleasepool {
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
            return;
        }
        MTLRenderPassDescriptor* rpd = view.currentRenderPassDescriptor;
        id<CAMetalDrawable> drawable = view.currentDrawable;
        if (!rpd || !drawable || view.bounds.size.width <= 0.0 || view.bounds.size.height <= 0.0) {
            return;
        }

        ImGuiIO& io = ImGui::GetIO();
        float w = static_cast<float>(view.bounds.size.width);
        float h = static_cast<float>(view.bounds.size.height);
        io.DisplaySize = ImVec2(w, h);
        io.DisplayFramebufferScale = ImVec2(
            static_cast<float>(view.drawableSize.width) / w,
            static_cast<float>(view.drawableSize.height) / h);

        CFTimeInterval now = CACurrentMediaTime();
        float dt = (self.last_frame > 0.0) ? static_cast<float>(now - self.last_frame) : (1.0f / 60.0f);
        self.last_frame = now;
        dt = std::clamp(dt, 0.001f, 0.1f);
        io.DeltaTime = dt;

        auto& ctx = IosUIBridge::GetContext();
        const bool protectedNow = FindCaptureContainerForOverlay(self) != nil;
        if (ctx.layout.hideRecording != protectedNow) {
            RyomenXSetCaptureProtectionEnabled(self, ctx.layout.hideRecording ? YES : NO);
        }

        if (ctx.backend) {
            ctx.backend->TickFrame(w, h, dt);
        }

        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);

        id<MTLCommandBuffer> cmdBuf = [self.command_queue commandBuffer];
        ImGui_ImplMetal_NewFrame(rpd);
        ImGui::NewFrame();

        IosUI::RenderFrame();

        BOOL activeNow = ctx.layout.menuBackdropActive ? YES : NO;
        if (activeNow != _prevMenuBackdropActive) {
            _prevMenuBackdropActive = activeNow;
        }
        [self updateMenuBackdrop];

        ImGui::Render();
        id<MTLRenderCommandEncoder> encoder = [cmdBuf renderCommandEncoderWithDescriptor:rpd];
        ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cmdBuf, encoder);
        [encoder endEncoding];
        [cmdBuf presentDrawable:drawable];
        [cmdBuf commit];
    }
}

@end

static __weak RyomenXOverlayView* gOverlayView = nil;
static id _Nullable gBecomeActiveObserver = nil;

static UIWindow* _Nullable FindActiveKeyWindow(void) {
    UIApplication* app = [UIApplication sharedApplication];
    if (@available(iOS 13.0, *)) {
        UIWindow* fallbackWindow = nil;
        for (UIScene* scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene* ws = (UIWindowScene*)scene;
            if (scene.activationState != UISceneActivationStateForegroundActive && fallbackWindow) continue;
            for (UIWindow* win in ws.windows) {
                if (win.isHidden) continue;
                if (win.isKeyWindow) return win;
                if (!fallbackWindow) fallbackWindow = win;
            }
        }
        if (fallbackWindow) return fallbackWindow;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.keyWindow ?: app.windows.firstObject;
#pragma clang diagnostic pop
}

static void RyomenXToggleMenuWithDebounce(void) {
    static CFTimeInterval sLastToggle = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - sLastToggle < 0.40) return;
    sLastToggle = now;

    dispatch_async(dispatch_get_main_queue(), ^{
        auto& ctx = IosUIBridge::GetContext();
        ctx.layout.menuOpen = !ctx.layout.menuOpen;
        IosUI::PushToast(ctx.layout.menuOpen ? "Menu Opened" : "Menu Closed");
    });
}

@interface UIApplication (RyomenXTouchInterceptor)
- (void)ryomenx_sendEvent:(UIEvent *)event;
@end

@implementation UIApplication (RyomenXTouchInterceptor)

- (void)ryomenx_sendEvent:(UIEvent *)event {
    [self ryomenx_sendEvent:event];

    if (event.type == UIEventTypeTouches) {
        NSSet<UITouch*>* touches = [event allTouches];
        if (!touches || touches.count == 0) return;

        int activeTouches = 0;
        for (UITouch* t in touches) {
            if (t.phase == UITouchPhaseBegan || t.phase == UITouchPhaseMoved || t.phase == UITouchPhaseStationary) {
                activeTouches++;
            }
        }

        static int sPeakTouchesThisGesture = 0;
        static CFTimeInterval sGestureStartTime = 0;
        static CFTimeInterval sLastTapEndTime = 0;
        static int sMultiTapCount = 0;

        CFTimeInterval now = CACurrentMediaTime();

        if (activeTouches > 0) {
            if (sPeakTouchesThisGesture == 0) {
                sGestureStartTime = now;
            }
            if (activeTouches > sPeakTouchesThisGesture) {
                sPeakTouchesThisGesture = activeTouches;
            }
        } else {
            // All touches lifted off screen
            if (sPeakTouchesThisGesture >= 3) {
                CFTimeInterval duration = now - sGestureStartTime;
                if (duration <= 0.45) { // Quick tap
                    if (now - sLastTapEndTime <= 0.55) {
                        sMultiTapCount++;
                    } else {
                        sMultiTapCount = 1;
                    }
                    sLastTapEndTime = now;

                    if (sMultiTapCount >= 2) {
                        sMultiTapCount = 0;
                        sLastTapEndTime = 0;
                        RyomenXToggleMenuWithDebounce();
                    }
                }
            } else if (now - sLastTapEndTime > 0.55) {
                sMultiTapCount = 0;
            }
            sPeakTouchesThisGesture = 0;
        }
    }
}

@end

static void RyomenXInstallTouchHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = [UIApplication class];
        SEL origSel = @selector(sendEvent:);
        SEL swizSel = @selector(ryomenx_sendEvent:);
        Method origMethod = class_getInstanceMethod(cls, origSel);
        Method swizMethod = class_getInstanceMethod(cls, swizSel);
        if (origMethod && swizMethod) {
            method_exchangeImplementations(origMethod, swizMethod);
        }
    });
}

void RyomenXAttachOverlayToKeyWindow(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RyomenXAttachOverlayToKeyWindow();
        });
        return;
    }

    RyomenXInstallTouchHook();

    UIWindow* win = FindActiveKeyWindow();
    if (!win) return;
    win.multipleTouchEnabled = YES;

    RyomenXOverlayView* existing = gOverlayView;
    if (existing) {
        if (![existing isDescendantOfView:win]) {
            RyomenXSetCaptureProtectionEnabled(existing, NO);
            [existing removeFromSuperview];
            existing.frame = win.bounds;
            [win addSubview:existing];
        }
        if (IosUIBridge::GetContext().layout.hideRecording) {
            RyomenXSetCaptureProtectionEnabled(existing, YES);
        } else {
            RyomenXSetCaptureProtectionEnabled(existing, NO);
            [win bringSubviewToFront:existing];
        }
        return;
    }

    RyomenXOverlayView* view = [[RyomenXOverlayView alloc] initWithFrame:win.bounds device:MTLCreateSystemDefaultDevice()];
    if (!view) return;

    gOverlayView = view;
    [win addSubview:view];
    [win bringSubviewToFront:view];

    if (IosUIBridge::GetContext().layout.hideRecording) {
        RyomenXSetCaptureProtectionEnabled(view, YES);
    }
}

void RyomenXDetachOverlay(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RyomenXDetachOverlay();
        });
        return;
    }

    RyomenXOverlayView* view = gOverlayView;
    if (!view) return;
    RyomenXSetCaptureProtectionEnabled(view, NO);
    [view removeFromSuperview];
    gOverlayView = nil;
}

RyomenXOverlayView* _Nullable RyomenXGetOverlayView(void) {
    return gOverlayView;
}

void RyomenXSetHostBackend(IosUIBridge::IHostBackend* _Nullable backend) {
    IosUIBridge::GetContext().backend = backend;
}

#ifndef ROSMODV2_DISABLE_AUTO_ATTACH
__attribute__((constructor))
static void RosModV2UI_DylibEntry(void) {
    // Signed iOS builds must not rewrite executable pages during startup.
    RyomenXInstallTouchHook();
    dispatch_async(dispatch_get_main_queue(), ^{
        IosGameBridge::Initialize();
        RyomenXSetHostBackend(&IosGameBridge::Backend());
        if (!gBecomeActiveObserver) {
            gBecomeActiveObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidBecomeActiveNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification* _Nonnull note) {
                            (void)note;
                            RyomenXAttachOverlayToKeyWindow();
                        }];
        }
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
            RyomenXAttachOverlayToKeyWindow();
        }
    });
}
#endif
