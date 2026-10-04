# LiquidGlassLock

iOS 26 **Liquid Glass** on the lock screen — for **rootless** jailbreaks
(palera1n / Dopamine), iOS 14–16. Built for **iPhone 6s / iOS 15.8.8 / arm64**.

This is a **lockscreen-only fork of [Liquidass](https://github.com/TrollStoreX/liquidass)
by dylv** (MIT). All credit for the Metal glass renderer goes to dylv.

## Why a fork

Upstream Liquidass injects glass into Home Screen, App Library, Dock, folders,
widgets, Search pill, Settings, Clock and the lock screen. It **cannot run
Home Screen + App Library + Lock Screen at the same time** — enabling several
surfaces makes the others render **black**.

This fork does not ship those hooks at all. `Makefile` compiles only:

- `Hooks/Platter.x` — notification + banner platters, quick actions
- `Hooks/Lockscreen/*.x` — clock, passcode, quick actions

So there is nothing left to conflict: lock screen glass, no black surfaces.

## Notable change vs upstream

`Shared/LGSharedSupport.m`:

```objc
// upstream
return LG_prefBool(@"Global.Enabled", NO);
// this fork (no prefs bundle is shipped, so the default must be ON)
return LG_prefBool(@"Global.Enabled", YES);
```

Without this, `Global.Enabled` defaults to `NO` and **every** surface silently
no-ops — the tweak would install fine and do nothing.

## Build

```bash
make package THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
```

Or push to `main`: `.github/workflows/build.yml` builds with theos +
iPhoneOS 15.6 SDK + L1ghtmann toolchain on `ubuntu-latest`.

## Install (palera1n rootless)

```bash
# copy the deb to the device, then
dpkg -i /var/mobile/Documents/com.you.liquidglasslock_1.0.0-1_iphoneos-arm64.deb
killall -9 SpringBoard        # or: sbreload
```

Files land in `/var/jb/Library/MobileSubstrate/DynamicLibraries/`.

## Verify it actually ran

A successful install is **not** proof. Grep SpringBoard's syslog:

```bash
log stream --predicate 'process == "SpringBoard"' | grep LiquidGlassLock
```

Expected:

```
[LiquidGlassLock] loaded lockscreen-only build into com.apple.springboard globalEnabled=1 lockscreenEnabled=1
[LiquidGlassLock] inject host=MTMaterialView enabled=1 radius=18.50
```

- Only the first line → dylib loaded, but no platter host was ever seen.
- No lines at all → dylib not loaded (check the filter plist / ElleKit).
- `globalEnabled=0` → `Global.Enabled` got written to `NO` somewhere;
  delete `/var/jb/var/mobile/Library/Preferences/dylv.liquidassprefs.plist`.

## License

MIT — see `LICENSE` (original author dylv).
