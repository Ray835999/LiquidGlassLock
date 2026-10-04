#import "Lockscreen/Common.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGBannerCaptureSupport.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

static void *kLockOriginalTextColorKey = &kLockOriginalTextColorKey;
#ifndef LG_DEBUG_VERBOSE
#define LG_DEBUG_VERBOSE 0
#endif
#if LG_DEBUG_VERBOSE
static void *kLockPlatterDebugLoggedKey = &kLockPlatterDebugLoggedKey;
#endif
static void *kBannerBackdropViewKey = &kBannerBackdropViewKey;
static void *kBannerAttachedKey = &kBannerAttachedKey;
// Banner lifetime is tracked by the weak host registry, so this state only uses link/driver.
static LGDisplayLinkState sBannerDisplayLinkState = {0};
static NSHashTable<UIView *> *sBannerHosts = nil;

BOOL LGIsLockscreenQuickActionsHost(UIView *view);
CGFloat LGLockscreenQuickActionsCornerRadius(UIView *view);

static BOOL LGBannerEnabled(void) {
    return LG_globalEnabled() && LG_prefBool(@"Banner.Enabled", YES);
}

static BOOL LGNotificationGlassEnabled(void) {
    return LGLockscreenEnabled();
}

static NSHashTable<UIView *> *LGBannerHostRegistry(void) {
    if (!sBannerHosts) {
        sBannerHosts = [NSHashTable weakObjectsHashTable];
    }
    return sBannerHosts;
}

static NSUInteger LGBannerLiveHostCount(void) {
    return [LGBannerHostRegistry().allObjects count];
}

static BOOL LGHasBannerPresentationContext(UIView *view) {
    if (!view || !view.window) return NO;
    if ([NSStringFromClass(view.window.class) isEqualToString:LGBannerWindowClassName]) return YES;
    if (LGHasAncestorClassNamed(view, LGBannerContentViewClassName)) return YES;
    if (LGResponderChainContainsClassNamed(view, LGBannerControllerClassName)) return YES;
    if (LGResponderChainContainsClassNamed(view, LGBannerPresentableControllerClassName)) return YES;
    return NO;
}

static void LGStartBannerDisplayLink(void) {
    LGAssertMainThread();
    if (sBannerDisplayLinkState.link || !LGBannerEnabled()) return;
    LGStartDisplayLinkState(&sBannerDisplayLinkState, 60, ^{
        LGRefreshBannerPlatterHosts();
    });
}

static void LGStopBannerDisplayLink(void) {
    LGAssertMainThread();
    LGStopDisplayLinkState(&sBannerDisplayLinkState);
}

static void LGAttachBannerHostIfNeeded(UIView *view) {
    LGAssertMainThread();
    if (!view) return;
    if ([objc_getAssociatedObject(view, kBannerAttachedKey) boolValue]) return;
    objc_setAssociatedObject(view, kBannerAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [LGBannerHostRegistry() addObject:view];
    LGStartBannerDisplayLink();
}

static void LGDetachBannerHostIfNeeded(UIView *view) {
    LGAssertMainThread();
    if (!view) return;
    if (![objc_getAssociatedObject(view, kBannerAttachedKey) boolValue]) return;
    objc_setAssociatedObject(view, kBannerAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LGRemoveLiveBackdropCaptureView(view, kBannerBackdropViewKey);
    [LGBannerHostRegistry() removeObject:view];
    if (LGBannerLiveHostCount() == 0) {
        LGStopBannerDisplayLink();
    }
}

static void LG_lockscreenPrefsChanged(CFNotificationCenterRef center,
                                      void *observer,
                                      CFStringRef name,
                                      const void *object,
                                      CFDictionaryRef userInfo) {
    LGInvalidateLockscreenSnapshotCache();
    dispatch_async(dispatch_get_main_queue(), ^{
        LGLockscreenRefreshAllHosts();
    });
}

static BOOL isInsidePlatterView(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"PLPlatterView");
    UIView *v = view.superview;
    while (v) {
        if ([v isKindOfClass:cls]) return YES;
        v = v.superview;
    }
    return NO;
}

static BOOL isInsideSwitcherSuggestionBanner(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"SBSwitcherAppSuggestionBannerView");
    UIView *v = view;
    while (v) {
        if ([v isKindOfClass:cls]) return YES;
        v = v.superview;
    }
    return NO;
}

static BOOL hasMaterialAncestorBeforeClass(UIView *view, Class stopClass) {
    static Class materialCls;
    if (!materialCls) materialCls = NSClassFromString(@"MTMaterialView");
    UIView *v = view.superview;
    while (v) {
        if (stopClass && [v isKindOfClass:stopClass]) return NO;
        if (materialCls && [v isKindOfClass:materialCls]) return YES;
        v = v.superview;
    }
    return NO;
}

static BOOL isPrimaryPlatterMaterialHost(UIView *view) {
    static Class platterCls, materialCls;
    if (!platterCls) platterCls = NSClassFromString(@"PLPlatterView");
    if (!materialCls) materialCls = NSClassFromString(@"MTMaterialView");
    if (!materialCls || ![view isKindOfClass:materialCls]) return NO;
    if (isInsideSwitcherSuggestionBanner(view)) return NO;
    if (!isInsidePlatterView(view)) return NO;
    return !hasMaterialAncestorBeforeClass(view, platterCls);
}

static BOOL isBannerPlatterHost(UIView *view) {
    if (!view || !isPrimaryPlatterMaterialHost(view) || !view.window) return NO;
    return LGHasBannerPresentationContext(view);
}

static BOOL LGViewLooksLikeBannerContext(UIView *view) {
    return LGHasBannerPresentationContext(view);
}

#if LG_DEBUG_VERBOSE
static NSString *LGViewAncestorClassChain(UIView *view, NSUInteger maxDepth) {
    if (!view) return @"(null)";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    UIView *current = view;
    NSUInteger depth = 0;
    while (current && depth < maxDepth) {
        [parts addObject:NSStringFromClass(current.class)];
        current = current.superview;
        depth++;
    }
    if (current) [parts addObject:@"..."];
    return [parts componentsJoinedByString:@" > "];
}

static NSString *LGResponderClassChain(UIResponder *responder, NSUInteger maxDepth) {
    if (!responder) return @"(null)";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    UIResponder *current = responder;
    NSUInteger depth = 0;
    while (current && depth < maxDepth) {
        [parts addObject:NSStringFromClass(current.class)];
        current = current.nextResponder;
        depth++;
    }
    if (current) [parts addObject:@"..."];
    return [parts componentsJoinedByString:@" > "];
}
#endif

#if LG_DEBUG_VERBOSE
static BOOL LGPlatterHostLooksLikeLockscreenContext(UIView *view) {
    if (!view) return NO;
    if (LGHasAncestorClassNamed(view, @"CSCombinedListView")) return YES;
    if (LGHasAncestorClassNamed(view, @"NCNotificationListView")) return YES;
    if (LGHasAncestorClassNamed(view, @"NCNotificationCombinedListView")) return YES;
    if (LGResponderChainContainsClassNamed(view, @"SBCoverSheetViewController")) return YES;
    if (LGResponderChainContainsClassNamed(view, @"SBDashBoardViewController")) return YES;
    if (LGResponderChainContainsClassNamed(view, @"CSCombinedListViewController")) return YES;
    if (view.window && [NSStringFromClass(view.window.class) containsString:@"CoverSheet"]) return YES;
    return NO;
}

static BOOL LGPlatterHostLooksLikeBannerContext(UIView *view) {
    if (!view) return NO;
    if (LGHasBannerPresentationContext(view)) return YES;
    if (LGHasAncestorClassNamed(view, @"NCNotificationShortLookView")) return YES;
    if (LGHasAncestorClassNamed(view, @"NCNotificationLongLookView")) return YES;
    if (LGResponderChainContainsClassNamed(view, @"NCNotificationShortLookViewController")) return YES;
    if (LGResponderChainContainsClassNamed(view, @"NCNotificationLongLookViewController")) return YES;
    if (view.window && [NSStringFromClass(view.window.class) containsString:@"Banner"]) return YES;
    return NO;
}
#endif

static void LGInjectBannerPlatterGlass(UIView *host) {
    LGAssertMainThread();
    if (!LGBannerEnabled()) {
        LGDebugLog(@"banner inject bail reason=disabled host=%@",
                   host ? NSStringFromClass(host.class) : @"(null)");
        LGRemoveLiveBackdropCaptureView(host, kBannerBackdropViewKey);
        LGCleanupLockscreenHost(host);
        return;
    }

    CGFloat configuredBlur = LG_prefFloat(@"Banner.Blur", LGBannerDefaultBlur);
    CGFloat effectiveBlur = LGEffectiveBannerBlur(configuredBlur);

    CGFloat cornerRadius = LG_prefFloat(@"Banner.CornerRadius", LGBannerDefaultCornerRadius);
    LiquidGlassView *glass = LGLockscreenEnsureConfiguredGlass(host,
                                                               CGPointZero,
                                                               LGUpdateGroupLockscreen,
                                                               cornerRadius,
                                                               LG_prefFloat(@"Banner.BezelWidth", LGBannerDefaultBezelWidth),
                                                               LG_prefFloat(@"Banner.GlassThickness", LGBannerDefaultGlassThickness),
                                                               LG_prefFloat(@"Banner.RefractionScale", LGBannerDefaultRefractionScale),
                                                               LG_prefFloat(@"Banner.RefractiveIndex", LGBannerDefaultRefractiveIndex),
                                                               LG_prefFloat(@"Banner.SpecularOpacity", LGBannerDefaultSpecularOpacity),
                                                               effectiveBlur,
                                                               LGBannerDefaultWallpaperScale,
                                                               LG_prefFloat(@"Banner.LightTintAlpha", LGBannerDefaultLightTintAlpha),
                                                               LG_prefFloat(@"Banner.DarkTintAlpha", LGBannerDefaultDarkTintAlpha));
    if (!glass) return;
    CGPoint fallbackOrigin = CGPointZero;
    UIImage *fallbackSnapshot = LG_getHomescreenSnapshot(&fallbackOrigin);
    if (!LGApplyRenderingModeToGlassHost(host,
                                         glass,
                                         @"Banner.RenderingMode",
                                         kBannerBackdropViewKey,
                                         fallbackSnapshot,
                                         fallbackOrigin)) {
        LGDebugLog(@"banner inject bail reason=rendering-mode-failed host=%@ fallbackSnapshot=%d",
                   host ? NSStringFromClass(host.class) : @"(null)",
                   fallbackSnapshot ? 1 : 0);
        LGCleanupLockscreenHost(host);
        return;
    }
}

void LGRefreshBannerPlatterHosts(void) {
    LGAssertMainThread();
    NSArray<UIView *> *liveHosts = [LGBannerHostRegistry() allObjects];
    if (liveHosts.count == 0) {
        LGStopBannerDisplayLink();
        return;
    }
    if (!LGBannerEnabled()) {
        for (UIView *view in liveHosts) {
            LGDetachBannerHostIfNeeded(view);
        }
        LGStopBannerDisplayLink();
        return;
    }
    for (UIView *view in liveHosts) {
        if (!view.window || view.hidden || view.alpha <= 0.01f || view.layer.opacity <= 0.01f) continue;
        if (!isBannerPlatterHost(view)) continue;
        LGInjectBannerPlatterGlass(view);
    }
}

#if LG_DEBUG_VERBOSE
static void LGLogPrimaryPlatterHostContext(UIView *view, NSString *phase) {
    if (!view || !isPrimaryPlatterMaterialHost(view) || !view.window) return;
    if ([objc_getAssociatedObject(view, kLockPlatterDebugLoggedKey) boolValue]) return;
    objc_setAssociatedObject(view, kLockPlatterDebugLoggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIWindow *window = view.window;
    NSString *sceneState = @"(none)";
    if (@available(iOS 13.0, *)) {
        if (window.windowScene) {
            switch (window.windowScene.activationState) {
                case UISceneActivationStateForegroundActive: sceneState = @"foregroundActive"; break;
                case UISceneActivationStateForegroundInactive: sceneState = @"foregroundInactive"; break;
                case UISceneActivationStateBackground: sceneState = @"background"; break;
                case UISceneActivationStateUnattached: sceneState = @"unattached"; break;
            }
        }
    }

    BOOL hasPlatterAncestor = LGHasAncestorClassNamed(view, @"PLPlatterView");
    BOOL hasShortLookAncestor = LGHasAncestorClassNamed(view, @"NCNotificationShortLookView");
    BOOL hasLongLookAncestor = LGHasAncestorClassNamed(view, @"NCNotificationLongLookView");
    BOOL hasCombinedListAncestor = LGHasAncestorClassNamed(view, @"CSCombinedListView");
    BOOL hasListResponder = LGResponderChainContainsClassNamed(view, @"CSCombinedListViewController");
    BOOL hasCoverResponder = LGResponderChainContainsClassNamed(view, @"SBCoverSheetViewController");
    BOOL hasDashResponder = LGResponderChainContainsClassNamed(view, @"SBDashBoardViewController");
    BOOL hasShortResponder = LGResponderChainContainsClassNamed(view, @"NCNotificationShortLookViewController");
    BOOL hasLongResponder = LGResponderChainContainsClassNamed(view, @"NCNotificationLongLookViewController");

    LGLog(@"platter host phase=%@ host=%@ frame=%@ window=%@ level=%.1f scene=%@ lockCtx=%d bannerCtx=%d platter=%d shortLook=%d/%d longLook=%d/%d combined=%d/%d cover=%d dash=%d",
          phase ?: @"(unknown)",
          NSStringFromClass(view.class),
          NSStringFromCGRect(view.frame),
          NSStringFromClass(window.class),
          (double)window.windowLevel,
          sceneState,
          LGPlatterHostLooksLikeLockscreenContext(view),
          LGPlatterHostLooksLikeBannerContext(view),
          hasPlatterAncestor,
          hasShortLookAncestor,
          hasShortResponder,
          hasLongLookAncestor,
          hasLongResponder,
          hasCombinedListAncestor,
          hasListResponder,
          hasCoverResponder,
          hasDashResponder);
    LGLog(@"platter host ancestors=%@", LGViewAncestorClassChain(view, 14));
    LGLog(@"platter host responders=%@", LGResponderClassChain(view, 14));
}
#endif

static BOOL isInsideActionButton(UIView *view) {
    static Class cls;
    if (!cls) {
        cls = NSClassFromString(LGIsAtLeastiOS16()
            ? @"PLPlatterActionButton"
            : @"NCNotificationListCellActionButton");
    }
    UIView *v = view.superview;
    while (v) {
        if ([v isKindOfClass:cls]) return YES;
        v = v.superview;
    }
    return NO;
}

static BOOL isPrimaryActionButtonMaterialHost(UIView *view) {
    static Class actionCls, materialCls;
    if (!actionCls) {
        actionCls = NSClassFromString(LGIsAtLeastiOS16()
            ? @"PLPlatterActionButton"
            : @"NCNotificationListCellActionButton");
    }
    if (!materialCls) materialCls = NSClassFromString(@"MTMaterialView");
    if (!materialCls || ![view isKindOfClass:materialCls]) return NO;
    if (isInsideSwitcherSuggestionBanner(view)) return NO;
    if (!isInsideActionButton(view)) return NO;
    return !hasMaterialAncestorBeforeClass(view, actionCls);
}

static CGFloat LGNotificationActionButtonCornerRadius(UIView *view) {
    CGFloat fallbackRadius = LGIsAtLeastiOS16() ? 23.5f : 14.0f;
    return LGLockscreenResolvedCornerRadius(view, fallbackRadius);
}

static BOOL LGLabelBelongsToNotificationPlatter(UILabel *label) {
    if (!label) return NO;
    if (LGHasAncestorClassNamed(label, @"NCNotificationSeamlessContentView")) return YES;
    if (LGHasAncestorClassNamed(label, @"NCNotificationShortLookView")) return YES;
    if (LGHasAncestorClassNamed(label, @"NCNotificationLongLookView")) return YES;
    if (LGHasAncestorClassNamed(label, @"PLPlatterView")) return YES;
    return NO;
}

static void updateSeamlessLabelColor(UILabel *label) {
    if (!label.window) return;
    if (!LGLabelBelongsToNotificationPlatter(label)) return;
    if (!objc_getAssociatedObject(label, kLockOriginalTextColorKey) && label.textColor) {
        objc_setAssociatedObject(label, kLockOriginalTextColorKey, label.textColor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (LGLockscreenEnabled()) {
        if (LGViewLooksLikeBannerContext(label)) {
            if (@available(iOS 12.0, *)) {
                UITraitCollection *traits = label.traitCollection ?: UIScreen.mainScreen.traitCollection;
                label.textColor = (traits.userInterfaceStyle == UIUserInterfaceStyleDark)
                    ? UIColor.whiteColor
                    : UIColor.blackColor;
            } else {
                label.textColor = UIColor.blackColor;
            }
        } else {
            label.textColor = UIColor.whiteColor;
        }
    } else {
        UIColor *original = objc_getAssociatedObject(label, kLockOriginalTextColorKey);
        if (original) label.textColor = original;
    }
}

void LGLockscreenRefreshAllHosts(void) {
    UIApplication *app = UIApplication.sharedApplication;
    void (^refreshWindow)(UIWindow *) = ^(UIWindow *window) {
        LGTraverseViews(window, ^(UIView *view) {
            if ([view isKindOfClass:[UILabel class]]) {
                updateSeamlessLabelColor((UILabel *)view);
                return;
            }
            if ([view isKindOfClass:NSClassFromString(@"MTMaterialView")]) {
                if (isPrimaryPlatterMaterialHost(view)) {
                    if (isBannerPlatterHost(view)) {
                        LGInjectBannerPlatterGlass(view);
                    } else {
                        LGLockscreenInjectGlass(view, LGLockscreenCornerRadius());
                    }
                    LGAttachLockHostIfNeeded(view);
                    return;
                }
                if (isPrimaryActionButtonMaterialHost(view)) {
                    LGLockscreenInjectGlass(view, LGNotificationActionButtonCornerRadius(view));
                    LGAttachLockHostIfNeeded(view);
                    return;
                }
            }
            if (LGIsLockscreenQuickActionsHost(view)) {
                if (LG_prefBool(@"LockscreenQuickActions.Enabled", YES)) {
                    CGFloat cornerRadius = LGLockscreenQuickActionsCornerRadius(view);
                    LGLockscreenInjectGlassWithSettingsAndMode(view,
                                                               @"LockscreenQuickActions.RenderingMode",
                                                               cornerRadius,
                                                               LG_prefFloat(@"LockscreenQuickActions.BezelWidth", 12.0),
                                                               LG_prefFloat(@"LockscreenQuickActions.GlassThickness", 80.0),
                                                               LG_prefFloat(@"LockscreenQuickActions.RefractionScale", 1.2),
                                                               LG_prefFloat(@"LockscreenQuickActions.RefractiveIndex", 1.0),
                                                               LG_prefFloat(@"LockscreenQuickActions.SpecularOpacity", 0.6),
                                                               LG_prefFloat(@"LockscreenQuickActions.Blur", 8.0),
                                                               LG_prefFloat(@"LockscreenQuickActions.WallpaperScale", 0.5),
                                                               LG_prefFloat(@"LockscreenQuickActions.LightTintAlpha", 0.1),
                                                               LG_prefFloat(@"LockscreenQuickActions.DarkTintAlpha", 0.6));
                    LGAttachLockHostIfNeeded(view);
                } else {
                    LGCleanupLockscreenHost(view);
                }
            }
        });
    };
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) refreshWindow(window);
        }
    } else {
        for (UIWindow *window in LGApplicationWindows(app)) refreshWindow(window);
    }
}

// ---------------------------------------------------------------------------
// LiquidGlassLock v3 — lockscreen + Control Center module glass.
//
// Upstream only glassifies PLPlatterView-based notification hosts. A real iOS
// 15.8.8 log showed 30 MTMaterialView instances and NOT ONE with a PLPlatterView
// ancestor: 25 were in SBControlCenterWindow (CCUIContentModuleContainerView,
// MRUControlCenterView, CCUIContinuousSliderView, FCUIActivityControl,
// MediaControlsMaterialView) and 2 were full-screen coversheet backdrops.
// Pulling down on the lockscreen therefore produced no glass at all, because
// Control Center modules were never a supported surface.
//
// Accept module-sized material views in the coversheet / control center windows,
// excluding full-screen backdrops and collapsed (0x0) views.
// ---------------------------------------------------------------------------
static BOOL LGIsLockOrControlCenterWindow(UIView *view) {
    if (!view || !view.window) return NO;
    NSString *w = NSStringFromClass(view.window.class);
    return [w isEqualToString:@"SBCoverSheetWindow"] || [w isEqualToString:@"SBControlCenterWindow"];
}

static BOOL LGIsModuleSizedGlassCandidate(UIView *view) {
    if (!view) return NO;
    if (!LGIsLockOrControlCenterWindow(view)) return NO;   // home screen stays untouched
    CGRect f = view.bounds;
    if (f.size.width < 40.0 || f.size.height < 20.0) return NO;        // collapsed / hidden
    if (f.size.width >= 300.0 && f.size.height >= 480.0) return NO;    // full-screen backdrop blur
    return YES;
}

static NSHashTable<UIView *> *sLGModuleHosts = nil;
static NSHashTable<UIView *> *LGModuleHostRegistry(void) {
    if (!sLGModuleHosts) sLGModuleHosts = [NSHashTable weakObjectsHashTable];
    return sLGModuleHosts;
}

static void LGInjectModuleGlassIfNeeded(UIView *view) {
    LGAssertMainThread();
    if (!view || !LGNotificationGlassEnabled()) return;
    if (!LGIsModuleSizedGlassCandidate(view)) return;

    NSHashTable<UIView *> *reg = LGModuleHostRegistry();
    BOOL known = [reg containsObject:view];
    // Perf guard: A9 cannot afford to refract an unbounded number of hosts per frame.
    if (!known && reg.allObjects.count >= 16) return;

    CGFloat radius = LGLockscreenResolvedCornerRadius(view, 18.5);
    LGLockscreenInjectGlass(view, radius);
    LGAttachLockHostIfNeeded(view);

    if (!known) {
        [reg addObject:view];
        LGLLog([NSString stringWithFormat:@"[module] new host #%lu %@ frame=%@ radius=%.1f",
                (unsigned long)reg.allObjects.count,
                NSStringFromClass(view.class),
                NSStringFromCGRect(view.frame),
                radius]);
    }
}

%group LGPlatterSpringBoard

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;

    if (!self_.window) {
#if LG_DEBUG_VERBOSE
        objc_setAssociatedObject(self_, kLockPlatterDebugLoggedKey, nil, OBJC_ASSOCIATION_ASSIGN);
#endif
        LGDetachBannerHostIfNeeded(self_);
        LGDetachLockHostIfNeeded(self_);
        return;
    }

    if (isPrimaryPlatterMaterialHost(self_)) {
#if LG_DEBUG_VERBOSE
        LGLogPrimaryPlatterHostContext(self_, @"didMove");
#endif
        if (isBannerPlatterHost(self_)) {
            LGInjectBannerPlatterGlass(self_);
            if (LGBannerEnabled()) LGAttachBannerHostIfNeeded(self_);
            else LGDetachBannerHostIfNeeded(self_);
        } else {
            if (LGNotificationGlassEnabled()) {
                LGLockscreenInjectGlass(self_, LGLockscreenCornerRadius());
                LGAttachLockHostIfNeeded(self_);
            } else {
                LGCleanupLockscreenHost(self_);
            }
        }
    } else if (isPrimaryActionButtonMaterialHost(self_)) {
        if (LGNotificationGlassEnabled()) {
            LGLockscreenInjectGlass(self_, LGNotificationActionButtonCornerRadius(self_));
            LGAttachLockHostIfNeeded(self_);
        } else {
            LGCleanupLockscreenHost(self_);
        }
    } else {
        if (LGIsModuleSizedGlassCandidate(self_)) {
            LGInjectModuleGlassIfNeeded(self_);
        } else if (LGIsLockOrControlCenterWindow(self_)) {
            // Only log surfaces we actually target, otherwise the log is 90% home screen noise.
            static int sLGSkipLogged = 0;
            if (sLGSkipLogged < 30) {
                sLGSkipLogged++;
                NSMutableArray<NSString *> *chain = [NSMutableArray array];
                UIView *v = self_.superview;
                for (int d = 0; v && d < 10; d++) {
                    [chain addObject:NSStringFromClass(v.class)];
                    v = v.superview;
                }
                LGLLog([NSString stringWithFormat:
                        @"[skip] MTMaterialView not a platter host (#%d) frame=%@ window=%@ ancestors=%@",
                        sLGSkipLogged,
                        NSStringFromCGRect(self_.frame),
                        NSStringFromClass(self_.window.class),
                        chain.count ? [chain componentsJoinedByString:@" > "] : @"(none)"]);
            }
        }
        return;
    }
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!self_.window) return;

    if (isPrimaryPlatterMaterialHost(self_)) {
#if LG_DEBUG_VERBOSE
        LGLogPrimaryPlatterHostContext(self_, @"layout");
#endif
        if (isBannerPlatterHost(self_)) {
            LGInjectBannerPlatterGlass(self_);
            if (LGBannerEnabled()) LGAttachBannerHostIfNeeded(self_);
            else LGDetachBannerHostIfNeeded(self_);
        } else {
            if (LGNotificationGlassEnabled()) {
                LGLockscreenInjectGlass(self_, LGLockscreenCornerRadius());
                LGAttachLockHostIfNeeded(self_);
            } else {
                LGCleanupLockscreenHost(self_);
            }
        }
        return;
    }
    if (isPrimaryActionButtonMaterialHost(self_)) {
        if (LGNotificationGlassEnabled()) {
            LGLockscreenInjectGlass(self_, LGNotificationActionButtonCornerRadius(self_));
            LGAttachLockHostIfNeeded(self_);
        } else {
            LGCleanupLockscreenHost(self_);
        }
    } else {
        // LiquidGlassLock v3: coversheet / Control Center module glass.
        // Module bounds are only final after layout, so this path matters.
        LGInjectModuleGlassIfNeeded(self_);
    }
}

%end

%hook UILabel

- (void)didMoveToWindow {
    %orig;
    updateSeamlessLabelColor(self);
}

- (void)layoutSubviews {
    %orig;
    updateSeamlessLabelColor(self);
}

%end

%hook SBCoverSheetViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    LGRefreshLockSnapshotAfterDelay(0.12);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    LGRefreshLockSnapshotAfterDelay(0.45);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    LGInvalidateLockscreenSnapshotCache();
}

%end

%hook SBDashBoardViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    LGRefreshLockSnapshotAfterDelay(0.12);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    LGRefreshLockSnapshotAfterDelay(0.45);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    LGInvalidateLockscreenSnapshotCache();
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    LGObservePreferenceChanges(^{
        LG_lockscreenPrefsChanged(NULL, NULL, NULL, NULL, NULL);
    });
    %init(LGPlatterSpringBoard);
}
