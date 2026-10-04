# LiquidGlassLock — iOS 26 Liquid Glass, LOCK SCREEN ONLY.
#
# Fork of Liquidass (dylv, MIT) reduced to the lockscreen surfaces.
# Build:  make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
#
# Why this exists: upstream Liquidass cannot run Home Screen + App Library +
# Lock Screen at the same time (the other surfaces go black). This fork never
# compiles the Home/AppLibrary/Dock/Folder/Widget/SearchPill/ContextMenu hooks
# in the first place, so there is nothing left to conflict.

TARGET := iphone:clang:15.6:14.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidGlassLock

# v4: lockscreen surfaces + control center + widgets.
# Explicit list, NOT $(wildcard Hooks/*.x) — several upstream hooks default to
# ENABLED (Dock / AppLibrary / FolderIcon / FolderOpen / SearchPill / ContextMenu),
# and turning them all on at once is exactly what produces the upstream
# "other surfaces render black" bug. PreferencesControls.x additionally imports
# the prefs bundle headers we no longer ship, so it must never be compiled.
HOOK_FILES := Hooks/Platter.x Hooks/Widgets.x $(wildcard Hooks/Lockscreen/*.x)

SHARED_FILES := Shared/LGSharedSupport.m \
                Shared/LGHookSupport.m \
                Shared/LGBannerCaptureSupport.m \
                Shared/LGMetalShaderSource.m \
                Shared/LGGlassRenderer.m \
                Shared/LGBackButtonSupport.m \
                Shared/LGRWBSupport.m

RUNTIME_FILES := Runtime/LGLiquidGlassRuntime.m \
                 Runtime/LGSnapshotCaptureSupport.m

$(TWEAK_NAME)_FILES = Tweak.x $(HOOK_FILES) $(SHARED_FILES) $(RUNTIME_FILES)
$(TWEAK_NAME)_CFLAGS = -fobjc-arc
$(TWEAK_NAME)_FRAMEWORKS = UIKit Metal MetalKit Accelerate

include $(THEOS_MAKE_PATH)/tweak.mk
