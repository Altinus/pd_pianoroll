-- ============================================================================
-- test_pianoroll.lua — Comprehensive Offline Regression & Interaction Suite
-- Run via:
--   python .../pdlua-run.py run pianoroll.pd_luajit --script test_pianoroll.lua --paint preview.svg --props --strict
-- ============================================================================

-- Polyfill pd._queue_repaint for plugdata 0.9.4+ pd.lua under offline pdmock.lua
if rawget(pd, "_queue_repaint") == nil and type(rawget(pd, "_repaint")) == "function" then
  pd._queue_repaint = function(obj_ptr, layer)
    return pd._repaint(obj_ptr, layer)
  end
end

-- Locate object instance cleanly from harness table
local obj = harness.obj or harness.object or rawget(harness, "_obj")
assert(obj ~= nil, "Expected harness.obj / harness.object to be set")

-- Load pure stateless helpers for exact coordinate assertions (safe via same package.path logic)
local dir = pd and rawget(pd, "_loadpath")
local saved_pp = package.path
if type(dir) == "string" and dir ~= "" then
  package.path = dir .. "/?.lua;" .. dir .. "\\?.lua;" .. saved_pp
end
local Layout = require("pr_layout")
local Model  = require("pr_model")
package.path = saved_pp

local function find_outlets(outlet_num, sel_filter)
  local all = harness.outlets()
  local res = {}
  for i = 1, #all do
    local msg = all[i]
    if (outlet_num == nil or msg.outlet == outlet_num)
       and (sel_filter == nil or msg.sel == sel_filter) then
      res[#res + 1] = msg
    end
  end
  return res
end

local function last_outlet(outlet_num, sel_filter)
  local list = find_outlets(outlet_num, sel_filter)
  return list[#list]
end

local function click(x, y)
  obj:mouse_down(x, y)
  obj:mouse_up(x, y)
end

local function drag(x0, y0, x1, y1, steps)
  steps = steps or 4
  obj:mouse_down(x0, y0)
  for s = 1, steps do
    local t = s / steps
    obj:mouse_drag(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t)
  end
  obj:mouse_up(x1, y1)
end

local function roll_xy_for(beat, pitch)
  local layout = Layout.compute(obj)
  local x = Layout.beat_to_px(obj, layout, beat)
  local y = Layout.pitch_to_py(obj, layout, pitch) + (obj.px_per_pitch * 0.5)
  return x, y, layout
end

local function send_msg(inlet, sel, ...)
  local atoms = { ... }
  harness.send(inlet, sel, atoms)
end

-- ----------------------------------------------------------------------------
-- Test 1: Blank click create, drag move, tail drag resize, double-click delete
-- ----------------------------------------------------------------------------
harness.clear_outlets()
obj:in_1("clear", {})
harness.assert_eq(#obj.notes, 0, "notes cleared before edit test")

local nx, ny = roll_xy_for(1.0 + 0.05, 64)
click(nx, ny)
harness.assert_eq(#obj.notes, 1, "blank click creates 1 note")
harness.assert_eq(obj.notes[1].pitch, 64, "created note pitch == 64")
harness.assert_near(obj.notes[1].start_beat, 1.0, 0.001, "created note snapped to 1.0")
local ed_add = last_outlet(4, "edited")
assert(ed_add and ed_add.atoms[1] == "add", "outlet 4 emitted edited add")

-- Drag note body from beat 1.1 (pitch 64) -> beat 2.1 (pitch 67)
local n_id = obj.notes[1].id
local mx0, my0 = roll_xy_for(1.05, 64)
local mx1, my1 = roll_xy_for(2.05, 67)
drag(mx0, my0, mx1, my1, 3)
local moved = Model.find_note_by_id(obj, n_id)
assert(moved ~= nil, "moved note still exists")
harness.assert_eq(moved.pitch, 67, "drag moved note vertically to pitch 67")
harness.assert_near(moved.start_beat, 2.0, 0.01, "drag moved note horizontally to beat 2.0")

-- Drag note tail right edge to extend length
local layout = Layout.compute(obj)
local tail_x = Layout.beat_to_px(obj, layout, moved.start_beat + moved.length) - 1
local tail_y = Layout.pitch_to_py(obj, layout, moved.pitch) + obj.px_per_pitch * 0.5
local new_end_x = Layout.beat_to_px(obj, layout, 3.5)
drag(tail_x, tail_y, new_end_x, tail_y, 3)
harness.assert_near(moved.length, 1.5, 0.05, "tail drag resized note length to 1.5 beats")

-- Double-click note to delete it (two consecutive clicks < 350ms)
harness.clear_outlets()
local dx, dy = roll_xy_for(2.5, 67)
click(dx, dy)
click(dx, dy)
harness.assert_eq(#obj.notes, 0, "double-click on note deleted it")
local ed_del = last_outlet(4, "edited")
assert(ed_del and ed_del.atoms[1] == "delete", "outlet 4 emitted edited delete")

-- ----------------------------------------------------------------------------
-- Test 2: Polyphonic sorted Outlet 1 output + Rest silence + Pause clears list
-- ----------------------------------------------------------------------------
harness.clear_outlets()
send_msg(1, "set_notes",
  67, 0.0, 1.0, 90,   -- G4 intentionally added before C4 to test ascending sort!
  60, 0.0, 2.0, 100,  -- C4
  64, 0.5, 1.5, 80,   -- E4
  72, 2.5, 1.0, 110   -- C5 after a 0.5-beat gap [2.0..2.5]
)
harness.assert_eq(#obj.notes, 4, "4 polyphonic notes loaded")

harness.clear_outlets()
send_msg(1, "bpm", 120)
send_msg(1, "play")

-- At beat 0.0: C4(60) & G4(67) should emit sorted {60, 67}
local m_start = last_outlet(1, "list")
assert(m_start ~= nil, "Outlet 1 emitted initial active chord list")
harness.assert_eq(#m_start.atoms, 2, "2 active pitches at beat 0")
harness.assert_eq(m_start.atoms[1], 60, "sorted first pitch == 60")
harness.assert_eq(m_start.atoms[2], 67, "sorted second pitch == 67")

-- Advance 350ms at 120 BPM = 0.7 beats -> E4(64) triggered at beat 0.5!
harness.clear_outlets()
harness.advance(350)
assert(obj.playhead_beat >= 0.55, "playhead advanced past beat 0.55")
local m_mid = last_outlet(1, "list")
assert(m_mid ~= nil, "Outlet 1 updated when E4 triggered")
harness.assert_eq(#m_mid.atoms, 3, "3 active sorted pitches {60, 64, 67}")
harness.assert_eq(m_mid.atoms[1], 60, "chord[1] == 60")
harness.assert_eq(m_mid.atoms[2], 64, "chord[2] == 64")
harness.assert_eq(m_mid.atoms[3], 67, "chord[3] == 67")

-- Test PAUSE clears Outlet 1 list!
harness.clear_outlets()
send_msg(1, "pause")
assert(obj.playing == false, "object paused")
local m_pause = last_outlet(1, "list")
assert(m_pause ~= nil, "Outlet 1 emitted list on pause")
harness.assert_eq(#m_pause.atoms, 0, "Outlet 1 MIDI list cleared to empty on pause!")
local m_pl = last_outlet(3, "playing")
assert(m_pl and m_pl.atoms[1] == 0, "Outlet 3 emitted playing 0 on pause")

-- Resume and advance into the rest gap [2.0..2.5] -> verifies automatic noteoff & empty list
send_msg(1, "seek", 1.8)
send_msg(1, "play")
harness.clear_outlets()
harness.advance(200) -- +0.4 beats -> beat ~2.2 (inside gap 2.0..2.5)
local m_gap = last_outlet(1, "list")
assert(m_gap ~= nil, "Outlet 1 emitted update at note endings")
harness.assert_eq(#m_gap.atoms, 0, "Outlet 1 cleared during rest gap")

-- Test STOP stops playback, rewinds, and ensures Outlet 1 is empty
send_msg(1, "stop")
assert(obj.playing == false, "stopped")
harness.assert_near(obj.playhead_beat, 0.0, 0.001, "stop rewound playhead to 0")

-- ----------------------------------------------------------------------------
-- Test 3: Inlet 4 [keyname]->[pak f a]: Ctrl marquee, Shift V/H zoom, Alt pan
-- ----------------------------------------------------------------------------
-- Ctrl + drag marquee selection across all 4 notes
send_msg(4, "list", 1, "Control_L")
assert(obj.keys_down["Control_L"] == true, "Control_L key recorded on inlet 4")
local qx0, qy0 = roll_xy_for(0.0, 74)
local qx1, qy1 = roll_xy_for(3.8, 58)
drag(qx1 + 8, qy0, qx0, qy1 + 8, 4)
send_msg(4, "list", 0, "Control_L")
harness.assert_eq(Model.count_selected(obj), 4, "Ctrl+drag marquee selected all 4 notes")

-- Ctrl + click one note toggles it out of selection
send_msg(4, "list", 1, "Control_L")
local tx, ty = roll_xy_for(2.7, 72)
click(tx, ty)
send_msg(4, "list", 0, "Control_L")
harness.assert_eq(Model.count_selected(obj), 3, "Ctrl+click toggled note out of selection")

-- Shift + drag UP/DOWN -> Vertical Zoom only (px_per_pitch changes, px_per_beat unchanged)
send_msg(4, "list", 1, "Shift_L")
local ppb0 = obj.px_per_beat
local ppp0 = obj.px_per_pitch
local bx, by = roll_xy_for(5.0, 70) -- blank area
drag(bx, by, bx, by - 45, 4)
assert(obj.px_per_pitch > ppp0 + 1.0, "Shift+drag UP zoomed in vertically (px_per_pitch increased)")
harness.assert_near(obj.px_per_beat, ppb0, 0.001, "Shift vertical zoom stayed axis-locked")

-- Shift + drag LEFT/RIGHT -> Horizontal Zoom only (px_per_beat changes, px_per_pitch unchanged)
local ppb1 = obj.px_per_beat
local ppp1 = obj.px_per_pitch
drag(bx, by, bx + 55, by, 4)
assert(obj.px_per_beat > ppb1 + 5.0, "Shift+drag RIGHT zoomed in horizontally (px_per_beat increased)")
harness.assert_near(obj.px_per_pitch, ppp1, 0.001, "Shift horizontal zoom stayed axis-locked")
send_msg(4, "list", 0, "Shift_L")

-- Alt + drag roll -> Free 2D pan
send_msg(4, "list", 1, "Alt_L")
local vb0 = obj.view_beat
local vpt0 = obj.view_pitch_top
send_msg(3, "scroll", 2.0, 84) -- ensure nonzero scroll room to pan both directions
vb0 = obj.view_beat
vpt0 = obj.view_pitch_top
drag(bx, by, bx + 60, by + 35, 4)
assert(obj.view_beat < vb0, "Alt+drag right panned view_beat earlier")
assert(obj.view_pitch_top > vpt0, "Alt+drag down panned view_pitch_top higher")
send_msg(4, "list", 0, "Alt_L")
send_msg(3, "scroll", 0.0, 82) -- restore nice framing

-- ----------------------------------------------------------------------------
-- Test 4: Ruler Click Seek, Ctrl+Drag Loop, Loop Wrap, Double-Click Delete Loop
-- ----------------------------------------------------------------------------
layout = Layout.compute(obj)
local r_mid_y = layout.ruler.y + layout.ruler.h * 0.5
local r_x2 = Layout.beat_to_px(obj, layout, 2.0)
click(r_x2, r_mid_y)
harness.assert_near(obj.playhead_beat, 2.0, 0.05, "ruler click seeked playhead to beat 2.0")

-- Ctrl + drag on ruler from beat 1.0 to beat 3.0 creates loop
send_msg(4, "list", 1, "Control_L")
local r_x1 = Layout.beat_to_px(obj, layout, 1.0)
local r_x3 = Layout.beat_to_px(obj, layout, 3.0)
drag(r_x1, r_mid_y, r_x3, r_mid_y, 4)
send_msg(4, "list", 0, "Control_L")
assert(obj.loop_enabled == true, "Ctrl+drag on ruler enabled loop")
harness.assert_near(obj.loop_start, 1.0, 0.05, "loop_start ~ 1.0")
harness.assert_near(obj.loop_end, 3.0, 0.05, "loop_end ~ 3.0")

-- Verify loop wrap during playback
send_msg(1, "seek", 2.8)
send_msg(1, "play")
harness.advance(250) -- +0.5 beat at 120 BPM -> 3.3 wraps to 1.3!
assert(obj.playing == true, "still playing during loop")
assert(obj.playhead_beat >= obj.loop_start and obj.playhead_beat < obj.loop_end,
       "playhead wrapped cleanly inside [loop_start, loop_end)")
send_msg(1, "stop")

-- Double-click on ruler deletes loop setting
click(r_x2, r_mid_y)
click(r_x2, r_mid_y)
assert(obj.loop_enabled == false and obj.loop_start == nil and obj.loop_end == nil,
       "ruler double-click cleared loop setting completely")

-- ----------------------------------------------------------------------------
-- Test 5: Scrollbars, Swapped Corner Controls (Reset & V-Zoom), Keyboard
-- ----------------------------------------------------------------------------
layout = Layout.compute(obj)

-- Bottom-right V-Zoom grip (hold & drag UP/DOWN)
local vz = layout.vzoom
assert(vz.x >= layout.roll.x + layout.roll.w - 0.5, "V-Zoom grip moved to bottom-right")
local vz_cx, vz_cy = vz.x + vz.w * 0.5, vz.y + vz.h * 0.5
local p_before_vz = obj.px_per_pitch
drag(vz_cx, vz_cy, vz_cx, vz_cy - 35, 4)
assert(obj.px_per_pitch > p_before_vz, "V-Zoom grip drag UP zoomed in vertically")

-- Top-right H-Zoom grip (hold & drag LEFT/RIGHT)
local hz = layout.hzoom
local hz_cx, hz_cy = hz.x + hz.w * 0.5, hz.y + hz.h * 0.5
local b_before_hz = obj.px_per_beat
drag(hz_cx, hz_cy, hz_cx + 35, hz_cy, 4)
assert(obj.px_per_beat > b_before_hz, "H-Zoom grip drag RIGHT zoomed in horizontally")

-- Bottom-left Reset Default Zoom & Position button
layout = Layout.compute(obj)
local cbl = layout.corner_bl
assert(cbl.x == 0 and cbl.w == layout.keyboard.w, "Reset button moved to bottom-left corner")
click(cbl.x + cbl.w * 0.5, cbl.y + cbl.h * 0.5)
harness.assert_near(obj.px_per_beat, Layout.DEF_PPB, 0.001, "bottom-left reset restored default H-zoom")
harness.assert_near(obj.px_per_pitch, Layout.DEF_PPP, 0.001, "bottom-left reset restored default V-zoom")
harness.assert_near(obj.view_beat, 0.0, 0.001, "bottom-left reset rewound view_beat to 0")

-- Zoom in so both scrollbars have room to scroll
send_msg(3, "zoom", 140, 18)
layout = Layout.compute(obj)
local ht = layout.h_thumb
if ht and layout.h_range_beats > 0.1 then
  local vb_pre = obj.view_beat
  drag(ht.x + ht.w * 0.5, ht.y + ht.h * 0.5, ht.x + ht.w * 0.5 + 40, ht.y + ht.h * 0.5, 3)
  assert(obj.view_beat > vb_pre, "H-scrollbar thumb drag scrolled view_beat right")
end

-- Right V-Scrollbar thumb drag
layout = Layout.compute(obj)
local vt = layout.v_thumb
if vt and layout.v_range_pitches > 0.1 then
  local vpt_pre = obj.view_pitch_top
  drag(vt.x + vt.w * 0.5, vt.y + vt.h * 0.5, vt.x + vt.w * 0.5, vt.y + vt.h * 0.5 + 30, 3)
  assert(obj.view_pitch_top < vpt_pre, "V-scrollbar thumb drag scrolled pitches down")
end

-- Reset view so pitches 65..67 are nicely centered before keyboard audition test
click(cbl.x + cbl.w * 0.5, cbl.y + cbl.h * 0.5)
layout = Layout.compute(obj)

-- Left Piano Keyboard audition & glissando
harness.clear_outlets()
local kb_x = layout.keyboard.x + layout.keyboard.w * 0.4
local kb_y1 = Layout.pitch_to_py(obj, layout, 65) + 4
local kb_y2 = Layout.pitch_to_py(obj, layout, 67) + 4
drag(kb_x, kb_y1, kb_x, kb_y2, 2)
local kb_ons = find_outlets(2, "noteon")
local kb_offs = find_outlets(2, "noteoff")
assert(#kb_ons >= 1 and #kb_offs >= 1, "keyboard drag auditioned pitches and sent noteoff on release")

-- ----------------------------------------------------------------------------
-- Test 6: Relative vs Absolute Snap Mode & Discrete Keys (space/Delete/Ctrl+A)
-- ----------------------------------------------------------------------------
send_msg(3, "scroll", 0.0, 66.0)
send_msg(3, "goto_pitch", 60)
send_msg(1, "snap", 1)
send_msg(1, "grid", "1/4") -- 1 beat step
send_msg(1, "snap_mode", 2) -- Relative Offset
send_msg(1, "set_notes", 60, 0.13, 1.0, 100)
local rel_n = obj.notes[1]
local rel_x0, rel_y0 = roll_xy_for(0.30, 60)
local rel_x1, _      = roll_xy_for(1.32, 60)
drag(rel_x0, rel_y0, rel_x1, rel_y0, 3)
harness.assert_near(rel_n.start_beat, 1.13, 0.02, "Relative snap preserved 0.13 beat offset")

-- Test Ctrl+A select all & Delete key via Inlet 4 [keyname]
send_msg(4, "list", 1, "Control_L")
send_msg(4, "list", 1, "a")
send_msg(4, "list", 0, "a")
send_msg(4, "list", 0, "Control_L")
harness.assert_eq(Model.count_selected(obj), 1, "Ctrl+A selected all notes")
send_msg(4, "list", 1, "Delete")
send_msg(4, "list", 0, "Delete")
harness.assert_eq(#obj.notes, 0, "Delete key deleted selected notes")

-- ----------------------------------------------------------------------------
-- Test 7: Resize Invariance
-- ----------------------------------------------------------------------------
send_msg(1, "fit")
local ppb_pre_res = obj.px_per_beat
local ppp_pre_res = obj.px_per_pitch
local lay_before  = Layout.compute(obj, 720, 380)

send_msg(1, "resize", 960, 520)
local new_w, new_h = obj:get_size()
harness.assert_eq(new_w, 960, "resized width == 960")
harness.assert_eq(new_h, 520, "resized height == 520")
harness.assert_near(obj.px_per_beat, ppb_pre_res, 0.001, "Resize invariant: px_per_beat preserved")
harness.assert_near(obj.px_per_pitch, ppp_pre_res, 0.001, "Resize invariant: px_per_pitch preserved")

local lay_after = Layout.compute(obj)
harness.assert_eq(lay_after.toolbar.h, lay_before.toolbar.h, "Resize invariant: toolbar height preserved")
harness.assert_eq(lay_after.ruler.h, lay_before.ruler.h, "Resize invariant: ruler height preserved")
harness.assert_eq(lay_after.keyboard.w, lay_before.keyboard.w, "Resize invariant: keyboard width preserved")
harness.assert_eq(lay_after.hscroll.h, lay_before.hscroll.h, "Resize invariant: hscroll height preserved")
harness.assert_eq(lay_after.vscroll.w, lay_before.vscroll.w, "Resize invariant: vscroll width preserved")
harness.assert_eq(lay_after.roll.w, lay_before.roll.w + 240, "Resize grew ONLY roll width by +240")
harness.assert_eq(lay_after.roll.h, lay_before.roll.h + 140, "Resize grew ONLY roll height by +140")

-- ----------------------------------------------------------------------------
-- Test 8: Default "Last Note" Length Inheritance & Toggle (L:LST / L:GRD)
-- ----------------------------------------------------------------------------
send_msg(1, "resize", 720, 380)
send_msg(1, "clear")
send_msg(1, "reset_view")
send_msg(1, "grid", "1/16") -- 0.25 beat
send_msg(1, "snap", 1)
send_msg(1, "snap_mode", "abs")
obj.last_note_len = 0.0
assert(obj.default_len_mode == 1, "default_len_mode defaults to 1 (Last Note)")

-- First note with no prior length falls back to Grid Step (0.25)
local l1x, l1y = roll_xy_for(0.05, 64)
click(l1x, l1y)
harness.assert_eq(#obj.notes, 1, "first note placed")
harness.assert_near(obj.notes[1].length, 0.25, 0.001, "initial Last Note fallback used grid step 0.25")

-- Resize first note tail from 0.25 to 1.0 beat
layout = Layout.compute(obj)
local n1 = obj.notes[1]
local n1_tail_x = Layout.beat_to_px(obj, layout, n1.start_beat + n1.length) - 1
local n1_mid_y  = Layout.pitch_to_py(obj, layout, n1.pitch) + obj.px_per_pitch * 0.5
local n1_new_ex = Layout.beat_to_px(obj, layout, 1.0)
drag(n1_tail_x, n1_mid_y, n1_new_ex, n1_mid_y, 3)
harness.assert_near(n1.length, 1.0, 0.05, "resized note 1 to 1.0 beat")

-- Placing next note inherits 1.0 beat automatically!
local l2x, l2y = roll_xy_for(2.05, 67)
click(l2x, l2y)
harness.assert_eq(#obj.notes, 2, "second note placed")
local n2 = obj.notes[2]
harness.assert_near(n2.length, 1.0, 0.05, "new note inherited length 1.0 from modified note")

-- Add a short 0.5-beat note via set_notes + click it -> inherits 0.5 on next place
send_msg(1, "add", 60, 4.0, 0.5, 100)
local cx05, cy05 = roll_xy_for(4.2, 60)
click(cx05, cy05)
-- Clicking & dragging in Last Note mode moves the newly created note position while locking length to 0.5
local l3x, l3y = roll_xy_for(5.05, 62)
local l3_drag_end_x, l3_drag_end_y = roll_xy_for(5.55, 64)
drag(l3x, l3y, l3_drag_end_x, l3_drag_end_y, 4)
local moved_lst_note = Model.hit_test_px(obj, Layout.compute(obj), l3_drag_end_x, l3_drag_end_y)
assert(moved_lst_note ~= nil, "third note placed and dragged to new position in Last Note mode")
harness.assert_eq(moved_lst_note.pitch, 64, "Last Note mode drag moved created note pitch to 64")
harness.assert_near(moved_lst_note.start_beat, 5.5, 0.05, "Last Note mode drag moved created note start_beat to 5.5")
harness.assert_near(moved_lst_note.length, 0.5, 0.001, "Last Note mode preserved creation length 0.5 during drag")

-- Toggle toolbar len_mode pill -> switches to Grid Step (mode 2)
layout = Layout.compute(obj)
local lmb = layout.btns.len_mode
click(lmb.x + lmb.w * 0.5, lmb.y + lmb.h * 0.5)
harness.assert_eq(obj.default_len_mode, 2, "toolbar len_mode toggle switched to Grid Step (2)")
local l4x, l4y = roll_xy_for(6.05, 65)
click(l4x, l4y)
local grid_note = Model.hit_test_px(obj, Layout.compute(obj), l4x, l4y)
assert(grid_note ~= nil, "fourth note placed in Grid Step mode")
harness.assert_near(grid_note.length, 0.25, 0.001, "Grid Step mode ignored last_note_len and used 0.25")

-- Clicking & dragging in GRID mode MUST allow editing length during creation
local l5x, l5y = roll_xy_for(7.05, 68)
local l5_drag_end_x = Layout.beat_to_px(obj, Layout.compute(obj), 8.5)
drag(l5x, l5y, l5_drag_end_x, l5y, 4)
local dragged_grid_note = Model.hit_test_px(obj, Layout.compute(obj), l5x, l5y)
assert(dragged_grid_note ~= nil, "fifth note placed via drag in GRID mode")
harness.assert_near(dragged_grid_note.length, 1.5, 0.05, "GRID mode allowed drag-resizing length during creation")

-- Toggle back to default Last Note (1)
click(lmb.x + lmb.w * 0.5, lmb.y + lmb.h * 0.5)
harness.assert_eq(obj.default_len_mode, 1, "toolbar len_mode toggle restored Last Note (1)")

-- ----------------------------------------------------------------------------
-- Test 9: Multi-Select Double-Click Simultaneously Deletes All Selected Notes
-- ----------------------------------------------------------------------------
send_msg(1, "set_notes",
  60, 0.0, 0.5, 100,
  64, 1.0, 0.5, 100,
  67, 2.0, 0.5, 100
)
send_msg(4, "list", 1, "Control_L")
send_msg(4, "list", 1, "a")
send_msg(4, "list", 0, "a")
send_msg(4, "list", 0, "Control_L")
harness.assert_eq(Model.count_selected(obj), 3, "all 3 notes selected before double-click")
local dmx, dmy = roll_xy_for(1.2, 64)
click(dmx, dmy)
click(dmx, dmy)
harness.assert_eq(#obj.notes, 0, "double-clicking one selected note deleted all 3 selected notes simultaneously")

-- ----------------------------------------------------------------------------
-- Test 10: Shift + Horizontal Zoom Anchoring (Left when Screen-Filled, Cursor when Scrollable)
-- ----------------------------------------------------------------------------
-- Case A: Full clip fits screen (px_per_beat = 30 -> visible beats > 16, view_beat = 0)
send_msg(1, "length", 16)
send_msg(3, "zoom", 30, 13)
send_msg(3, "scroll", 0.0, 82)
layout = Layout.compute(obj)
assert(layout.h_visible_beats >= 16.0, "zoom 30 fits full 16-beat sequence on screen")
send_msg(4, "list", 1, "Shift_L")
local sx_a = layout.roll.x + layout.roll.w * 0.65
local sy_a = layout.roll.y + layout.roll.h * 0.5
drag(sx_a, sy_a, sx_a + 55, sy_a, 4)
assert(obj.px_per_beat > 30.0, "Shift+drag right zoomed in from full-screen view")
harness.assert_near(obj.view_beat, 0.0, 0.001, "Screen-filled horizontal zoom anchored at left edge (view_beat == 0)")

-- Case B: Zoomed in / scrollable -> strictly anchors at cursor beat
send_msg(3, "zoom", 120, 13)
send_msg(3, "scroll", 2.5, 82)
layout = Layout.compute(obj)
local sx_b = layout.roll.x + layout.roll.w * 0.55
local sy_b = layout.roll.y + layout.roll.h * 0.5
local beat_cursor_before = Layout.px_to_beat(obj, layout, sx_b)
drag(sx_b, sy_b, sx_b + 65, sy_b, 4)
local beat_cursor_after = Layout.px_to_beat(obj, Layout.compute(obj), sx_b)
assert(obj.px_per_beat > 120.0, "Shift+drag right zoomed in while scrollable")
harness.assert_near(beat_cursor_after, beat_cursor_before, 0.02, "Scrollable horizontal zoom strictly anchored at cursor X")

-- Case C: Zooming back out to full screen settles cleanly at view_beat == 0
drag(sx_b, sy_b, sx_b - 220, sy_b, 6)
harness.assert_near(obj.view_beat, 0.0, 0.001, "Zooming back out settles view_beat cleanly to 0")
send_msg(4, "list", 0, "Shift_L")

-- ----------------------------------------------------------------------------
-- Test 11: Snap Mode 4 ("Visible Grid Lines" / VIS) & Higher Grid Density
-- ----------------------------------------------------------------------------
send_msg(1, "clear")
send_msg(1, "reset_view")
send_msg(1, "grid", "1/16")
send_msg(1, "snap", 1)
send_msg(1, "snap_mode", "vis")
harness.assert_eq(obj.snap_mode, 4, "snap_mode 'vis' selected mode 4")
send_msg(3, "zoom", 12, 13) -- 1/16 (3px) < 4.5px min spacing, so coarsens to 1/8 (0.5 beat = 6px)
harness.assert_near(Model.get_draw_grid_step(obj), 0.5, 0.001, "Density limit keeps 1/8 grid visible at 12px/beat")
send_msg(3, "zoom", 8, 13)  -- 0.5*8 = 4px < 4.5px -> coarsens further to 1.0 beat (8px >= 6px)
local vis_draw_step = Model.get_draw_grid_step(obj)
local vis_snap_step = Model.get_grid_step(obj)
assert(vis_draw_step >= 1.0, "Visible grid step coarsened to >= 1 beat when zoomed out to 8px/beat")
harness.assert_near(vis_snap_step, vis_draw_step, 0.001, "VIS snap step matches drawn grid line spacing 1:1")
assert(vis_snap_step * obj.px_per_beat >= (Model.MIN_SUB_GRID_PX or 4.5), "VIS visible grid interval respects density threshold")
local vx, vy = roll_xy_for(1.3, 64)
click(vx, vy)
harness.assert_eq(#obj.notes, 1, "created note under VIS snap mode")
harness.assert_near(obj.notes[1].start_beat, 1.0, 0.001, "VIS snap aligned click to visible 1.0 beat grid line")
send_msg(1, "snap_mode", "abs")
send_msg(1, "reset_view")

-- ----------------------------------------------------------------------------
-- Test 12: Bottom H-Scrollbar Leftmost Drag Monotonic (Zero Twitch)
-- ----------------------------------------------------------------------------
send_msg(1, "clear")
send_msg(1, "length", 16)
send_msg(3, "zoom", 120, 13)
layout = Layout.compute(obj)
assert(layout.h_range_beats > 4.0, "zoom 120 gives wide scroll range")
local hs_t = layout.h_thumb
drag(hs_t.x + hs_t.w * 0.5, hs_t.y + hs_t.h * 0.5, hs_t.x + hs_t.w * 0.5 + 150, hs_t.y + hs_t.h * 0.5, 4)
assert(obj.view_beat > 3.0, "scrolled right before testing leftmost drag (got " .. tostring(obj.view_beat) .. ")")

layout = Layout.compute(obj)
hs_t = layout.h_thumb
local drag_start_x = hs_t.x + hs_t.w * 0.5
local drag_y       = hs_t.y + hs_t.h * 0.5
local drag_end_x   = layout.hscroll.x - 40
obj:mouse_down(drag_start_x, drag_y)
local prev_vb = obj.view_beat
for s = 1, 14 do
  local t = s / 14
  obj:mouse_drag(drag_start_x + (drag_end_x - drag_start_x) * t, drag_y)
  assert(obj.view_beat <= prev_vb + 1e-9, "H-scrollbar drag left never twitches rightward")
  prev_vb = obj.view_beat
end
obj:mouse_up(drag_end_x, drag_y)
harness.assert_near(obj.view_beat, 0.0, 0.001, "H-scrollbar settled stably at view_beat == 0.0")

-- ----------------------------------------------------------------------------
-- Test 13: Background Grid Syncs to Snap/Grid Setting & Zoom Density Limit
-- ----------------------------------------------------------------------------
local Render = require("pr_render")
local function count_roll_grid_lines()
  local lay = Layout.compute(obj)
  local r = lay.roll
  local v_xs, h_ys = {}, {}
  local noop = function() end
  local spy_g = setmetatable({
    draw_line = function(_, x1, y1, x2, y2, lw)
      -- Vertical grid lines spanning full roll height (ignore seq_end marker lw=1.5)
      if (lw or 1.0) < 1.4 and math.abs(x1 - x2) < 0.01 and math.abs(y1 - r.y) < 0.01 and math.abs(y2 - (r.y + r.h)) < 0.01 then
        if x1 > r.x + 1.0 and x1 < r.x + r.w - 1.0 then
          v_xs[#v_xs + 1] = x1
        end
      elseif (lw or 1.0) < 1.4 and math.abs(y1 - y2) < 0.01 and math.abs(x1 - r.x) < 0.01 and math.abs(x2 - (r.x + r.w)) < 0.01 then
        h_ys[#h_ys + 1] = y1
      end
    end,
  }, {
    __index = function() return noop end,
  })
  Render.paint_layer_1(obj, spy_g)
  table.sort(v_xs)
  return v_xs, h_ys
end

send_msg(1, "clear")
send_msg(1, "length", 32)
send_msg(1, "reset_view")
send_msg(1, "snap_mode", "abs")
send_msg(3, "zoom", 72, 13)

-- Changing grid division (1/16 -> 1/8 -> 1/4 -> 1/2 -> 1/1) synchronously updates vertical grid lines
local grid_counts = {}
for _, gname in ipairs({ "1/16", "1/8", "1/4", "1/2", "1/1" }) do
  send_msg(1, "grid", gname)
  local xs = count_roll_grid_lines()
  grid_counts[gname] = #xs
end
assert(grid_counts["1/16"] > grid_counts["1/8"]
   and grid_counts["1/8"]  > grid_counts["1/4"]
   and grid_counts["1/4"]  > grid_counts["1/2"]
   and grid_counts["1/2"]  > grid_counts["1/1"],
  "Grid lines strictly synced across 1/16 -> 1/8 -> 1/4 -> 1/2 -> 1/1")

-- Zooming out horizontally thins out dense lines respecting density limit, while keeping finer grids visible earlier
send_msg(1, "grid", "1/32")
send_msg(3, "zoom", 40, 13)
harness.assert_near(Model.get_draw_grid_step(obj), 0.125, 0.001, "1/32 grid visible already at 40px/beat")
send_msg(1, "grid", "1/16")
send_msg(3, "zoom", 20, 13)
harness.assert_near(Model.get_draw_grid_step(obj), 0.25, 0.001, "1/16 grid visible even when zoomed out to 20px/beat")

local function count_in_first_8b(xs, ppb, roll_x)
  local x_limit = roll_x + 8.0 * ppb + 0.5
  local c = 0
  for i = 1, #xs do
    if xs[i] <= x_limit then c = c + 1 end
  end
  return c
end

send_msg(3, "zoom", 72, 13)
local xs_72 = count_roll_grid_lines()
local c8_72 = count_in_first_8b(xs_72, 72, Layout.compute(obj).roll.x)
local st_72 = Model.get_draw_grid_step(obj)
send_msg(3, "zoom", 15, 13)
local xs_15 = count_roll_grid_lines()
local c8_15 = count_in_first_8b(xs_15, 15, Layout.compute(obj).roll.x)
local st_15 = Model.get_draw_grid_step(obj)
send_msg(3, "zoom", 5, 13)
local xs_05 = count_roll_grid_lines()
local c8_05 = count_in_first_8b(xs_05, 5, Layout.compute(obj).roll.x)
local st_05 = Model.get_draw_grid_step(obj)
assert(st_72 < st_15 and st_15 < st_05 and c8_72 > c8_15 and c8_15 > c8_05,
       "Zooming out coarsened draw grid step and reduced drawn vertical lines per beat")
assert(st_05 >= 2.0, "At tiny 5px/beat zoom, background thins out beats/subdivisions cleanly")
for _, xs in ipairs({ xs_72, xs_15, xs_05 }) do
  for i = 2, #xs do
    local diff = xs[i] - xs[i - 1]
    assert(diff >= 4.4, "Drawn vertical grid spacing >= 4.4px (got " .. tostring(diff) .. ")")
  end
end

-- Zooming out vertically hides minor pitch divider lines below ppp < 5.5
send_msg(3, "vzoom", 13)
local _, ys_13 = count_roll_grid_lines()
send_msg(3, "vzoom", 5)
local _, ys_05 = count_roll_grid_lines()
assert(#ys_05 < #ys_13, "Vertical zoom-out hid minor row separator lines keeping only octaves")
send_msg(1, "length", 16)

-- ----------------------------------------------------------------------------
-- Test 14: Blank Click Deselects After Ctrl Multi-Select, Nearest Grid Snap,
--          Deepened & Customizable Grid Color + Contrast Properties
-- ----------------------------------------------------------------------------
-- Req 2: Ctrl multi-select -> release Ctrl -> blank click cancels selection WITHOUT creating a note
send_msg(1, "reset_view")
send_msg(1, "grid", "1/4") -- 1.0 beat step
send_msg(1, "snap", 1)
send_msg(1, "snap_mode", "abs")
send_msg(1, "set_notes",
  60, 0.0, 0.5, 100,
  64, 1.0, 0.5, 100,
  67, 2.0, 0.5, 100
)
send_msg(4, "list", 1, "Control_L")
local mq0x, mq0y = roll_xy_for(0.0, 70)
local mq1x, mq1y = roll_xy_for(3.0, 58)
drag(mq0x, mq0y, mq1x, mq1y, 4)
send_msg(4, "list", 0, "Control_L")
harness.assert_eq(Model.count_selected(obj), 3, "Ctrl marquee selected 3 notes")

local bx_blank, by_blank = roll_xy_for(4.1, 64)
click(bx_blank, by_blank)
harness.assert_eq(Model.count_selected(obj), 0, "blank click after Ctrl multi-select cleared selection")
harness.assert_eq(#obj.notes, 3, "blank click after Ctrl multi-select did NOT create a note")

-- Subsequent blank click when nothing is multi-selected DOES create a note normally
click(bx_blank, by_blank)
harness.assert_eq(#obj.notes, 4, "blank click after deselection creates note normally")

-- Req 3: Nearest grid line snap on create (grid step = 1.0 beat)
-- Clicking at beat 5.85 is closer to 6.0 (right grid) than 5.0 (left grid) -> creates at 6.0!
local near_right_x, near_right_y = roll_xy_for(5.85, 65)
click(near_right_x, near_right_y)
harness.assert_eq(#obj.notes, 5, "created note near right grid boundary")
harness.assert_near(obj.notes[5].start_beat, 6.0, 0.001, "nearest-grid snap placed note at 6.0 instead of flooring to 5.0")

-- Clicking at beat 7.15 is closer to 7.0 (left grid) than 8.0 (right grid) -> creates at 7.0!
local near_left_x, near_left_y = roll_xy_for(7.15, 67)
click(near_left_x, near_left_y)
harness.assert_eq(#obj.notes, 6, "created note near left grid boundary")
harness.assert_near(obj.notes[6].start_beat, 7.0, 0.001, "nearest-grid snap placed note at 7.0")

-- Req 4: Grid Color & Grid Contrast adjustable in Properties + Palette
local Theme = require("pr_theme")
obj:prop_grid_color({ 70, 90, 130 })
obj:prop_grid_contrast(1.45)
local pal_custom = Theme.resolve(obj)
harness.assert_eq(pal_custom.grid_color[1], 70, "prop_grid_color updated palette red")
harness.assert_eq(pal_custom.grid_color[3], 130, "prop_grid_color updated palette blue")
assert(pal_custom.grid_bar_a > 0.9, "higher grid_contrast deepened bar line alpha")
-- Reset default grid color & contrast before final preview
obj:prop_grid_color({ 96, 102, 114 })
obj:prop_grid_contrast(1.0)

-- Restore clean 720x380 view & test new features (Alt-Pan, Copy/Cut/Paste/Dup, Undo/Redo, Overlays)
-- ----------------------------------------------------------------------------
-- Test 15: Free Alt+Drag Horizontal Pan Even When Zoomed Out / Screen-Filled
-- ----------------------------------------------------------------------------
send_msg(1, "clear")
send_msg(1, "length", 16)
send_msg(3, "zoom", 24, 13) -- h_visible_beats (~27b) > 16b -> would have clamped to 0 previously!
send_msg(3, "scroll", 0.0, 82)
layout = Layout.compute(obj)
assert(layout.h_visible_beats > 16.0, "zoom 24 fits all 16 beats on screen")
send_msg(4, "list", 1, "Alt_L")
local apx, apy = layout.roll.x + layout.roll.w * 0.6, layout.roll.y + layout.roll.h * 0.5
drag(apx, apy, apx - 120, apy, 4) -- pan left -> advance rightward in beats
assert(obj.view_beat > 4.0, "Alt+drag panned freely right along timeline even without zooming in")
drag(apx, apy, apx + 60, apy, 3)  -- pan back slightly right -> smaller beat
assert(obj.view_beat < 4.5 and obj.view_beat > 0.5, "Alt+drag back panned smoothly without snapping back to 0")
send_msg(4, "list", 0, "Alt_L")
send_msg(1, "fit")
harness.assert_near(obj._pan_extra_beats or 0.0, 0.0, 0.001, "FIT reset free-pan extension padding cleanly")

-- ----------------------------------------------------------------------------
-- Test 16: Copy / Cut / Paste / Duplicate + Smart Paste Placement
-- ----------------------------------------------------------------------------
send_msg(1, "reset_view")
send_msg(1, "grid", "1/16")
send_msg(1, "snap", 1)
send_msg(1, "snap_mode", "abs")
send_msg(1, "set_notes",
  60, 0.0, 0.5, 100,
  64, 0.5, 0.5, 100
)
send_msg(1, "seek", 0.0)
send_msg(1, "select_all")
harness.assert_eq(Model.count_selected(obj), 2, "selected 2 source notes")

-- Copy via toolbar CPY pill, then Paste twice via PST pill (sequential non-overlapping)
layout = Layout.compute(obj)
local cpy_b = layout.btns.copy
local pst_b = layout.btns.paste
local cut_b = layout.btns.cut
click(cpy_b.x + cpy_b.w * 0.5, cpy_b.y + cpy_b.h * 0.5)
assert(Model.has_clipboard(obj), "CPY toolbar pill stored 2 notes on clipboard")
click(pst_b.x + pst_b.w * 0.5, pst_b.y + pst_b.h * 0.5)
harness.assert_eq(#obj.notes, 4, "first paste added 2 notes cleanly after selection")
local p1_notes = Model.get_selected_notes(obj)
harness.assert_eq(#p1_notes, 2, "pasted notes became selected")
harness.assert_near(p1_notes[1].start_beat, 1.0, 0.001, "first paste landed cleanly at beat 1.0")

click(pst_b.x + pst_b.w * 0.5, pst_b.y + pst_b.h * 0.5)
harness.assert_eq(#obj.notes, 6, "second paste advanced cleanly without overlapping")

-- Move playhead to beat 6.0 and Cut selected notes, then Paste at playhead 6.0
send_msg(1, "seek", 6.0)
click(cut_b.x + cut_b.w * 0.5, cut_b.y + cut_b.h * 0.5)
harness.assert_eq(#obj.notes, 4, "CUT removed selected 2 notes")
click(pst_b.x + pst_b.w * 0.5, pst_b.y + pst_b.h * 0.5)
harness.assert_eq(#obj.notes, 6, "Paste after seeking pasted cut notes at new count")
local cut_pasted = Model.get_selected_notes(obj)
table.sort(cut_pasted, function(a, b) return a.start_beat < b.start_beat end)
harness.assert_near(cut_pasted[1].start_beat, 6.0, 0.001, "Paste landed at playhead 6.0")

-- Alt+d Duplicate immediately clones selection directly after it (beat 7.0)
send_msg(4, "list", 1, "Alt_L")
send_msg(4, "list", 1, "d")
send_msg(4, "list", 0, "d")
send_msg(4, "list", 0, "Alt_L")
harness.assert_eq(#obj.notes, 8, "Alt+D duplicated selected phrase")
local dup_notes = Model.get_selected_notes(obj)
table.sort(dup_notes, function(a, b) return a.start_beat < b.start_beat end)
harness.assert_near(dup_notes[1].start_beat, 7.0, 0.001, "Duplicate placed clone cleanly at beat 7.0")

-- ----------------------------------------------------------------------------
-- Test 17: Undo/Redo History Pool & Unintercepted Plugdata Shortcut Paths
-- ----------------------------------------------------------------------------
send_msg(1, "clear")
Model.init_history(obj)
assert(not Model.can_undo(obj) and not Model.can_redo(obj), "fresh history empty")

-- Step 1: Click-create a note at beat 0.0 (0.10 < 0.125 snaps to 0.0)
local ux0, uy0 = roll_xy_for(0.10, 62)
click(ux0, uy0)
harness.assert_eq(#obj.notes, 1, "created initial note")
harness.assert_near(obj.notes[1].start_beat, 0.0, 0.001, "note snapped cleanly to 0.0")
local created_id = obj.notes[1].id

-- Clicking note WITHOUT moving (after double-click window) must NOT push spurious no-op undo entry
harness.advance(400)
local pre_depth = #obj.undo_stack
click(ux0, uy0)
harness.assert_eq(#obj.undo_stack, pre_depth, "clicking note without editing did not push duplicate undo entry")

-- Step 2: Drag note to pitch 65, beat 1.0
harness.advance(400)
local ux1, uy1 = roll_xy_for(1.10, 65)
drag(ux0, uy0, ux1, uy1, 4)
harness.assert_eq(obj.notes[1].pitch, 65, "drag moved note to pitch 65")

-- Step 3: Cut via hover-gated single key 'x' (mouse hovered inside widget)
obj:mouse_enter(layout.roll.x + 10, layout.roll.y + 10)
assert(obj._mouse_inside == true, "mouse_enter enabled hover hotkeys")
send_msg(4, "list", 1, "x")
send_msg(4, "list", 0, "x")
harness.assert_eq(#obj.notes, 0, "hover single-key 'x' cut selected note")

-- Hover leave immediately disables single-key hotkeys so Pd typing never collides
obj:mouse_exit(-10, -10)
assert(obj._mouse_inside == false, "mouse_exit disabled hover hotkeys")
send_msg(4, "list", 1, "v")
send_msg(4, "list", 0, "v")
harness.assert_eq(#obj.notes, 0, "single-key 'v' ignored when mouse outside widget")

-- Toolbar UND/RDO + Alt+Z + sticky virtual [C] badge bypass all work seamlessly
layout = Layout.compute(obj)
local und_b = layout.btns.undo
local rdo_b = layout.btns.redo
click(und_b.x + und_b.w * 0.5, und_b.y + und_b.h * 0.5) -- Undo Cut -> note back at pitch 65!
harness.assert_eq(#obj.notes, 1, "UND pill restored cut note")
harness.assert_eq(obj.notes[1].pitch, 65, "restored note at moved pitch 65")

send_msg(4, "list", 1, "Alt_L")
send_msg(4, "list", 1, "z")
send_msg(4, "list", 0, "z")
send_msg(4, "list", 0, "Alt_L") -- Undo Move -> back to pitch 62!
harness.assert_eq(#obj.notes, 1, "Alt+Z undid move")
harness.assert_eq(obj.notes[1].pitch, 62, "restored note pitch 62 before move")
harness.assert_eq(obj.notes[1].id, created_id, "restored exact note ID")

click(und_b.x + und_b.w * 0.5, und_b.y + und_b.h * 0.5) -- Undo Create -> 0 notes!
harness.assert_eq(#obj.notes, 0, "UND undid initial click creation back to 0 notes")

-- Redo forward twice via RDO pill + Alt+Y
click(rdo_b.x + rdo_b.w * 0.5, rdo_b.y + rdo_b.h * 0.5)
harness.assert_eq(#obj.notes, 1, "RDO re-applied note create")
send_msg(4, "list", 1, "Alt_L")
send_msg(4, "list", 1, "y")
send_msg(4, "list", 0, "y")
send_msg(4, "list", 0, "Alt_L")
harness.assert_eq(obj.notes[1].pitch, 65, "Alt+Y redid move cleanly to pitch 65")

-- Sticky clickable virtual [C] badge + bare 'c' / 'v' works without physical Ctrl
local mod_c = layout.btns.mod_ctrl
click(mod_c.x + mod_c.w * 0.5, mod_c.y + mod_c.h * 0.5)
assert(obj.keys_down["Control_L"] == true, "virtual [C] badge latched Control_L")
send_msg(4, "list", 1, "c")
send_msg(4, "list", 0, "c")
send_msg(4, "list", 1, "v")
send_msg(4, "list", 0, "v")
harness.assert_eq(#obj.notes, 2, "sticky [C] + c/v copied & pasted without physical Ctrl")
click(mod_c.x + mod_c.w * 0.5, mod_c.y + mod_c.h * 0.5) -- unlatch [C]

-- ----------------------------------------------------------------------------
-- Test 18: Active Multi-Note Edit Layer-3 Feedback Render Smoke Check
-- ----------------------------------------------------------------------------
send_msg(1, "select_all")
local l3_idle, l3_active = 0, 0
local noop3 = function() end
local function make_spy3(inc)
  return setmetatable({
    fill_rect          = inc,
    stroke_rect        = inc,
    fill_rounded_rect  = inc,
    stroke_rounded_rect = inc,
    draw_line          = inc,
    draw_text          = inc,
  }, { __index = function() return noop3 end })
end
Render.paint_layer_3(obj, make_spy3(function() l3_idle = l3_idle + 1 end))
obj:mouse_down(roll_xy_for(obj.notes[1].start_beat + 0.1, obj.notes[1].pitch))
obj:mouse_drag(roll_xy_for(obj.notes[1].start_beat + 0.6, obj.notes[1].pitch + 2))
Render.paint_layer_3(obj, make_spy3(function() l3_active = l3_active + 1 end))
assert(l3_active > l3_idle + 8 and l3_active > 15,
       "Active multi-note edit Layer 3 emitted ghost/guide/halo overlays (idle=" .. tostring(l3_idle) .. ", active=" .. tostring(l3_active) .. ")")
obj:mouse_up(roll_xy_for(obj.notes[1].start_beat + 0.6, obj.notes[1].pitch + 2))

-- Restore clean 720x380 view & populate rich demo pattern for preview.svg inspection
send_msg(1, "resize", 720, 380)
send_msg(1, "theme", "auto")
send_msg(1, "grid", "1/16")
send_msg(1, "snap_mode", "abs")
send_msg(1, "loop", 0.0, 4.0)
send_msg(1, "set_notes",
  -- Bar 1 Cm9 chord + melody line for visually clear preview
  48, 0.0, 2.0, 95,
  55, 0.0, 2.0, 88,
  60, 0.0, 1.0, 100,
  63, 0.0, 1.5, 92,
  67, 0.5, 1.0, 108,
  70, 1.0, 1.0, 112,
  74, 1.5, 0.5, 118,
  -- Bar 2 Abmaj7 -> G7
  56, 2.0, 1.0, 96,
  60, 2.0, 1.0, 90,
  63, 2.0, 1.0, 94,
  67, 2.5, 0.5, 110,
  55, 3.0, 1.0, 98,
  59, 3.0, 1.0, 92,
  62, 3.0, 0.75, 102,
  65, 3.25, 0.75, 114
)
send_msg(1, "fit")
send_msg(1, "seek", 1.25)
Model.select_only(obj, obj.notes[7].id)

-- Test properties callbacks + persistence
obj:prop_bpm(128)
obj:prop_note_color({ 84, 214, 184 })
obj:prop_grid_color({ 88, 96, 110 })
obj:prop_grid_contrast(1.1)
harness.assert_near(obj.bpm, 128, 0.001, "prop_bpm updated bpm")
obj:save_state()
local fn_get_args = obj.get_args
if type(fn_get_args) == "function" then
  local saved_args = fn_get_args(obj)
  assert(saved_args and saved_args[52] == -2 and saved_args[57] == -3 and #saved_args > 58,
         "save_state persisted v2/v3 headers + notes in args")
end

pd.post("[TEST PASSED] All pianoroll DAW interaction, protocol & layout assertions succeeded.")
