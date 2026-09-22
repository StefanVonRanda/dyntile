# dyntile

Dynamic window tiling for macOS, built around native desktops instead of replacing them.

dyntile never creates, names, numbers or switches Spaces. It tiles whatever macOS is
already showing on each display's current desktop, and remembers the layout, split ratio
and main-window count **per desktop**. Switch desktops with the trackpad or `ctrl-→` as
you always have; dyntile picks up whatever is there.

That is the one thing it does differently from AeroSpace: there is no virtual workspace
layer, so there is nothing to get out of sync with what macOS thinks is on screen.

## Layouts

| name | behaviour |
| --- | --- |
| `tall` | main column on the left, stack on the right |
| `wide` | main row across the top, stack underneath |
| `columns` | equal vertical columns |
| `rows` | equal horizontal rows |
| `grid` | near-square grid |
| `monocle` | every window fills the work area |
| `bsp` | binary split at the focused window; the tree follows where you work |
| `float` | tiling off, for that one desktop |

`layouts = ...` sets which ones `layout next` cycles through, and each desktop keeps its
own choice.

## Install

```sh
git clone <this repo> && cd dyntile
make install          # builds dyntile.app, installs to /Applications, symlinks ~/.local/bin/dyntile
open /Applications/dyntile.app
```

Then grant **System Settings → Privacy & Security → Accessibility → dyntile**, and launch
it again. Accessibility is the only permission it needs — the hotkeys use Carbon's
`RegisterEventHotKey`, not an event tap, so Input Monitoring is never requested.

The first `make install` writes `~/.config/dyntile/dyntile.conf` if you don't have one;
it never overwrites an existing config.

To start it at login: System Settings → General → Login Items → add `dyntile.app`.

### Codesigning

The bundle is ad-hoc signed by default, which means macOS treats each rebuild as a new
app and drops the Accessibility grant. To keep it across rebuilds, make a self-signed
codesigning certificate in Keychain Access and build with:

```sh
make install SIGN_ID="dyntile-local"
```

## Configuration

`~/.config/dyntile/dyntile.conf`, reloaded automatically when you save it.
`dyntile --print-default-config` prints a fully commented starter file.

```conf
gaps-inner     = 8
gaps-outer     = 8
main-ratio     = 0.55
main-count     = 1
resize-step    = 0.03
layouts        = tall, bsp, monocle
default-layout = tall

focus-follows-mouse = false
mouse-follows-focus = false
mouse-drag          = swap     # dragging a tiled window swaps it with the one you drop it on

float-app   = com.apple.systempreferences
float-title = ^Picture[- ]in[- ]Picture$

bind alt-h = focus left
bind alt-shift-l = move right
bind alt-slash = layout next
bind alt-shift-enter = exec open -na Ghostty; retile
```

Modifiers are `cmd`, `alt`, `ctrl`, `shift`; key names follow AeroSpace's vocabulary
(`h`, `1`, `f5`, `minus`, `equal`, `slash`, `comma`, `leftSquareBracket`, `space`,
`enter`, `esc`, `tab`, `left`/`right`/`up`/`down`, `keypad3`, …), and `kc:36` takes a raw
virtual keycode. Several commands can share one key, separated by `;`.

**Defining any `bind` replaces the entire default keymap**, so copy the lines you want to
keep. `dyntile --check` validates a config without running anything, and every error
names its file and line.

### Commands

| command | |
| --- | --- |
| `focus left\|right\|up\|down\|next\|prev` | move focus |
| `move left\|right\|up\|down\|next\|prev\|main` | swap the focused window with that neighbour |
| `layout next\|prev\|<name>` | cycle, or jump to one (pressing the same one twice goes back) |
| `resize grow\|shrink` | grow or shrink the focused window's split |
| `main inc\|dec` | windows in the main area |
| `float toggle` | take the focused window out of the layout |
| `gaps inc\|dec\|toggle` | |
| `tiling toggle` | pause dyntile entirely |
| `display focus\|move next\|prev` | across physical displays |
| `reload`, `retile`, `query`, `quit` | |
| `exec <shell command>` | |

### Default keymap

Mirrors AeroSpace's defaults with the workspace bindings removed.

```
alt-h/j/k/l              focus left/down/up/right
alt-shift-h/j/k/l        move  left/down/up/right
alt-tab / alt-shift-tab  focus next / prev
alt-enter                promote to main
alt-minus / alt-equal    resize shrink / grow
alt-slash / alt-comma    layout next / prev
alt-m                    monocle (press again to go back)
alt-shift-, / alt-shift-.  main dec / inc
alt-f                    float toggle
alt-g                    gaps toggle
alt-shift-space          tiling toggle
alt-ctrl-←/→             focus previous/next display
alt-shift-←/→            move window to previous/next display
alt-shift-;              reload config
```

## Scripting

A running dyntile listens on `/tmp/dyntile-$UID.sock`:

```sh
dyntile msg 'layout bsp'
dyntile msg 'focus right'
dyntile msg query          # what dyntile sees right now, per desktop
```

Handy if you'd rather keep your hotkeys in skhd or Karabiner: bind them to
`dyntile msg <command>` and leave the config's `bind` lines out.

## Troubleshooting

```sh
dyntile --check       # validate the config
dyntile --dry-run     # log the layout it would apply, without moving anything
dyntile -v            # verbose event log
dyntile msg query     # per-desktop layout, window order, floating windows
make test             # 2400+ assertions over the layout maths, BSP tree and config parser
```

A window that refuses to tile is usually one dyntile deliberately skips: it only manages
standard, resizable, non-minimized windows. Dialogs, sheets, palettes and fixed-size
panels are left where the app put them. `dyntile msg query` lists what it is managing.

## How it works, and what that costs

- Windows are moved through the Accessibility API, same as every other macOS tiler.
- The current desktop is read from `CGWindowListCopyWindowInfo`'s on-screen list, which
  is exactly the set of windows macOS is showing — so dyntile is always in agreement with
  the system about what's visible.
- Two private symbols are used, both resolved with `dlsym` and both with fallbacks:
  `_AXUIElementGetWindow` (accessibility element → window id) and SkyLight's
  `CGSCopyManagedDisplaySpaces` (which desktop is current on which display, so layouts can
  be remembered per desktop). No SIP changes, no injection, no scripting additions.
- Accessibility events are lossy, so a 3-second reconcile pass catches anything missed.
- Apps that snap to size increments — terminals, mostly — will not land exactly on their
  tile. dyntile records where they actually landed rather than fighting them.

## Limits

- Fullscreen (green-button) windows are macOS's own Space; dyntile leaves them alone.
- It cannot move a window between desktops, by design: that is Spaces' job.
