# Keystrike

Mechanical keyboard sounds for your MacBook, chosen by how hard you actually type.

Keystrike listens to the MacBook's built-in accelerometer, reads the chassis
vibration each keystroke makes in the aluminium, and picks the matching sound:
a brushed key stays soft, a real press sits in the middle, a slammed key lands
on the slam tier - continuously crossfaded, not stepped.

It is an open-source take on apps like Haptyk and Thock, built end-to-end:
a real-time C audio engine, force sensing from the laptop's own sensor, and
16 switch packs.

```
keystroke ──▶ SPU accelerometer ──▶ force 0..1 ──▶ tier crossfade ──▶ clip
              chassis vibration      gravity-removed              48 kHz RAM
                                     adaptive noise floor         voice mixer
```

## What is verified

Everything below was run on a MacBook Air (M5, macOS 27.2, Swift 6.4.2):

| Check | Result |
|---|---|
| `AppleSPUHIDDevice` access without root | opens, streams at **805 Hz** |
| Core Audio negotiation | **48 kHz / 128 frames / 2.67 ms** round trip |
| Pack loading | 16 packs, 892 clips, `cream` = 48 clips |
| Offline render (`make test-offline`) | 6 s stereo WAV, peak 0.818, 17/17 voices, 0 drops |
| Live render + mixing | **2150 render callbacks, 86 voices, 0 dropped** over a scripted stream |
| Force mapping (`KS_FORCE_TEST=1`) | 5/5 synthetic bursts detected, peaks matched to 3 %, scores monotonic soft → slam |

Not yet verified end-to-end: keystrokes from the event tap driving all of the
above, because granting Accessibility permission needs a human (see
[Permissions](#permissions)). Everything on either side of that tap is tested.

## Build and run

```sh
make app      # swift build + Keystrike.app (ad-hoc signed, no Xcode needed)
make run      # build and open it
make dmg      # a drag-to-install Keystrike.dmg (release by default)
```

The app is a menu-bar agent: no Dock icon, click the waveform icon for the
menu, or `Settings…` for pack, force, audio and general panes.

```sh
make test-offline   # render a WAV through the engine with no output device
make packs          # rebuild all 16 packs from the upstream recordings
make clean
```

`make dmg` produces `.build/dmg/Keystrike-<version>.dmg`: the `.app` plus an
`Applications` symlink, verified by mounting it back after writing. Nothing
in the DMG is signed beyond the app's ad-hoc signature, so the first run needs
a right-click → Open, then the Accessibility grant below.
Environment variables (useful for CI and headless checks):

| Variable | Effect |
|---|---|
| `KS_FORCE_TEST=1` | feed synthetic keystrokes through the detector, log the scores |
| `KS_SELFTEST=1` | play a scripted 4 s stream, report render/voice counts |
| `THOCK_DEBUG=1` | verbose Core Audio logging (stderr) |
| `KS_PACKS=…` | override the pack directory |

Logs land in `~/Library/Logs/Keystrike/keystrike.log`.

## How it works

**Sensing.** The MacBook has an undocumented HID device, `AppleSPUHIDDevice`,
that reports accelerometer samples at ~1 kHz. Keystrike opens it through IOKit
(`Sources/ThockSPU`, no root, no kernel extension) and reads three int32 Q16
values per report. Samples are stamped with `mach_absolute_time()` in-process,
so key events and chassis vibrations share one clock.

**Force.** `Sources/keystrike/ForceDetector.swift`:

1. removes gravity with a slow per-axis EMA (frozen while an impact is in
   flight, so a strike does not drag the resting point with it);
2. tracks an adaptive noise floor that falls fast on a quiet desk and rises
   slowly when the laptop is being handled;
3. gates impacts with a threshold combining that floor and the sensitivity
   control, holds the peak for ~90 ms, and applies a refractory period so one
   strike is scored once;
4. correlates the onset with the keystroke timestamp, waiting a few
   milliseconds for the vibration to reach its peak rather than guessing from
   the first sample.

Force is a continuous 0…1 value, mapped onto soft/medium/hard/slam with
boundaries at 0.25/0.5/0.75 and a crossfade between neighbouring tiers in the
mixer, so pressing a bit harder never sounds like a switch was flipped.

**Calibration.** "Soft" and "slam" are different on every desk and every pair
of hands, so `Calibrate force sensor…` asks you to type normally for 8 s and
takes the 35th and 92nd percentile of your impact peaks as the two endpoints.
Until then the defaults (soft ≤ 7.5 mg, slam ≥ 140 mg) apply.

**Sound.** `Sources/ThockAudio` is a Core Audio engine in C: one AudioUnit at a
128-frame buffer, all clips pre-decoded into RAM, a lock-free ring of triggers
feeding a fixed voice pool with per-voice gain ramps, round-robin variant
selection so repeated presses never sound identical, and an idle pause after
three minutes of silence so the machine can sleep normally.

**Layout.**

```
Sources/ThockAudio/   C audio engine + pack cache + WAV reader
Sources/ThockSPU/     C bridge to the undocumented SPU accelerometer
Sources/keystrike/    Swift app: sensor, force, keys, menu, settings UI
Tools/                generate_packs.py, engine_test.c
scripts/              build_app.sh, build_packs.sh
Resources/Packs/      16 packs × 4 key groups × press/release × 4 tiers
Resources/upstream.clickclack/  the MIT recordings the packs are built from
```

## Permissions

**Accessibility** is needed to observe key events. This is not optional: every
keystroke-feedback app on macOS needs it, and it is why apps like this one can
only be distributed outside the App Store. Keystrike asks on first launch, or
use `Grant Accessibility access…` in the menu, or toggle it in
`System Settings → Privacy & Security → Accessibility`.

Keystrike only ever reads key codes: it never sees or stores what you type,
never modifies your keystrokes, and nothing leaves the machine.

The accelerometer needs no permission at all - it is plain IOKit - but it does
use a private interface. That means:

- it can break in any macOS update, silently or loudly (the log will say
  `no SPU accelerometer`);
- when it breaks, or on a MacBook without the sensor, Keystrike still plays
  sound, estimating force from typing rhythm unless you turn that off.

Neither of these is acceptable for Mac App Store distribution; ad-hoc signing
with `scripts/build_app.sh` is the supported path.

## Sound packs

16 packs, 892 clips, built from the MIT-licensed
[Mechvibes/ClickClack](https://github.com/cesarferreira/clickclack) recordings
(`Resources/upstream.clickclack/CLICKCLACK-LICENSE`):

alpaca, blackink, bluealps, boxnavy, buckling, cream, holypanda, membrane,
mxblack, mxblue, mxbrown, redink, scissor, topre, turquoise, typewriter.

Each pack holds four key groups (generic, return, space, backspace) ×
press/release × four force tiers, with up to five recordings per slot.
Three packs (scissor, membrane, typewriter) are synthesised, because no
upstream recording exists for a MacBook scissor switch or a rubber dome.
Regenerate with `make packs` (needs `numpy`).

## Troubleshooting

**No sound at all, and even `say hello` hangs.** Something else is holding the
audio device. System-wide EQ apps (FineTune and friends) install themselves
into the output path and can leave it wedged after they quit; the fix is to
quit or reinstall them, then `sudo killall coreaudiod` (launchd restarts it).
`log stream --predicate 'process == "coreaudiod"'` will point at the client.
Keystrike's heartbeat in `~/Library/Logs/Keystrike/keystrike.log` reports
`renders=0` when the engine is healthy but the HAL is not pulling.

**No per-key sound, but the heartbeat shows renders climbing.** The event tap
was not created: grant Accessibility and use `Re-check` in the settings.
`make test-offline` and `KS_FORCE_TEST=1` bypass the tap entirely and are the
right tools when the tap is the problem.

## Credits

- Switch recordings: [Mechvibes/ClickClack](https://github.com/cesarferreira/clickclack), MIT (Tiago Ferreira).
- Force sensing follows the same idea as Thock/Haptyk, but is implemented here
  from scratch against the raw HID reports.
- Built with SwiftPM, AppKit, SwiftUI and Core Audio; no third-party
  dependencies.

## License

MIT, see [LICENSE](LICENSE).
