# Pitfalls and fixes

Lessons from automating iPhone Mirroring from a terminal on macOS 26 (Tahoe). They apply to any agent
driving the app with synthetic events.

## Permissions

The permissions belong to the **host app**: the `.app` whose process tree runs your shell, such as Terminal,
iTerm, Warp, Ghostty, VS Code or Cursor. `iphone-mirror doctor` finds it by walking the parent PIDs. To do
it by hand:

```bash
pid=$$; while [ "$pid" -gt 1 ]; do ps -o ppid=,comm= -p "$pid"; pid=$(ps -o ppid= -p "$pid" | tr -d ' '); done
```

| Symptom | Missing permission |
|---|---|
| `screencapture` prints "could not create image from display/rect/window" | Screen & System Audio Recording |
| `AXIsProcessTrusted()` is false (Swift needs `import ApplicationServices`) | Accessibility |
| `osascript` fails with "-1719 ... assistive access not allowed" | Accessibility |
| `osascript` fails with "-1743 ... not allowed to send Apple events" | Automation > System Events (AppleScript only) |
| Taps/scrolls "succeed" but nothing happens and the cursor does not move | Accessibility (events are silently dropped; the CLI now refuses instead) |

- **Screen Recording only takes effect after the host app is fully quit (cmd+Q) and reopened.** Closing the
  window is not enough. That restart ends the agent session, so ask the user to do it and come back.
- Under tmux, screen or ssh there may be no `.app` among the parents. Grant the permissions to the terminal
  that started the tmux server, then restart the server.
- `iphone-mirror` uses the Accessibility API directly for menus, so it does not need the Automation
  permission. AppleScript does.

## Finding the window

- Match by bundle id `com.apple.ScreenContinuity`. The app and window owner name are localized ("iPhone
  Mirroring" in English, "Espelhamento do iPhone" in pt-BR). Never match on a substring such as "Mirroring"
  or "Espelhamento": AirPlay processes ("Espelhamento de Tela AirPlay") match too.
- The app owns some thin helper windows (about 1512x33, the size of the menu bar). The phone window is the
  tall one at layer 0.
- Bounds from `CGWindowListCopyWindowInfo` are **global points with a top-left origin**. They are
  **negative** on a display placed left of or above the main one (seen: X=-401, Y=-1010, 354x781).
- For AppleScript/System Events, `process "iPhone Mirroring"` worked even on a pt-BR system.

## Screenshots and coordinates

- `screencapture -x -o -l <windowNumber> out.png`. `-o` drops the shadow, `-x` the shutter sound. It works
  even when other windows cover the phone window.
- On a 1x display the image is exactly the window size in points (354x781). On Retina it is 2x
  (708x1562). `iphone-mirror shot` downsizes to points by default, so **1 screenshot px = 1 window point**.
  With `shot --native`, convert using scale = image width / window width (`--ref img.png` does it).
- The window can move or change size (View menu sizes, display changes). Take a fresh shot before acting
  on old coordinates.

## Taps (the key lesson)

iPhone Mirroring tracks the iPhone-side pointer from **mouse movement events**. A click lands wherever that
pointer currently is, not where the event says.

| Tried | Result |
|---|---|
| `leftMouseDown`/`leftMouseUp` at a point | Not registered |
| One `mouseMoved`, then down/up ~120 ms later | Not registered |
| `CGWarpMouseCursorPosition` + click | Landed at the **previous** pointer position |
| ~25 interpolated `mouseMoved` from the current cursor to the target (~12 ms apart), wait ~500 ms, `leftMouseDown`, hold ~120 ms, `leftMouseUp`, `clickState=1`, all on `.cghidEventTap` | **Works reliably** |

`iphone-mirror tap` does exactly that. Tunables: `--steps`, `--wait`, `--hold`.

- **At the very start of a session nothing registered until the user physically clicked once inside the
  window.** If taps do nothing, ask the user for that one click.
- A click goes to whatever window is on top at that point. The CLI raises iPhone Mirroring first and
  refuses when another window still covers the target (`--force` overrides).
- If the phone shows a lock screen or "iPhone in use", taps go nowhere useful. Ask the user to unlock the
  phone or reconnect.

## Scrolling

- `CGEvent(scrollWheelEvent2Source:units:.pixel, wheelCount: 1, wheel1: dy, ...)` works. Negative `dy` moves
  further down the page. Eight events of -60 make a good default step; check in the next screenshot how far it
  went.
- **A tap sent while scroll momentum is still running only stops the scroll**; the button does not
  activate. Wait about 2.5 s after scrolling (`scroll` does it by default; `--settle` changes it).
- The pointer must be over the area that should scroll (`--at x y`; default: window centre).
- If the direction looks inverted on some setup, flip the sign and verify with a screenshot.

## Swipes and drags (untested)

A synthetic drag was only tried before the first-click issue was understood, so it is unproven.
`iphone-mirror swipe` uses the same move-first approach: glide to the start, wait, press, then drag events,
then release. Treat it as experimental and verify with a screenshot. Prefer `scroll` for scrolling and
taps on visible back buttons for navigation.

## Menu actions

The app's menus contain **Home Screen**, **App Switcher** and **Spotlight** (pt-BR: "Tela de Início",
"Seletor de Apps", "Spotlight"), plus **Edit > Paste** ("Colar"). Pressing them by name, searching every menu
of the menu bar, is a robust way to go Home, open the App Switcher or open Spotlight.

- `iphone-mirror menu home|app-switcher|spotlight|paste` uses the Accessibility API and matches the
  localized titles, ignoring case and accents. `menu --list` prints the real titles and shortcuts on this Mac.
  Add your language to `menuActions` in the Swift file if it is missing.
- **Paste (Mac clipboard into the phone's focused field) is untested.** If you try it, `pbcopy` overwrites
  the user's clipboard, so ask first.
- **Keyboard typing is untested.**
- AppleScript fallback (needs the Automation permission for System Events):

```bash
osascript <<'EOF'
tell application "System Events" to tell process "iPhone Mirroring"
  set frontmost to true
  repeat with mbi in menu bar items of menu bar 1
    repeat with t in {"Home Screen", "Tela de Início"}
      if exists menu item (t as text) of menu 1 of mbi then
        click menu item (t as text) of menu 1 of mbi
        return
      end if
    end repeat
  end repeat
end tell
EOF
```

## Staying oriented

This was the main pain point.

- Take a screenshot after **every** action and look at it before the next one.
- The same tap can open different views. In Instagram, a profile grid item sometimes opens the full-screen
  Reels viewer and sometimes the Posts list. Verify the screen, then retry or back out.
- Cheap pixel checks are reliable for that: a known button colour in a known region (`has-color`). See
  [scripting.md](scripting.md).
- `wait-settle` waits for the screen to stop changing. Autoplaying video never settles: limit it with
  `--region` to a static part of the screen, or use a fixed delay.
- To read long pages cheaply, scroll in steps, then `join --trim-bars` the shots (status bar and home
  indicator removed) and read one image.
- When lost, `menu home` gets you back to a known state. Reopen the app from there.
- Never tap buttons that post, like, follow, send, buy, boost or delete unless the user asked. Watch out for
  double taps on photos and videos (likes) and for long presses (context menus with destructive actions).
