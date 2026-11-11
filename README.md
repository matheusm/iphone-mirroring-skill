# iPhone Mirroring skill

An [Agent Skill](https://agentskills.io) for driving the macOS **iPhone Mirroring** app from a coding agent
(Claude Code, Codex, Cursor, Gemini CLI, OpenCode and other agents that load skills). The agent can screenshot
the phone, tap, scroll, open Home / App Switcher / Spotlight, and check every step against a fresh screenshot.

Use it for things that only exist in a phone app: creator analytics such as Instagram Reel insights (retention
curve, skip rate, view sources), app settings, or a quick check of a mobile UI.

```bash
npx skills add matheusm/iphone-mirroring-skill
```

## What's inside

```
skills/iphone-mirroring/
├── SKILL.md                     # when to use it, setup, the core loop, rules
├── scripts/
│   ├── iphone-mirror            # wrapper: compiles the Swift file on first run, then runs it
│   └── iphone-mirror.swift      # the CLI, one dependency-free Swift file
└── references/
    ├── pitfalls.md              # everything that went wrong and how to fix it
    ├── scripting.md             # retrying flows with pixel checks, joining screenshots
    └── instagram-insights.md    # worked recipe: Reel insights in the Instagram iOS app
```

The CLI (`iphone-mirror help` lists every option):

| Command | What it does |
|---|---|
| `doctor [--prompt]` | Checks permissions, finds the host app, the window and the display scale |
| `info` | Window position, size, scale and permission state as JSON |
| `shot <out.png> [--native]` | Screenshot of the phone window, no shadow, 1 px = 1 window point |
| `tap <x> <y>` | Tap at screenshot coordinates (`--hold 800` for a long press) |
| `scroll <dy> [--at x y] [--times n]` | Pixel scroll wheel, then waits for momentum to stop |
| `swipe <x1> <y1> <x2> <y2>` | Press, drag and release (experimental) |
| `menu <home\|app-switcher\|spotlight\|paste>` | The app's menu actions, with localized names; `menu --list` |
| `wait-settle` | Waits until the screen stops changing |
| `color`, `has-color` | Pixel probes for cheap "which screen am I on?" checks |
| `join` | Several screenshots side by side (trims status bar and home indicator) |

Actions accept `--shot out.png` to capture right after acting, and `--dry-run` to print the target without
sending events. Coordinates are always pixels of a `shot` image, so the agent reads a coordinate off the
picture and taps it. With `shot --native` on Retina, pass `--ref <image>` and the scale is computed.

## Requirements

- macOS 15 (Sequoia) or later, with iPhone Mirroring set up and a paired iPhone (iOS 18 or later).
- Xcode Command Line Tools for `swiftc` (`xcode-select --install`). The wrapper compiles the CLI on first run,
  in about 10 s, and caches it in `~/Library/Caches/iphone-mirroring-skill`.
- No other dependencies: no Python, Node or Homebrew packages.

## Permissions

The app that runs the agent's shell (Terminal, iTerm, Warp, Ghostty, VS Code, Cursor...) needs, under
**System Settings > Privacy & Security**:

1. **Accessibility**, for taps, scrolls and menus.
2. **Screen & System Audio Recording**, for screenshots. It only takes effect after that app is **fully quit
   (cmd+Q) and reopened**.

`scripts/iphone-mirror doctor` names the host app and says what is missing. `doctor --prompt` asks macOS to
show the dialogs.

If taps do nothing at the very start of a session, click once inside the iPhone Mirroring window yourself,
then retry.

## Example

```
$ IM=~/.agents/skills/iphone-mirroring/scripts/iphone-mirror
$ $IM doctor
[ok]   host app: Terminal (/System/Applications/Utilities/Terminal.app); permissions must be granted to this app
[ok]   Accessibility: granted (taps, scrolls, menus)
[ok]   iPhone Mirroring running: "iPhone Mirroring" pid 812
[ok]   window #4321 at (612, 140) size 354x781 pt, display scale 2
[ok]   Screen Recording: screenshot works, native 708x1562 px (2x); `shot` saves 354x781
$ $IM shot /tmp/im/0.png
/tmp/im/0.png 354x781 scale=1
$ $IM tap 324 752 --shot /tmp/im/1.png      # coordinates read from 0.png
tapped 324,752
/tmp/im/1.png 354x781 scale=1
$ $IM scroll -60 --times 8 --shot /tmp/im/2.png
scrolled -60 x 8
/tmp/im/2.png 354x781 scale=1
$ $IM menu home
pressed <menu> > Home Screen
```

(Illustrative output. Window numbers, positions and menu paths vary.)

Inside an agent, just ask, for example: *"Open Instagram on my phone through iPhone Mirroring and read the
insights of my last three reels. Don't like or post anything."*

## How it works, and why taps are odd

iPhone Mirroring tracks the iPhone-side pointer from **mouse-move events**, and a click lands wherever that
pointer currently is. A bare synthetic click does nothing, and warping the cursor before clicking makes the
click land at the old position. The CLI therefore glides the cursor to the target with about 25 small
`mouseMoved` events, waits about 500 ms, then sends mouse down, hold 120 ms, mouse up. A tap sent during scroll
momentum only stops the scroll, so `scroll` waits 2.5 s afterwards. More in
[pitfalls.md](skills/iphone-mirroring/references/pitfalls.md).

## Status

| Feature | Status |
|---|---|
| Window detection (localized app name, negative coordinates on a secondary display), `info`, host app detection, `doctor` including the missing-permission paths | Tested live (macOS 26, pt-BR system, 1x secondary display) |
| `shot` | The same `screencapture -x -o -l` call was proven live in prototypes. This CLI's success path and the Retina downscale are not yet tested live |
| `tap`, `scroll` | The same event sequences were proven live in prototype scripts. This CLI adds window raising and an "is something covering the target" check. Not yet tested live in this form |
| `menu home / app-switcher / spotlight` | Menu titles were confirmed live, and pressing them through System Events worked. The CLI presses them through the Accessibility API directly: not yet tested live |
| `swipe`, long press (`tap --hold`), `menu paste`, `wait-settle`, keyboard typing (not implemented) | Untested / experimental |
| `join`, `color`, `has-color`, coordinate scaling (`--ref`, `--dry-run`) | Tested offline |

Issues and pull requests with results from other macOS versions, languages and Retina setups are welcome.

## Safety

The agent acts on a real phone with real accounts. The skill tells it to stay read-only unless asked: no
posting, liking, following, sending, buying, boosting or deleting, and no double taps on media (a double tap
likes it in many apps). Actions refuse to click when another window covers the target point. Screenshots can
contain private data, so delete them when you are done.

## License

[MIT](LICENSE)
