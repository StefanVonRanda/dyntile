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

Then grant **System Settings → Privacy & Security → Accessibility → dyntile**. dyntile
waits for the grant and starts on its own, so there is no need to launch it twice.
Accessibility is the only permission it needs. dyntile has no keyboard shortcuts, so
Input Monitoring is never requested.

dyntile lives in the menu bar, not the Dock. Its icon dims when tiling is paused, and its
menu carries a **Layout** submenu listing every layout with the current one checked — all
of them, not just the ones in your `layouts` cycle, since the cycle only governs what
`layout next` steps through. The rest of the menu is retile, float the focused window, pause,
reload and quit.

The first `make install` writes `~/.config/dyntile/dyntile.conf` if you don't have one;
it never overwrites an existing config.

To start it at login: System Settings → General → Login Items → add `dyntile.app`.

### Codesigning

The bundle is ad-hoc signed by default, which means macOS treats each rebuild as a new app
and drops the Accessibility grant. Fix that once with a self-signed identity:

```sh
make signing-cert                        # creates "dyntile-local" in your login keychain
make install SIGN_ID="dyntile-local"
```

`make signing-cert` generates a code signing certificate with `openssl` and imports it
into your **login** keychain. Nothing is installed system-wide, nothing needs `sudo`, and
the certificate is deliberately *not* added to the trust store — `codesign` does not need
that, so there is no authorisation dialog. `codesign` asks once for access to the key;
choose *Always Allow*. Put `SIGN_ID=dyntile-local` in your environment to make it the
default, and `make remove-signing-cert` deletes the identity again.

Why this works: signed with an identity, the designated requirement codesign writes is

```
identifier "com.igzo.dyntile" and certificate leaf = H"<your certificate's hash>"
```

which does not change when the binary does. Ad-hoc signing instead produces
`cdhash H"…"`, derived from the binary's contents, so every rebuild is a different app as
far as TCC is concerned and the Accessibility grant stops matching.

`SIGN_ID` only *selects* an identity; if the named one does not exist the build stops and
tells you so rather than producing a differently-signed bundle.

If you do stay on ad-hoc signing, each rebuild leaves a stale Accessibility entry that
macOS will not match. Clear it and accept the prompt again:

```sh
make reset-permission && open /Applications/dyntile.app
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
mouse-drag          = swap     # drop a window on a tile to swap the two
mouse-resize        = ratio    # drag a window's edge to move that split

float-app   = com.apple.systempreferences
float-title = ^Picture[- ]in[- ]Picture$
```

`dyntile --check` validates a config without running anything, and every error names its
file and line. dyntile has no keyboard shortcuts; `bind` lines left in an older config are
ignored, and `--check` says how many.

### Commands

Sent with `dyntile msg` (see [Scripting](#scripting)).

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

## The icon

`Tools/MakeIcon.swift` draws the app icon — the `tall` layout itself — with Core Graphics
and hands the iconset to `iconutil`, so it is generated from source rather than checked in
as a binary. `make icon` rebuilds it; `make bundle` does so automatically. Every size is
drawn from scratch instead of downscaled, and below 32pt the plate grows into the margin
so the three tiles stay legible at 16pt.

## Scripting

A running dyntile listens on `/tmp/dyntile-$UID.sock`:

```sh
dyntile msg 'layout bsp'
dyntile msg 'focus right'
dyntile msg query          # what dyntile sees right now, per desktop
```

dyntile has no hotkeys of its own. If you want some, bind them in skhd, Karabiner or
Shortcuts to `dyntile msg <command>`.

## Troubleshooting

```sh
dyntile msg 'layout bsp'   # or use the Layout submenu in the menu bar
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
- Tiling is frozen for as long as the left mouse button is held. A layout pass in the
  middle of a drag is what makes a tiler feel like it is fighting the cursor, so there
  is exactly one pass, on mouse-up.

## Using the mouse

Dragging a tiled window and dropping it on another **swaps the two** (`mouse-drag = off`
turns this off and snaps it back instead).

Dragging a window's **edge** moves the split it sits on, and the window keeps the size you
dropped it at, in every layout that has splits:

- `tall`/`wide`: the edge becomes the main ratio.
- `columns`, `rows`, `grid`: the tile trades size with the neighbour on the side you
  dragged, and nothing else moves. Sizes belong to the slot rather than the window, so a
  swap keeps them in place, and a newly opened window gets an average share instead of
  resetting the rest.
- `bsp`: each edge you moved is pushed onto whichever ancestor split owns it.

An edge against the side of the screen has no neighbour, so dragging it snaps back, as
does any resize in `monocle`. `mouse-resize = off` snaps back everywhere.

Nothing is retiled while the button is down, so neither gesture fights the cursor.

## Limits

- Fullscreen (green-button) windows are macOS's own Space; dyntile leaves them alone.
- It cannot move a window between desktops, by design: that is Spaces' job.
