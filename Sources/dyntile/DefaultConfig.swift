import Foundation

extension Main {
    /// Printed by `dyntile --print-default-config`; also shipped as Resources/dyntile.conf.
    static let defaultConfigText = #"""
# dyntile.conf — dynamic tiling for macOS, one layout per native desktop.
# Put this at ~/.config/dyntile/dyntile.conf. Saved changes reload automatically.
#
# Syntax: `key = value`, `bind <keys> = <command>`, `#` starts a comment.
# Defining ANY bind replaces the whole default keymap, so copy what you want to keep.

# ---------------------------------------------------------------- appearance
gaps-inner   = 8        # between tiles
gaps-outer   = 8        # around the edge of the work area
main-ratio   = 0.55     # share of the screen the main area gets
main-count   = 1        # how many windows live in the main area
resize-step  = 0.03     # how much one `resize` press moves a split

# ---------------------------------------------------------------- layouts
# Cycled by `layout next` / `layout prev`, in this order.
#   tall     main column left, stack right
#   wide     main row on top, stack below
#   columns  equal columns
#   rows     equal rows
#   grid     near-square grid
#   monocle  every window fills the screen
#   bsp      splits at the focused window, dynamic tree
#   float    tiling off for that desktop only
layouts        = tall, bsp, monocle
default-layout = tall

# ---------------------------------------------------------------- behaviour
focus-follows-mouse = false
mouse-follows-focus = false
mouse-drag          = swap   # swap | off — what dragging a tiled window does
verbose             = false

# ---------------------------------------------------------------- floating
# Windows that should never be tiled. Bundle ids, and regexes over window titles.
float-app   = com.apple.systempreferences
float-app   = com.apple.ActivityMonitor
float-app   = com.apple.finder.SaveDialog
float-title = ^Picture[- ]in[- ]Picture$

# ---------------------------------------------------------------- keybindings
# Modifiers: cmd, alt, ctrl, shift. Keys use AeroSpace's names
# (letters, digits, f1-f20, minus, equal, slash, comma, period, semicolon,
#  quote, backtick, leftSquareBracket, rightSquareBracket, space, enter, esc,
#  tab, backspace, arrows, keypad*). `kc:36` takes a raw virtual keycode.
# Chain several commands on one key with `;`.

bind alt-h = focus left
bind alt-j = focus down
bind alt-k = focus up
bind alt-l = focus right

bind alt-shift-h = move left
bind alt-shift-j = move down
bind alt-shift-k = move up
bind alt-shift-l = move right

bind alt-tab       = focus next
bind alt-shift-tab = focus prev
bind alt-enter     = move main

bind alt-minus = resize shrink
bind alt-equal = resize grow

bind alt-slash = layout next
bind alt-comma = layout prev
bind alt-m     = layout monocle     # press twice to go back
bind alt-b     = layout bsp
bind alt-t     = layout tall

bind alt-shift-comma  = main dec
bind alt-shift-period = main inc

bind alt-f           = float toggle
bind alt-g           = gaps toggle
bind alt-shift-space = tiling toggle

bind alt-ctrl-left   = display focus prev
bind alt-ctrl-right  = display focus next
bind alt-shift-left  = display move prev
bind alt-shift-right = display move next

bind alt-shift-semicolon = reload

# bind alt-shift-enter = exec open -na Ghostty
"""#
}
