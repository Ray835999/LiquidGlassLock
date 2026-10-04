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

## v1.0.0-4: widget glass

v4 adds `Hooks/Widgets.x`, so the **Today View / home screen widgets** get the same
Metal refraction. Upstream ships `Widgets.Enabled` **off** by default, so the flag is
flipped to `YES` in `Hooks/Widgets.x` — otherwise it compiles in and still renders
nothing (the same silent-no-op class of bug as `Global.Enabled`).

Still deliberately NOT compiled: `Dock`, `AppLibrary`, `AppIcons`, `FolderIcon`,
`FolderOpen`, `SearchPill`, `ContextMenu`, `PreferencesControls`. Several of those
default to **enabled** upstream, and turning them all on at once is exactly what
causes the "other surfaces render black" bug. `PreferencesControls.x` additionally
imports the prefs-bundle headers this fork no longer ships, so it can never compile.

`Hooks/` intentionally keeps only `Platter.x`, `Widgets.x` and `Lockscreen/*.x`, and
the Makefile lists them explicitly instead of using `$(wildcard Hooks/*.x)`.

## Recovery (if v4 looks wrong)

Widget glass is the most demanding surface on an A9. If SpringBoard goes black or
loops: **reboot into the unjailbroken state, then re-boot while holding Volume Down**
to enter Safe Mode (no tweaks loaded), and uninstall `com.you.liquidglasslock`.

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

### v1.0.0-2 and later: read the log file, no terminal needed

The tweak writes to **`/var/mobile/Documents/LiquidGlassLock.log`**. Open it with **Filza**
after a respring. Lines to look for:

```
[LiquidGlassLock] [load] loaded into com.apple.springboard | iOS 15.8.8 | globalEnabled=1 lockscreenEnabled=1
[LiquidGlassLock] [inject] FIRST host=MTMaterialView enabled=1 radius=18.50
[LiquidGlassLock] [skip] MTMaterialView not a platter host (#1) frame=... ancestors=... > ...
```

| Log says | Meaning | Fix |
|---|---|---|
| nothing at all | dylib not loaded | check `LiquidGlassLock.dylib` + `.plist` are in `/var/jb/Library/MobileSubstrate/DynamicLibraries/` |
| `[load] ... globalEnabled=0` | prefs say off | delete `.../Preferences/com.you.liquidglasslock.plist` |
| `[load]` but no `[inject]` and no `[skip]` | no `MTMaterialView` exists on screen | there is genuinely no notification platter / media player to glassify |
| `[load]` + `[skip] ... ancestors=...` | views exist but iOS 15 nests them differently than `PLPlatterView` | send the ancestor chain — that dictates the next fix |

### Or via syslog

```bash
log stream --predicate 'process == "SpringBoard"' | grep LiquidGlassLock
```

- Only the first line → dylib loaded, but no platter host was ever seen.
- No lines at all → dylib not loaded (check the filter plist / ElleKit).

## License

MIT — see `LICENSE` (original author dylv).
