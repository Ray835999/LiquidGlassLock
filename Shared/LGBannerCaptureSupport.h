#pragma once

#import <UIKit/UIKit.h>

@class LiquidGlassView;

void LGRemoveLiveBackdropCaptureView(UIView *host, const void *associationKey);
BOOL LGCaptureLiveBackdropTextureForHost(UIView *host,
                                         LiquidGlassView *glass,
                                         const void *associationKey,
                                         CGPoint *outOrigin,
                                         CGSize *outSamplingResolution);
BOOL LGApplyRenderingModeToGlassHost(UIView *host,
                                     LiquidGlassView *glass,
                                     NSString *renderingModeKey,
                                     const void *associationKey,
                                     UIImage *snapshot,
                                     CGPoint snapshotOrigin);
