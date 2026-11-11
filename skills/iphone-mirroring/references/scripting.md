# Scripting a flow that retries

Once you have done a flow by hand (shot, tap, verify), you can script it so that a repeated task (one item
after another) does not need a screenshot read on every step. Keep the verify step in the script. Make it a
pixel check instead of your eyes.

## 1. Find a signature for each screen

Take a screenshot of each screen the flow passes through and look for something that is only on that screen:
a coloured button, a selected tab underline, a white title area. Read its colour:

```bash
$IM shot /tmp/im/list.png
$IM color /tmp/im/list.png 300 733 177 391     # prints "x,y #RRGGBB" per point
```

Then test for it in a box, with a tolerance:

```bash
$IM has-color /tmp/im/list.png 270 722 330 744 '#0095F6' --tol 60 && echo "on the list screen"
```

Boxes are more robust than single points: layouts shift by a few pixels between items.

## 2. Wrap each step in "act, verify, retry or back out"

```bash
#!/usr/bin/env bash
# open_item.sh X Y OUT: from a grid, open the item at (X, Y) and make sure the expected screen opened.
set -u
IM="${IM:?set IM to the iphone-mirror path}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

is_grid() { $IM shot "$T/s.png" >/dev/null && $IM has-color "$T/s.png" 50 185 110 197 '#0095F6' --tol 60 >/dev/null; }
is_list() { $IM has-color "$1" 270 722 330 744 '#0095F6' --tol 60 >/dev/null; }

back_to_grid() {
  for _ in 1 2 3 4; do
    is_grid && return 0
    $IM tap 37 103 >/dev/null; sleep 2.5      # top-left back chevron
  done
  return 1
}

back_to_grid || { echo "lost: not on the grid" >&2; exit 1; }
for try in 1 2 3; do
  $IM tap "$1" "$2" --shot "$3" >/dev/null
  is_list "$3" && exit 0
  echo "try $try opened a different screen, backing out" >&2
  back_to_grid
done
exit 1
```

The coordinates and colours above are examples from one layout. Read your own from your screenshots.

## 3. Read long pages with one image

```bash
$IM shot /tmp/im/p1.png
$IM scroll -60 --times 8 --shot /tmp/im/p2.png    # scroll waits 2.5 s, then captures
$IM scroll -60 --times 8 --shot /tmp/im/p3.png
$IM join /tmp/im/page.png /tmp/im/p1.png /tmp/im/p2.png /tmp/im/p3.png --trim-bars
```

`--trim-bars` crops the iOS status bar and the home indicator. Use `--crop-top`/`--crop-bottom` in pixels
for a fixed app header. `--resize 0.7` shrinks the result if small text stays readable.

## Timing defaults that worked

| After | Wait |
|---|---|
| tap that opens a new screen | 2–3 s (`--shot` defaults to 1 s; raise it with `--delay 2500`) |
| tab switch inside a screen | 1.5–2 s |
| scroll | 2.5 s (built into `scroll`) |
| going back | 2.5 s |

`wait-settle` can replace fixed sleeps on static screens. It cannot replace them on screens with playing
video.

## Clean up

Delete the screenshot folder at the end (`trap 'rm -rf "$T"' EXIT` above). Screenshots of a personal phone
are private data.
