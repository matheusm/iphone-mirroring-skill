---
name: iphone-mirroring
description: Drive the macOS iPhone Mirroring app from a coding agent. Screenshot the phone, tap, scroll, swipe, open Home / App Switcher / Spotlight, and check every step against a fresh screenshot. Use when the user wants you to read or operate an iPhone app through iPhone Mirroring on a Mac, such as app-only stats (Instagram Reel insights, creator dashboards), settings, or a quick check of a mobile UI. Also use when they mention "iPhone Mirroring", "Espelhamento do iPhone", or controlling their phone from the Mac.
license: MIT
compatibility: macOS 15+ with the iPhone Mirroring app and Xcode Command Line Tools (swiftc). The app running the agent's shell needs Accessibility and Screen & System Audio Recording permissions.
metadata:
  version: "1.0.0"
---

# iPhone Mirroring

You control the user's real iPhone through the iPhone Mirroring window on their Mac. You see the phone only
through screenshots and act only through synthetic mouse events. Be slow, verify everything, and change
nothing the user did not ask you to change.

## The tool

`scripts/iphone-mirror` lives in this skill's folder. It is a wrapper that compiles `scripts/iphone-mirror.swift`
with `swiftc` on first run (about 10 s) and caches the binary. Use its absolute path:

```bash
IM="<this skill's folder>/scripts/iphone-mirror"   # if the exec bit is lost: IM="bash <folder>/scripts/iphone-mirror"
$IM help
```

| Command | Use |
|---|---|
| `$IM doctor` | Check permissions, host app, window and scale. Run first. |
| `$IM shot <png>` | Screenshot of the phone. 1 px = 1 window point, so coordinates read off it go straight to `tap`. |
| `$IM tap <x> <y> [--shot <png>]` | Tap. `--shot` takes a screenshot 1 s later. |
| `$IM scroll -60 [--at x y] [--times 8]` | Negative = further down the page. Waits 2.5 s for momentum by default. |
| `$IM menu home\|app-switcher\|spotlight` | iPhone Mirroring menu actions (localized names handled). `menu --list` shows all. |
| `$IM wait-settle` | Wait until the screen stops changing. Playing videos never settle: use `--region`. |
| `$IM has-color <png> x1 y1 x2 y2 '#RRGGBB'` | Cheap check of which screen you are on (exit 0 = found). |
| `$IM join <out> a.png b.png --trim-bars` | Several screenshots side by side, to read long pages with fewer tokens. |

All actions take `--dry-run`, which prints the target point and sends nothing. Exit codes: 2 = app or window
missing, 3 = permission or capture failure, 4 = timeout or not found.

## Setup (once per machine)

1. Run `$IM doctor`, then fix each `[FAIL]` by asking the user. You cannot grant permissions yourself.
   - The **host app** that doctor names (Terminal, iTerm, Warp, Ghostty, VS Code, Cursor...) needs
     **Accessibility** and **Screen & System Audio Recording** (System Settings > Privacy & Security).
   - Screen Recording only applies after the host app is **fully quit (cmd+Q) and reopened**, which ends
     this session. Tell the user to do that and resume afterwards.
   - `$IM doctor --prompt` asks macOS to show the permission dialogs.
2. iPhone Mirroring must be open (`open -b com.apple.ScreenContinuity`), connected, and visible on a display.
   Other windows may cover it; every action raises it first.
3. **If taps do nothing at the start of a session, ask the user to click once inside the iPhone
   Mirroring window**, then retry. Synthetic events can be ignored until the first physical click.

## Core loop: one action, then verify

1. `$IM shot /tmp/im/00.png` and look at the image (read it with your image or file tool).
2. Pick **one** action and read its coordinates off **that** image.
3. Act and capture in one step: `$IM tap 177 391 --shot /tmp/im/01.png`.
4. Look at the new screenshot. Check that the screen is the one you expected (title, selected tab, a known
   button). If it is not, back out (top-left back chevron, or `$IM menu home`) and try again.
5. Repeat. Never chain several blind actions, and never reuse coordinates from an older screenshot after
   anything moved.

## Rules

- **Read-only by default.** Never tap anything that posts, likes, follows, comments, sends, shares, buys,
  subscribes, boosts/promotes, deletes, or changes settings unless the user explicitly asked for that exact
  action. Do not double-tap on media: many apps treat a double tap as a like. If a dialog asks for a payment,
  a permission or a confirmation, stop and ask the user.
- **After scrolling, wait** (built in: 2.5 s). A tap during scroll momentum only stops the scroll.
- **The same tap can open different screens** (in Instagram, a grid item sometimes opens the Reels viewer and
  sometimes the Posts list). Verify, then retry or back out. In scripts, use `has-color` as the check.
- **Coordinates come from the latest `shot`.** If you captured with `--native` on a Retina display, add
  `--ref <that.png>` to the action.
- Keep screenshots in a temporary folder and **delete them when done**. They show private data.

## Status

The tap and scroll event sequences were proven live with prototype scripts. In this CLI, live tests have
covered `doctor`, `info` and window detection so far. Successful `shot`, `tap`, `scroll` and `menu` still need
a live run on a machine with both permissions. `swipe`, long press, `menu paste` and keyboard typing are
**experimental**: confirm each with a screenshot and fall back to taps.

## References

- [references/pitfalls.md](references/pitfalls.md): every failure seen so far and its fix (permissions,
  taps that land in the wrong place, scroll, menus, coordinates, multiple displays). Read it when something
  does not behave.
- [references/scripting.md](references/scripting.md): turning a manual flow into a script that retries
  (verify-by-pixel loops, joining pages).
- [references/instagram-insights.md](references/instagram-insights.md): worked recipe for reading Instagram
  Reel insights in the iOS app (data the web does not show).
