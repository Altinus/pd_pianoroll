# `pianoroll` — DAW-Grade MIDI Piano Roll for plugdata (`pdlua` / LuaJIT)

A multi-module, 3-layer NanoVG piano roll editor and MIDI sequencer custom object designed for **plugdata** with **LuaJIT** performance optimizations.

## Architecture (7 Files)

| Module | Responsibility |
| --- | --- |
| [`pianoroll.pd_luajit`](pianoroll.pd_luajit) | Class entry point (`4` inlets, `4` outlets), lifecycle/hot-reload, clocks, message router, `properties` inspector, state persistence |
| [`pr_theme.lua`](pr_theme.lua) | Dynamic host-theme palette (`pd.bg_color`, `pd.fg_color`, `pd.sel_color`) + Auto/Dark/Light/Custom modes & customizable colors |
| [`pr_layout.lua`](pr_layout.lua) | Resize-invariant pixel layout & beat/pitch coordinate mapping |
| [`pr_model.lua`](pr_model.lua) | Note CRUD, hit-testing, 9 grid divisions, 4 snap modes (`ABS`/`REL`/`ADP`/`VIS`), `Last Note`/`Grid Step` default length modes, compiled event timeline, LuaJIT FFI `uint16_t[128]` / `uint8_t[128]` voice counters |
| [`pr_playback.lua`](pr_playback.lua) | ~2ms tick scheduler, loop wrapping, keyboard/edit audition, sorted Outlet 1 active-pitch emission (clears on pause) |
| [`pr_render.lua`](pr_render.lua) | 3-layer NanoVG renderer (`paint` / `paint_layer_2` / `paint_layer_3`) with coalesced dirty-layer repaints |
| [`pr_input.lua`](pr_input.lua) | Mouse gestures, toolbar/ruler/keyboard/scrollbar/zoom-grip handlers, and `[keyname]` modifier tracking |
| [`pianoroll_main.pd`](pianoroll_main.pd) | Ready-to-run plugdata demo patch including `[keyname] -> [pak f a] -> [listbox]` wiring |

## UI Regions & Resize Invariance

- **Top Toolbar**: Play/Pause, Stop, Loop toggle, interactive BPM (`-` / drag / `+` / dblclick reset), Grid selector, Snap toggle & Mode (`ABS` / `REL` / `ADP` / `VIS`), Default Length Mode (`L:LST` Last Note [default] / `L:GRD` Grid Step), **Edit actions (`UND` / `RDO` / `CUT` / `CPY` / `PST`)**, Fit, Clear, Note count, and clickable `[C][S][A]` keyname modifier badges.
- **Top Ruler**: Click or drag to jump/scrub playhead; `Ctrl+Drag` to set loop bracket; **double-click** to clear loop.
- **Left Keyboard**: Piano black/white keys with `C-1..C9` octave labels; click or drag (glissando) auditions notes.
- **Bottom Rail**: Bottom-left **Reset Default Zoom & Pos (`RST`)** corner + **Horizontal Scrollbar** + bottom-right **V-Zoom grip** (`↕`, drag up/down for vertical zoom, dblclick resets).
- **Right Rail**: Top-right **H-Zoom grip** (`↔`, drag left/right for horizontal zoom, dblclick resets) + **Vertical Scrollbar**.
- **Resize Behavior**: Resizing the object (box handle, `resize w h`, or Properties Width/Height) **only expands/shrinks the piano roll viewport**; toolbar height, ruler height, keyboard width, scrollbar thickness, and note zoom scales (`px_per_beat`, `px_per_pitch`) stay fixed.

## Mouse & `[keyname]` Gestures

Wire Inlet 4 from `[keyname]` -> `[pak f a]` -> `[listbox]` (emitting `[1/0 KEYNAME]`):

- **Blank click**: Create note snapped to **nearest** grid line when snap is enabled (`Last Note` / `L:LST` mode preserves note length and lets you **drag-reposition pitch & start beat** during creation; `Grid` / `L:GRD` mode lets you **drag-resize length** during creation)
- **Blank click after Ctrl multi-select**: Cancels active selection cleanly without creating a note; clicking blank again creates a note
- **Drag note body**: Move note in pitch & time (supports multi-selection move)
- **Drag note right tail edge**: Resize note length
- **Zoom-Adaptive Grid Density**: Background vertical and horizontal grid lines update synchronously with active Grid/Snap settings and zoom level, automatically thinning overly dense subdivision/beat/pitch lines when zoomed far out
- **Double-click note**: Delete note (when multiple notes are selected, double-clicking **any** selected note deletes **all** selected notes simultaneously)
- **`Ctrl` + Drag blank roll**: Marquee box selection (`Ctrl` + click note toggles selection)
- **`Shift` + Drag blank roll**: Vertical drag = Vertical Zoom; Horizontal drag = Horizontal Zoom (anchors at **left edge** when sequence fits/fills screen, and strictly at **cursor X** when scrollable)
- **`Alt` + Drag blank roll**: Free 2D view pan across time and pitch (freely pans along the timeline even when zoomed out / full clip visible)
- **Keys & Undo/Clipboard Shortcuts (Plugdata-Safe)**:
  - **Toolbar Buttons**: `UND`, `RDO`, `CUT`, `CPY`, `PST` (always available, zero hotkey conflict)
  - **`Alt` + Key (via Inlet 4)**: `Alt+Z` Undo, `Alt+Y` / `Alt+Shift+Z` Redo, `Alt+C` Copy, `Alt+X` Cut, `Alt+V` Paste, `Alt+D` Duplicate, `Alt+A` Select All (bypasses plugdata's `Ctrl+*` window accelerators)
  - **Hover-Gated Single Keys** *(toggleable in Properties `Hover Hotkeys`)*: When mouse is hovered over the piano roll, bare `z` (Undo), `y`/`r`/`Shift+z` (Redo), `c` (Copy), `x` (Cut), `v` (Paste), `d` (Duplicate), `a` (Select All)
  - **Clickable `[C]` Modifier Badge**: Click `[C]` in top-right toolbar + press `c`/`x`/`v`/`z`/`y`/`a` without holding physical `Ctrl`
  - **General Keys**: `Delete`/`BackSpace` deletes selection, `space` toggles Play/Pause, `Escape` deselects

## Inlets & Outlets Protocol

### Inlets (`4`)
1. **Inlet 1 (Main Control)**: `bang` (toggle play/pause), `float` (seek beat), `play`, `pause`, `stop`, `toggle`, `reset`, `seek <beat>`, `seek_sec <sec>`, `bpm <f>`, `grid <div|index>`, `snap <0|1>`, `snap_mode <1..4|abs|rel|adp|vis>`, `len_mode <1..5|last|grid>`, `length <beats>`, `bars <n>`, `timesig <n>`, `vel <1..127>`, `loop [en] [start end]`, `clear_loop`, `add <p> <s> [l] [v]`, `set_notes <p s l v ...>`, `remove <id|p s>`, `delete_selected`, `clear`, `transpose <semi>`, `quantize [strength]`, **`undo`**, **`redo`**, **`copy`**, **`cut`**, **`paste [beat]`**, **`duplicate`**, `select_all`, `deselect`, `hotkeys <0|1>`, `get_notes`/`dump`, `get_active`, `get_state`, `theme <1..4|auto|dark|light|custom>`, `note_color`/`selected_color`/`playhead_color`/`loop_color`/`grid_color`/`custom_bg_color <r g b>`, `grid_contrast <0.25..2.0>`, `resize <w h>`, `fit`, `reset_view`
2. **Inlet 2 (BPM)**: `float` BPM (`20..300`), `bang` (queries current BPM)
3. **Inlet 3 (View)**: `float` / `goto <beat>`, `scroll <beat> [pitch_top]`, `zoom`/`hzoom <px_per_beat>`, `vzoom <px_per_pitch>`, `goto_pitch <p>`, `fit`
4. **Inlet 4 (Keyname)**: `[1/0 KEYNAME]` lists from `[keyname] -> [pak f a]`, `reset_keys`, `mods`

### Outlets (`4`, emitted right-to-left)
1. **Outlet 1 (Sorted Active MIDI List)**: Ascending sorted list of currently sounding MIDI note numbers (`list p1 p2 ...`). **Automatically clears to empty list (`list`) on pause, stop, or rests.**
2. **Outlet 2 (Note Events)**: `noteon <pitch> <vel>`, `noteoff <pitch> 0`, `velocities <v1 v2 ...>`
3. **Outlet 3 (Transport & Sync)**: `playing <0|1>`, `pos <beat> <sec> <bar> <beat_in_bar>`, `bpm <f>`, `loop <en> <start> <end>`
4. **Outlet 4 (Queries & Edits)**: `dump_begin <n>`, `note <pitch> <start> <len> <vel> <id>`, `dump_end <n>`, `state ...`, `edited <op ...>`

## Verification Commands

Static lint check (LuaLS via `pdlua-run.py`):
```bash
python F:/MyWork/0_Global/Knowledge/pdluajit/vscode-pdlua/harness/pdlua-run.py lint pianoroll.pd_luajit pr_theme.lua pr_layout.lua pr_model.lua pr_playback.lua pr_render.lua pr_input.lua
```

Offline regression suite + SVG preview + properties check:
```bash
python F:/MyWork/0_Global/Knowledge/pdluajit/vscode-pdlua/harness/pdlua-run.py run pianoroll.pd_luajit --args "720 380 120" --script test_pianoroll.lua --paint preview.svg --props --strict
```
