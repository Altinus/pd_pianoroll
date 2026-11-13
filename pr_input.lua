-- ============================================================================
-- pr_input.lua — Stateless Mouse, Scrollbar, Zoom & External Keyname Handler
-- ============================================================================

local Layout   = require("pr_layout")
local Model    = require("pr_model")
local Playback = require("pr_playback")

local Input = {}

local floor = math.floor
local ceil  = math.ceil
local abs   = math.abs
local max   = math.max
local min   = math.min
local exp   = math.exp

local function is_ctrl(self)
  local kd = self.keys_down
  if not kd then return false end
  return kd["Control_L"] or kd["Control_R"] or kd["Ctrl"] or kd["ctrl"]
end

local function is_shift(self)
  local kd = self.keys_down
  if not kd then return false end
  return kd["Shift_L"] or kd["Shift_R"] or kd["Shift"] or kd["shift"]
end

local function is_alt(self)
  local kd = self.keys_down
  if not kd then return false end
  return kd["Alt_L"] or kd["Alt_R"] or kd["Alt"] or kd["alt"]
end

Input.is_ctrl  = is_ctrl
Input.is_shift = is_shift
Input.is_alt   = is_alt

local function mark_all_dirty(self)
  self._dirty_l1 = true
  self._dirty_l2 = true
  self._dirty_l3 = true
end

-- Pure cursor-anchored zoom-in & boundary-clamped zoom-out horizontal solver
local function apply_hzoom(self, layout, new_ppb, orig_ppb, orig_extra, anchor_beat, anchor_rel_x)
  self.px_per_beat = new_ppb
  local base_h_total = max(self.length_beats or 16, self.max_end_beat or 0, 4.0)
  local h_vis_new = layout.roll.w / new_ppb
  local raw_vb = anchor_beat - anchor_rel_x / new_ppb

  if new_ppb > orig_ppb + 1e-9 then
    -- Zoom IN: anchor strictly at initial mouse beat (never stick to left/right edge)
    local new_vb = max(0.0, raw_vb)
    local needed_extra = max(0.0, new_vb + h_vis_new - base_h_total)
    self._pan_extra_beats = (new_vb > 1e-4) and needed_extra or 0.0
    self.view_beat = new_vb
  else
    -- Zoom OUT: anchor at mouse until left (0) or right content boundary hits viewport edge
    local right_limit = base_h_total + (orig_extra or 0.0)
    local max_vb = max(0.0, right_limit - h_vis_new)
    local clamped_vb = max(0.0, min(max_vb, raw_vb))
    self.view_beat = clamped_vb
    if clamped_vb <= 1e-4 and h_vis_new >= base_h_total - 1e-4 then
      self._pan_extra_beats = 0.0
    else
      self._pan_extra_beats = max(0.0, min(orig_extra or 0.0, clamped_vb + h_vis_new - base_h_total))
    end
  end

  Layout.clamp_view(self, layout)
end

function Input.fit_view(self)
  local w, h = self:get_size()
  local layout = Layout.compute(self, w, h)
  local roll = layout.roll
  local notes = self.notes
  local n = #notes

  local end_beat = self.length_beats or 16
  local lo_p, hi_p = 55, 76
  if n > 0 then
    end_beat = 1.0
    lo_p, hi_p = 127, 0
    for i = 1, n do
      local note = notes[i]
      local e = note.start_beat + note.length
      if e > end_beat then end_beat = e end
      if note.pitch < lo_p then lo_p = note.pitch end
      if note.pitch > hi_p then hi_p = note.pitch end
    end
  end

  local span_b = max(4.0, end_beat)
  local span_p = max(6, hi_p - lo_p + 3)

  self._pan_extra_beats = 0.0
  self.px_per_beat  = max(Layout.MIN_PPB, min(Layout.MAX_PPB, (roll.w - 8) / span_b))
  self.px_per_pitch = max(Layout.MIN_PPP, min(Layout.MAX_PPP, roll.h / span_p))
  self.view_beat    = 0.0
  self.view_pitch_top = min(127.0, hi_p + 1.0)
  Layout.clamp_view(self, layout)

  mark_all_dirty(self)
  self:flush_repaint()
end

function Input.reset_default_view(self)
  local w, h = self:get_size()
  local layout = Layout.compute(self, w, h)
  local roll = layout.roll
  local notes = self.notes
  local n = #notes

  self._pan_extra_beats = 0.0
  self.px_per_beat  = Layout.DEF_PPB
  self.px_per_pitch = Layout.DEF_PPP
  self.view_beat    = 0.0

  if n > 0 then
    local lo_p, hi_p = 127, 0
    for i = 1, n do
      local p = notes[i].pitch
      if p < lo_p then lo_p = p end
      if p > hi_p then hi_p = p end
    end
    local mid_p = (lo_p + hi_p) * 0.5
    local vis_p = roll.h / self.px_per_pitch
    self.view_pitch_top = min(127.0, mid_p + vis_p * 0.5)
  else
    self.view_pitch_top = 82.0
  end

  Layout.clamp_view(self, layout)
  self.hud_text = "Default Zoom & Pos"
  mark_all_dirty(self)
  self:save_state()
  self:flush_repaint()
end

-- ============================================================================
-- Edit / History / Clipboard High-Level Actions
-- ============================================================================

local function clear_drag_state(self)
  self.drag_mode = nil
  self.drag_note = nil
  self.drag_snaps = nil
  self._pending_undo_snap = nil
  self._collapse_on_up_id = nil
  self._last_note_group_ids = nil
end

function Input.action_undo(self)
  Playback.release_playback_voices(self)
  if not Model.undo(self) then return false end
  clear_drag_state(self)
  self._ctrl_selected = (Model.count_selected(self) > 1)
  if self.playing then
    Model.rebuild_events(self)
    Playback.emit_active_list(self)
  end
  self.hud_text = "Undo"
  self:outlet(4, "edited", { "undo" })
  self:save_state()
  Layout.clamp_view(self)
  mark_all_dirty(self)
  self:flush_repaint()
  return true
end

function Input.action_redo(self)
  Playback.release_playback_voices(self)
  if not Model.redo(self) then return false end
  clear_drag_state(self)
  self._ctrl_selected = (Model.count_selected(self) > 1)
  if self.playing then
    Model.rebuild_events(self)
    Playback.emit_active_list(self)
  end
  self.hud_text = "Redo"
  self:outlet(4, "edited", { "redo" })
  self:save_state()
  Layout.clamp_view(self)
  mark_all_dirty(self)
  self:flush_repaint()
  return true
end

function Input.action_copy(self)
  local n = Model.copy_selected(self)
  if n == 0 then return 0 end
  self.hud_text = string.format("Copied %d note%s", n, (n > 1) and "s" or "")
  self:outlet(4, "edited", { "copy", n })
  self._dirty_l1 = true
  self._dirty_l3 = true
  self:flush_repaint()
  return n
end

function Input.action_cut(self)
  Playback.release_playback_voices(self)
  local removed = Model.cut_selected(self)
  local n = #removed
  if n == 0 then return 0 end
  for i = 1, n do
    Playback.sync_note_removed(self, removed[i])
  end
  self._ctrl_selected = false
  self._last_note_group_ids = nil
  self.hud_text = string.format("Cut %d note%s", n, (n > 1) and "s" or "")
  self:outlet(4, "edited", { "cut", n })
  self:save_state()
  mark_all_dirty(self)
  self:flush_repaint()
  return n
end

function Input.action_paste(self, target_beat)
  local pasted, pstart = Model.paste_clipboard(self, target_beat)
  local n = #pasted
  if n == 0 then return 0 end
  for i = 1, n do
    Playback.sync_note_modified(self, pasted[i])
  end
  self._ctrl_selected = (n > 1)
  self._last_note_group_ids = nil
  self.hud_text = string.format("Pasted %d @ %.2fb", n, pstart or 0.0)
  self:outlet(4, "edited", { "paste", n })
  self:save_state()
  Layout.clamp_view(self)
  mark_all_dirty(self)
  self:flush_repaint()
  return n
end

function Input.action_duplicate(self)
  local pasted, pstart = Model.duplicate_selected(self)
  local n = #pasted
  if n == 0 then return 0 end
  for i = 1, n do
    Playback.sync_note_modified(self, pasted[i])
  end
  self._ctrl_selected = (n > 1)
  self._last_note_group_ids = nil
  self.hud_text = string.format("Duplicated %d @ %.2fb", n, pstart or 0.0)
  self:outlet(4, "edited", { "duplicate", n })
  self:save_state()
  Layout.clamp_view(self)
  mark_all_dirty(self)
  self:flush_repaint()
  return n
end

-- ============================================================================
-- External Keyname Inlet Handler: [1/0 KEYNAME]
-- ============================================================================

function Input.on_key_list(self, atoms)
  if not atoms or #atoms < 2 then return end
  local pressed, key
  if type(atoms[1]) == "number" then
    pressed = (atoms[1] ~= 0)
    key = tostring(atoms[2])
  elseif type(atoms[2]) == "number" then
    key = tostring(atoms[1])
    pressed = (atoms[2] ~= 0)
  else
    return
  end

  if not self.keys_down then self.keys_down = {} end
  local prev = (self.keys_down[key] == true)
  self.keys_down[key] = pressed and true or nil

  -- Trigger toolbar badge refresh if modifier changed
  if key:find("Control") or key:find("Shift") or key:find("Alt") or key == "Ctrl" then
    if prev ~= pressed then
      self._dirty_l1 = true
      self:flush_repaint()
    end
    return
  end

  -- Discrete key actions on key press edge
  if pressed and not prev then
    local kl        = key:lower()
    local mod_ctrl  = is_ctrl(self)
    local mod_shift = is_shift(self)
    local mod_alt   = is_alt(self)
    local hover_ok  = (self.single_key_hotkeys ~= false) and (self._mouse_inside == true) and (not mod_ctrl) and (not mod_alt)
    local can_cmd   = mod_ctrl or mod_alt or (hover_ok and not mod_shift)

    if key == "Delete" or key == "BackSpace" then
      if Model.count_selected(self) > 0 then
        Model.push_undo(self)
        local removed = Model.remove_selected(self)
        if #removed > 0 then
          for i = 1, #removed do
            Playback.sync_note_removed(self, removed[i])
          end
          self._ctrl_selected = false
          self:outlet(4, "edited", { "delete", #removed })
          self:save_state()
          mark_all_dirty(self)
          self:flush_repaint()
        end
      end
    elseif key == "space" or key == "Space" then
      if self.playing then Playback.pause(self) else Playback.start(self) end
    elseif key == "Escape" then
      Model.clear_selection(self)
      self._ctrl_selected = false
      self.drag_mode = nil
      self.hud_text  = nil
      mark_all_dirty(self)
      self:flush_repaint()
    elseif (kl == "z" and mod_shift and (mod_ctrl or mod_alt or hover_ok))
           or ((kl == "y" or kl == "r") and can_cmd) then
      Input.action_redo(self)
    elseif kl == "z" and can_cmd then
      Input.action_undo(self)
    elseif kl == "c" and can_cmd then
      Input.action_copy(self)
    elseif kl == "x" and can_cmd then
      Input.action_cut(self)
    elseif kl == "v" and can_cmd then
      Input.action_paste(self)
    elseif kl == "d" and can_cmd then
      Input.action_duplicate(self)
    elseif kl == "a" and (mod_ctrl or mod_alt or can_cmd) then
      Model.select_all(self)
      self._ctrl_selected = (#self.notes > 0)
      self._dirty_l1 = true
      self._dirty_l2 = true
      self:flush_repaint()
    end
  end
end

function Input.reset_keys(self)
  self.keys_down = {}
  self._dirty_l1 = true
  self:flush_repaint()
end

-- ============================================================================
-- Toolbar Button Dispatch
-- ============================================================================

local function handle_toolbar_down(self, layout, x, y)
  local btns = layout.btns
  if Layout.in_rect(x, y, btns.play) then
    if self.playing then Playback.pause(self) else Playback.start(self) end
    return true
  elseif Layout.in_rect(x, y, btns.stop) then
    Playback.stop(self)
    return true
  elseif Layout.in_rect(x, y, btns.loop) then
    if self.loop_start == nil or self.loop_end == nil or self.loop_end <= self.loop_start then
      self.loop_start = 0.0
      self.loop_end   = max(1.0, min(self.length_beats or 16, (self.timesig_num or 4) * 1.0))
    end
    self.loop_enabled = not self.loop_enabled
    Playback.emit_loop(self)
    mark_all_dirty(self)
    self:flush_repaint()
    return true
  elseif Layout.in_rect(x, y, btns.bpm_minus) then
    local step = is_shift(self) and 0.1 or 1.0
    Playback.set_bpm(self, (self.bpm or 120) - step)
    self:save_state()
    self._dirty_l1 = true
    self:flush_repaint()
    return true
  elseif Layout.in_rect(x, y, btns.bpm_plus) then
    local step = is_shift(self) and 0.1 or 1.0
    Playback.set_bpm(self, (self.bpm or 120) + step)
    self:save_state()
    self._dirty_l1 = true
    self:flush_repaint()
    return true
  elseif Layout.in_rect(x, y, btns.bpm_val) then
    -- Double-click BPM value resets to 120; single drag adjusts BPM smoothly
    local now = pd.systime()
    if self._last_bpm_click and pd.timesince(self._last_bpm_click) < 340 then
      self._last_bpm_click = nil
      Playback.set_bpm(self, 120.0)
      self:save_state()
      self._dirty_l1 = true
      self:flush_repaint()
      return true
    end
    self._last_bpm_click = now
    self.drag_mode     = "bpm_drag"
    self.drag_start_y  = y
    self.drag_orig_bpm = self.bpm or 120.0
    self.hud_text      = string.format("BPM: %.1f", self.drag_orig_bpm)
    self._dirty_l3 = true
    self:flush_repaint()
    return true
  elseif Layout.in_rect(x, y, btns.grid) then
    local idx = (self.grid_div_idx or 5) % #Model.GRID_DIVS + 1
    self.grid_div_idx = idx
    self:save_state()
    self._dirty_l1 = true
    self:flush_repaint()
    return true
  elseif Layout.in_rect(x, y, btns.snap) then
    self.snap_enabled = not self.snap_enabled
    self:save_state()
    self._dirty_l1 = true
    self:flush_repaint()
    return true
  elseif Layout.in_rect(x, y, btns.snap_mode) then
    self.snap_mode = (self.snap_mode or 1) % #Model.SNAP_MODES + 1
    self:save_state()
    self._dirty_l1 = true
    self:flush_repaint()
    return true
  elseif Layout.in_rect(x, y, btns.len_mode) then
    -- Toggle primary switch between Last Note (1) and Grid Step (2)
    self.default_len_mode = ((self.default_len_mode or 1) == 1) and 2 or 1
    self:save_state()
    self._dirty_l1 = true
    self:flush_repaint()
    return true
  elseif Layout.in_rect(x, y, btns.shift_dup) then
    self.shift_drag_dup = (self.shift_drag_dup == false)
    self.hud_text = "Shift+Drag Copy: " .. (self.shift_drag_dup and "ON" or "OFF")
    self:save_state()
    self._dirty_l1 = true
    self._dirty_l3 = true
    self:flush_repaint()
    return true
  elseif Layout.in_rect(x, y, btns.undo) then
    Input.action_undo(self)
    return true
  elseif Layout.in_rect(x, y, btns.redo) then
    Input.action_redo(self)
    return true
  elseif Layout.in_rect(x, y, btns.cut) then
    Input.action_cut(self)
    return true
  elseif Layout.in_rect(x, y, btns.copy) then
    Input.action_copy(self)
    return true
  elseif Layout.in_rect(x, y, btns.paste) then
    Input.action_paste(self)
    return true
  elseif Layout.in_rect(x, y, btns.fit) then
    Input.fit_view(self)
    return true
  elseif Layout.in_rect(x, y, btns.clr) then
    Playback.release_playback_voices(self)
    if #self.notes > 0 then
      Model.push_undo(self)
    end
    Model.clear_notes(self)
    self._ctrl_selected = false
    if self.playing then Playback.emit_active_list(self) end
    self:outlet(4, "edited", { "clear" })
    self:save_state()
    mark_all_dirty(self)
    self:flush_repaint()
    return true
  elseif Layout.in_rect(x, y, btns.mod_ctrl) then
    -- Fallback sticky toggle / stuck-modifier release
    local kd = self.keys_down
    local on = is_ctrl(self)
    kd["Control_L"] = (not on) and true or nil
    kd["Control_R"] = nil
    self._dirty_l1 = true
    self:flush_repaint()
    return true
  elseif Layout.in_rect(x, y, btns.mod_shift) then
    local kd = self.keys_down
    local on = is_shift(self)
    kd["Shift_L"] = (not on) and true or nil
    kd["Shift_R"] = nil
    self._dirty_l1 = true
    self:flush_repaint()
    return true
  elseif Layout.in_rect(x, y, btns.mod_alt) then
    local kd = self.keys_down
    local on = is_alt(self)
    kd["Alt_L"] = (not on) and true or nil
    kd["Alt_R"] = nil
    self._dirty_l1 = true
    self:flush_repaint()
    return true
  end
  return false
end

-- ============================================================================
-- Mouse Down
-- ============================================================================

function Input.mouse_down(self, x, y)
  self._mouse_inside = true
  local w, h = self:get_size()
  local layout = Layout.compute(self, w, h)

  -- 1. Toolbar
  if Layout.in_rect(x, y, layout.toolbar) then
    handle_toolbar_down(self, layout, x, y)
    return
  end

  -- 2. Bottom-Right V-Zoom grip (hold & drag Up/Down)
  if Layout.in_rect(x, y, layout.vzoom) then
    local now = pd.systime()
    if self._last_vz_click and pd.timesince(self._last_vz_click) < 340 then
      self._last_vz_click = nil
      local center_p = self.view_pitch_top - (layout.roll.h * 0.5) / self.px_per_pitch
      self.px_per_pitch = Layout.DEF_PPP
      self.view_pitch_top = center_p + (layout.roll.h * 0.5) / self.px_per_pitch
      Layout.clamp_view(self, layout)
      mark_all_dirty(self)
      self:flush_repaint()
      return
    end
    self._last_vz_click = now
    self.drag_mode = "vzoom_grip"
    self.drag_start_y = y
    self.drag_orig_ppp = self.px_per_pitch
    self.drag_anchor_pitch_f = self.view_pitch_top - (layout.roll.h * 0.5) / self.px_per_pitch
    self.hud_text = string.format("V-Zoom: %.1f px", self.px_per_pitch)
    self._dirty_l3 = true
    self:flush_repaint()
    return
  end

  -- 3. Top-Right H-Zoom grip (hold & drag Left/Right)
  if Layout.in_rect(x, y, layout.hzoom) then
    local now = pd.systime()
    if self._last_hz_click and pd.timesince(self._last_hz_click) < 340 then
      self._last_hz_click = nil
      local center_b = self.view_beat + (layout.roll.w * 0.5) / self.px_per_beat
      self.px_per_beat = Layout.DEF_PPB
      self.view_beat = max(0.0, center_b - (layout.roll.w * 0.5) / self.px_per_beat)
      Layout.clamp_view(self, layout)
      mark_all_dirty(self)
      self:flush_repaint()
      return
    end
    self._last_hz_click = now
    self.drag_mode = "hzoom_grip"
    self.drag_start_x = x
    self.drag_orig_ppb = self.px_per_beat
    self.drag_orig_pan_extra = self._pan_extra_beats or 0.0
    self.drag_anchor_beat = self.view_beat + (layout.roll.w * 0.5) / self.px_per_beat
    self.hud_text = string.format("H-Zoom: %.0f px/b", self.px_per_beat)
    self._dirty_l3 = true
    self:flush_repaint()
    return
  end

  -- 4. Bottom-Left Reset Default Zoom & Position (swapped cleanly with V-Zoom)
  if Layout.in_rect(x, y, layout.corner_bl) then
    Input.reset_default_view(self)
    return
  end

  -- 5. Bottom Horizontal Scrollbar
  if Layout.in_rect(x, y, layout.hscroll) then
    local hs = layout.hscroll
    local ht = layout.h_thumb
    local travel = max(1, hs.w - ht.w)
    if layout.h_range_beats > 1e-6 and (x < ht.x or x > ht.x + ht.w) then
      local target_thumb_x = max(hs.x, min(hs.x + travel, x - ht.w * 0.5))
      local ratio = (target_thumb_x - hs.x) / travel
      self.view_beat = ratio * layout.h_range_beats
      Layout.clamp_view(self, layout)
    end
    self.drag_mode = "hscroll"
    self.drag_start_x = x
    self.drag_orig_vb = self.view_beat
    self.drag_scroll_max    = layout.h_range_beats
    self.drag_scroll_per_px = (layout.h_range_beats > 1e-6 and travel > 0) and (layout.h_range_beats / travel) or 0.0
    mark_all_dirty(self)
    self:flush_repaint()
    return
  end

  -- 6. Right Vertical Scrollbar
  if Layout.in_rect(x, y, layout.vscroll) then
    local vs = layout.vscroll
    local vt = layout.v_thumb
    local travel = max(1, vs.h - vt.h)
    if layout.v_range_pitches > 1e-6 and (y < vt.y or y > vt.y + vt.h) then
      local target_thumb_y = max(vs.y, min(vs.y + travel, y - vt.h * 0.5))
      local ratio = (target_thumb_y - vs.y) / travel
      self.view_pitch_top = layout.v_max_top - ratio * layout.v_range_pitches
      Layout.clamp_view(self, layout)
    end
    self.drag_mode = "vscroll"
    self.drag_start_y = y
    self.drag_orig_vpt = self.view_pitch_top
    self.drag_scroll_min    = layout.v_min_top
    self.drag_scroll_max    = layout.v_max_top
    self.drag_scroll_per_px = (layout.v_range_pitches > 1e-6 and travel > 0) and (layout.v_range_pitches / travel) or 0.0
    mark_all_dirty(self)
    self:flush_repaint()
    return
  end

  -- 7. Top Progress Ruler (Click = seek, Ctrl+Drag = loop select, Double-click = clear loop)
  if Layout.in_rect(x, y, layout.ruler) then
    local beat = max(0.0, Layout.px_to_beat(self, layout, x))
    if is_ctrl(self) then
      local b_snap = Model.snap_round(self, beat)
      self.drag_mode = "loop_select"
      self.drag_anchor_beat = b_snap
      self.loop_start = b_snap
      self.loop_end   = b_snap + Model.get_grid_step(self)
      self.loop_enabled = true
      Playback.emit_loop(self)
      self.hud_text = string.format("Loop: %.2f - %.2f", self.loop_start, self.loop_end)
      mark_all_dirty(self)
      self:flush_repaint()
      return
    end

    local now = pd.systime()
    if self._last_ruler_click_time
       and pd.timesince(self._last_ruler_click_time) < 350
       and abs(x - (self._last_ruler_click_x or -999)) < 7 then
      -- Double-click on ruler -> remove loop setting
      self._last_ruler_click_time = nil
      self.loop_enabled = false
      self.loop_start = nil
      self.loop_end   = nil
      Playback.emit_loop(self)
      self.drag_mode = nil
      self.hud_text  = "Loop Cleared"
      mark_all_dirty(self)
      self:flush_repaint()
      return
    end

    self._last_ruler_click_time = now
    self._last_ruler_click_x    = x
    self.drag_mode = "scrub"
    self.drag_start_x = x
    local seek_b = is_shift(self) and beat or Model.snap_round(self, beat)
    Playback.seek_beat(self, seek_b)
    self.hud_text = string.format("Pos: %s (%.2fb)", Model.format_beat_pos(self, seek_b), seek_b)
    self._dirty_l3 = true
    self:flush_repaint()
    return
  end

  -- 8. Left Piano Keyboard (Click & glissando audition)
  if Layout.in_rect(x, y, layout.keyboard) then
    local pitch = Layout.py_to_pitch(self, layout, y)
    self.drag_mode = "keyboard"
    Playback.start_audition(self, pitch, self.default_vel)
    self.hud_text = string.format("%s (%d)", Model.pitch_name(pitch), pitch)
    self._dirty_l2 = true
    self._dirty_l3 = true
    self:flush_repaint()
    return
  end

  -- 9. Main Piano Roll Canvas
  if not Layout.in_rect(x, y, layout.roll) then return end

  local ctrl  = is_ctrl(self)
  local shift = is_shift(self)
  local alt   = is_alt(self)

  -- Alt + drag anywhere in roll: Free 2D view pan
  if alt then
    self.drag_mode = "pan"
    self.drag_start_x = x
    self.drag_start_y = y
    self.drag_orig_vb  = self.view_beat
    self.drag_orig_vpt = self.view_pitch_top
    self.hud_text = string.format("Pan: %.2fb", self.view_beat)
    self._dirty_l3 = true
    self:flush_repaint()
    return
  end

  local hit, is_tail = Model.hit_test_px(self, layout, x, y)
  local beat  = max(0.0, Layout.px_to_beat(self, layout, x))
  local pitch = Layout.py_to_pitch(self, layout, y)

  if hit then
    -- Remember length of clicked note for "Last Note" length mode
    self.last_note_len = hit.length

    -- Ctrl + click existing note -> toggle selection
    if ctrl then
      Model.toggle_select(self, hit.id)
      self._ctrl_selected        = (Model.count_selected(self) >= 1)
      self._last_note_click_time = nil
      self._last_note_group_ids  = nil
      self._dirty_l1 = true
      self._dirty_l2 = true
      self:flush_repaint()
      return
    end

    -- Shift + click/drag existing note:
    --   * When shift_drag_dup ON & on note body: Shift+Drag duplicates (FL-style); Shift+Click adds to selection
    --   * When shift_drag_dup OFF or on tail: Shift+Click adds to selection
    if shift then
      if self.shift_drag_dup ~= false and not is_tail then
        local prev_sel = {}
        if self.selected_ids then
          for k, v in pairs(self.selected_ids) do prev_sel[k] = v end
        end
        local hit_was_sel = Model.is_selected(self, hit.id)
        local targets = hit_was_sel and Model.get_selected_notes(self) or { hit }
        local snaps = {}
        for i = 1, #targets do
          local sn = targets[i]
          snaps[i] = {
            note       = sn,
            start_beat = sn.start_beat,
            pitch      = sn.pitch,
            length     = sn.length,
          }
        end
        self._shift_dup_armed   = true
        self._shift_dup_done    = false
        self._shift_prev_sel    = prev_sel
        self._shift_hit_was_sel = hit_was_sel
        self._collapse_on_up_id = nil
        self._pending_undo_snap = Model.capture_snapshot(self)
        self.drag_mode          = "move"
        self.drag_is_dup        = false
        self.drag_note          = hit
        self.drag_snaps         = snaps
        self.drag_start_x       = x
        self.drag_start_y       = y
        self.drag_mouse_beat    = beat
        self.drag_mouse_pitch   = pitch
        self.drag_orig_start    = hit.start_beat
        self.drag_orig_pitch    = hit.pitch
        self.drag_orig_len      = hit.length
        self.drag_moved         = false
        if self.preview_on_edit ~= false then
          Playback.start_audition(self, hit.pitch, hit.velocity)
        end
        self.hud_text = string.format("Shift+Drag: Duplicate (%d)", #snaps)
        self._dirty_l3 = true
        self:flush_repaint()
        return
      end

      if not self.selected_ids then self.selected_ids = {} end
      self.selected_ids[hit.id] = true
      self.primary_sel_id = hit.id
      self._ctrl_selected        = (Model.count_selected(self) > 1)
      self._last_note_group_ids = nil
      self._dirty_l1 = true
      self._dirty_l2 = true
      self:flush_repaint()
      return
    end

    -- Double-click existing note -> delete note, OR delete ALL selected notes if part of multi-selection!
    local now = pd.systime()
    if self._last_note_click_time
       and self._last_note_click_id == hit.id
       and pd.timesince(self._last_note_click_time) < 350
       and abs(x - (self._last_note_click_x or -999)) < 7
       and abs(y - (self._last_note_click_y or -999)) < 7 then
      self._last_note_click_time = nil
      self._last_note_click_id   = nil
      if self._last_note_group_ids and self._last_note_group_ids[hit.id] then
        self.selected_ids = self._last_note_group_ids
      end
      self._last_note_group_ids = nil

      Model.push_undo(self)
      if Model.is_selected(self, hit.id) and Model.count_selected(self) > 1 then
        local removed = Model.remove_selected(self)
        for i = 1, #removed do
          Playback.sync_note_removed(self, removed[i])
        end
        self:outlet(4, "edited", { "delete", #removed })
      else
        Playback.sync_note_removed(self, hit)
        Model.remove_note(self, hit)
        self:outlet(4, "edited", { "delete", hit.pitch, hit.start_beat })
      end
      self.drag_mode = nil
      self.hud_text  = nil
      self:save_state()
      mark_all_dirty(self)
      self:flush_repaint()
      return
    end

    self._last_note_click_time = now
    self._last_note_click_id   = hit.id
    self._last_note_click_x    = x
    self._last_note_click_y    = y
    self._last_note_group_ids  = nil

    -- Selection logic: if clicking an unselected note, select only it;
    -- if already part of multi-selection, preserve group for group drag
    self._collapse_on_up_id = nil
    if not Model.is_selected(self, hit.id) then
      Model.select_only(self, hit.id)
      self._ctrl_selected = false
    else
      if Model.count_selected(self) > 1 then
        self._collapse_on_up_id = hit.id
      end
      self.primary_sel_id = hit.id
    end

    local sel_notes = Model.get_selected_notes(self)
    local snaps = {}
    for i = 1, #sel_notes do
      local sn = sel_notes[i]
      snaps[i] = {
        note       = sn,
        start_beat = sn.start_beat,
        pitch      = sn.pitch,
        length     = sn.length,
      }
    end

    self._pending_undo_snap = Model.capture_snapshot(self)
    self.drag_mode          = is_tail and "resize" or "move"
    self.drag_is_dup        = false
    self.drag_note         = hit
    self.drag_snaps        = snaps
    self.drag_start_x      = x
    self.drag_start_y      = y
    self.drag_mouse_beat   = beat
    self.drag_mouse_pitch  = pitch
    self.drag_orig_start   = hit.start_beat
    self.drag_orig_pitch   = hit.pitch
    self.drag_orig_len     = hit.length
    self.drag_moved        = false

    if self.preview_on_edit ~= false then
      Playback.start_audition(self, hit.pitch, hit.velocity)
    end
    self.hud_text = string.format("%s (%d)  %.2fb  Len %.2f", Model.pitch_name(hit.pitch), hit.pitch, hit.start_beat, hit.length)
    self._dirty_l1 = true
    self._dirty_l2 = true
    self._dirty_l3 = true
    self:flush_repaint()
    return
  end

  -- Blank area inside roll!
  -- Ctrl + drag blank area -> Marquee box selection
  if ctrl then
    self._last_note_click_time = nil
    Model.clear_selection(self)
    self._ctrl_selected = false
    self.drag_mode    = "marquee"
    self.drag_start_x = x
    self.drag_start_y = y
    self.marquee_x0   = x
    self.marquee_y0   = y
    self.marquee_x1   = x
    self.marquee_y1   = y
    self.hud_text     = "Select Box"
    self._dirty_l1 = true
    self._dirty_l2 = true
    self._dirty_l3 = true
    self:flush_repaint()
    return
  end

  -- Shift + drag blank area -> Vertical (up/down) or Horizontal (left/right) Zoom
  if shift then
    self._last_note_click_time = nil
    self._last_note_group_ids  = nil
    self.drag_mode = "shift_zoom"
    self.drag_axis = nil
    self.drag_start_x = x
    self.drag_start_y = y
    self.drag_orig_ppb = self.px_per_beat
    self.drag_orig_ppp = self.px_per_pitch
    self.drag_orig_pan_extra = self._pan_extra_beats or 0.0
    self.drag_anchor_beat    = Layout.px_to_beat(self, layout, x)
    self.drag_anchor_pitch_f = Layout.py_to_pitch_float(self, layout, y)
    self.drag_anchor_rel_x   = x - layout.roll.x
    self.drag_anchor_rel_y   = y - layout.roll.y
    self.hud_text = "Drag U/D: V-Zoom | L/R: H-Zoom"
    self._dirty_l3 = true
    self:flush_repaint()
    return
  end

  -- Clicking blank area after Ctrl / multi-selection cancels selection without creating a note
  if Model.count_selected(self) > 1 or (Model.count_selected(self) >= 1 and self._ctrl_selected) then
    Model.clear_selection(self)
    self._ctrl_selected        = false
    self._last_note_click_time = nil
    self._last_note_click_id   = nil
    self._last_note_group_ids  = nil
    self.drag_mode             = nil
    self.drag_note             = nil
    self.hud_text              = nil
    self._dirty_l1 = true
    self._dirty_l2 = true
    self._dirty_l3 = true
    self:flush_repaint()
    return
  end

  -- Single click on blank area -> Create new note snapped to nearest grid line
  self._last_note_click_time = nil
  self._last_note_click_id   = nil
  self._last_note_group_ids  = nil
  self._ctrl_selected        = false
  local pre_snap = Model.capture_snapshot(self)
  local sb  = Model.snap_round(self, beat)
  local len = Model.get_default_note_length(self)
  local note = Model.add_note(self, pitch, sb, len, self.default_vel)
  Model.push_undo(self, pre_snap)
  self.last_note_len = note.length
  Model.select_only(self, note.id)

  self.drag_mode        = "create"
  self.drag_note        = note
  self.drag_start_x     = x
  self.drag_start_y     = y
  self.drag_orig_start  = note.start_beat
  self.drag_orig_pitch  = note.pitch
  self.drag_orig_len    = note.length
  self.drag_mouse_beat  = beat
  self.drag_mouse_pitch = pitch
  self.drag_moved       = false

  if self.preview_on_edit ~= false then
    Playback.start_audition(self, note.pitch, note.velocity)
  end
  self:outlet(4, "edited", { "add", note.pitch, note.start_beat, note.length, note.velocity })
  self.hud_text = string.format("%s (%d)  %.2fb  Len %.2f", Model.pitch_name(note.pitch), note.pitch, note.start_beat, note.length)
  self._dirty_l1 = true
  self._dirty_l2 = true
  self._dirty_l3 = true
  self:flush_repaint()
end

-- ============================================================================
-- Mouse Drag
-- ============================================================================

function Input.mouse_drag(self, x, y)
  local mode = self.drag_mode
  if not mode then return end

  local w, h = self:get_size()
  local layout = Layout.compute(self, w, h)

  if abs(x - (self.drag_start_x or x)) >= 4 or abs(y - (self.drag_start_y or y)) >= 4 then
    self.drag_moved = true
    self._collapse_on_up_id = nil
  end

  if mode == "bpm_drag" then
    local dy = self.drag_start_y - y
    local scale = is_shift(self) and 0.1 or 0.5
    Playback.set_bpm(self, self.drag_orig_bpm + dy * scale)
    self.hud_text = string.format("BPM: %.1f", self.bpm)
    self._dirty_l1 = true
    self._dirty_l3 = true
    self:flush_repaint()
    return
  end

  if mode == "vzoom_grip" then
    local dy = y - self.drag_start_y
    local factor = exp(-dy * 0.012)
    local new_ppp = max(Layout.MIN_PPP, min(Layout.MAX_PPP, self.drag_orig_ppp * factor))
    self.px_per_pitch = new_ppp
    self.view_pitch_top = self.drag_anchor_pitch_f + (layout.roll.h * 0.5) / new_ppp
    Layout.clamp_view(self, layout)
    self.hud_text = string.format("V-Zoom: %.1f px", self.px_per_pitch)
    mark_all_dirty(self)
    self:flush_repaint()
    return
  end

  if mode == "hzoom_grip" then
    local dx = x - self.drag_start_x
    local factor = exp(dx * 0.010)
    local new_ppb = max(Layout.MIN_PPB, min(Layout.MAX_PPB, self.drag_orig_ppb * factor))
    apply_hzoom(self, layout, new_ppb, self.drag_orig_ppb, self.drag_orig_pan_extra or 0.0, self.drag_anchor_beat, layout.roll.w * 0.5)
    self.hud_text = string.format("H-Zoom: %.0f px/b", self.px_per_beat)
    mark_all_dirty(self)
    self:flush_repaint()
    return
  end

  if mode == "shift_zoom" then
    local dx = x - self.drag_start_x
    local dy = y - self.drag_start_y
    if not self.drag_axis then
      if abs(dx) >= 4 or abs(dy) >= 4 then
        self.drag_axis = (abs(dy) >= abs(dx)) and "v" or "h"
      else
        return
      end
    end
    if self.drag_axis == "v" then
      local factor = exp(-dy * 0.012)
      local new_ppp = max(Layout.MIN_PPP, min(Layout.MAX_PPP, self.drag_orig_ppp * factor))
      self.px_per_pitch = new_ppp
      self.view_pitch_top = self.drag_anchor_pitch_f + self.drag_anchor_rel_y / new_ppp
      Layout.clamp_view(self, layout)
      self.hud_text = string.format("V-Zoom: %.1f px", self.px_per_pitch)
    else
      local factor = exp(dx * 0.010)
      local new_ppb = max(Layout.MIN_PPB, min(Layout.MAX_PPB, self.drag_orig_ppb * factor))
      apply_hzoom(self, layout, new_ppb, self.drag_orig_ppb, self.drag_orig_pan_extra or 0.0, self.drag_anchor_beat, self.drag_anchor_rel_x)
      self.hud_text = string.format("H-Zoom: %.0f px/b", self.px_per_beat)
    end
    mark_all_dirty(self)
    self:flush_repaint()
    return
  end

  if mode == "pan" then
    local dx = x - self.drag_start_x
    local dy = y - self.drag_start_y
    local base_h_total = max(self.length_beats or 16, self.max_end_beat or 0, 4.0)
    local h_vis = layout.roll.w / self.px_per_beat
    local new_vb = max(0.0, self.drag_orig_vb - dx / self.px_per_beat)
    local needed_extra = max(0.0, new_vb + h_vis - base_h_total)
    self._pan_extra_beats = (new_vb > 1e-4) and needed_extra or 0.0
    self.view_beat      = new_vb
    self.view_pitch_top = self.drag_orig_vpt + dy / self.px_per_pitch
    Layout.clamp_view(self, layout)
    self.hud_text = string.format("View: %.1fb | %s", self.view_beat, Model.pitch_name(floor(self.view_pitch_top)))
    mark_all_dirty(self)
    self:flush_repaint()
    return
  end

  if mode == "hscroll" then
    local per_px = self.drag_scroll_per_px or 0.0
    if per_px <= 0.0 then return end
    local prev_vb = self.view_beat
    local new_vb = max(0.0, min(self.drag_scroll_max or 0.0, self.drag_orig_vb + (x - self.drag_start_x) * per_px))
    if abs(new_vb - prev_vb) < 1e-6 then return end
    self.view_beat = new_vb
    Layout.clamp_view(self, layout)
    mark_all_dirty(self)
    self:flush_repaint()
    return
  end

  if mode == "vscroll" then
    local per_px = self.drag_scroll_per_px or 0.0
    if per_px <= 0.0 then return end
    local prev_vpt = self.view_pitch_top
    local new_vpt = max(self.drag_scroll_min or 0.0, min(self.drag_scroll_max or 127.0, self.drag_orig_vpt - (y - self.drag_start_y) * per_px))
    if abs(new_vpt - prev_vpt) < 1e-6 then return end
    self.view_pitch_top = new_vpt
    Layout.clamp_view(self, layout)
    mark_all_dirty(self)
    self:flush_repaint()
    return
  end

  if mode == "loop_select" then
    local beat = max(0.0, Layout.px_to_beat(self, layout, x))
    local b_cur = Model.snap_round(self, beat)
    local b0 = self.drag_anchor_beat
    local ls = min(b0, b_cur)
    local le = max(b0, b_cur)
    if le <= ls then le = ls + Model.get_grid_step(self) end
    self.loop_start = ls
    self.loop_end   = le
    self.loop_enabled = true
    Playback.emit_loop(self)
    self.hud_text = string.format("Loop: %.2f - %.2f", ls, le)
    self._dirty_l2 = true
    self._dirty_l3 = true
    self:flush_repaint()
    return
  end

  if mode == "scrub" then
    if abs(x - (self.drag_start_x or x)) >= 4 then
      self._last_ruler_click_time = nil
    end
    local beat = max(0.0, Layout.px_to_beat(self, layout, x))
    local seek_b = is_shift(self) and beat or Model.snap_round(self, beat)
    Playback.seek_beat(self, seek_b)
    self.hud_text = string.format("Pos: %s (%.2fb)", Model.format_beat_pos(self, seek_b), seek_b)
    return
  end

  if mode == "keyboard" then
    local pitch = Layout.py_to_pitch(self, layout, y)
    Playback.start_audition(self, pitch, self.default_vel)
    self.hud_text = string.format("%s (%d)", Model.pitch_name(pitch), pitch)
    self._dirty_l2 = true
    self._dirty_l3 = true
    self:flush_repaint()
    return
  end

  if mode == "marquee" then
    self.marquee_x1 = x
    self.marquee_y1 = y
    local x_lo = min(self.marquee_x0, x)
    local x_hi = max(self.marquee_x0, x)
    local y_lo = min(self.marquee_y0, y)
    local y_hi = max(self.marquee_y0, y)
    local b_min = max(0.0, Layout.px_to_beat(self, layout, x_lo))
    local b_max = max(0.0, Layout.px_to_beat(self, layout, x_hi))
    local p_max = Layout.py_to_pitch(self, layout, y_lo)
    local p_min = Layout.py_to_pitch(self, layout, y_hi)
    if p_min > p_max then p_min, p_max = p_max, p_min end
    Model.select_in_box(self, b_min, b_max, p_min, p_max, false)
    local cnt = Model.count_selected(self)
    self._ctrl_selected = (cnt >= 1)
    self.hud_text = string.format("Selected: %d", cnt)
    self._dirty_l1 = true
    self._dirty_l2 = true
    self._dirty_l3 = true
    self:flush_repaint()
    return
  end

  -- Note Editing Modes: move / resize / create
  local note = self.drag_note
  if not note then return end

  local beat  = max(0.0, Layout.px_to_beat(self, layout, x))
  local pitch = Layout.py_to_pitch(self, layout, y)

  if mode == "move" then
    if self.drag_moved then
      self._last_note_click_time = nil
    end
    local just_cloned = false
    if self._shift_dup_armed and not self._shift_dup_done then
      if not (self.drag_moved or abs(x - (self.drag_start_x or x)) >= 3 or abs(y - (self.drag_start_y or y)) >= 3) then
        return
      end
      self._shift_dup_done = true
      self.drag_is_dup = true
      local orig_snaps = self.drag_snaps or { { note = note, start_beat = self.drag_orig_start, pitch = self.drag_orig_pitch, length = self.drag_orig_len } }
      local new_snaps = {}
      local new_sel = {}
      local new_primary = nil
      for i = 1, #orig_snaps do
        local s = orig_snaps[i]
        local orig_n = s.note
        local cloned = Model.add_note(self, s.pitch, s.start_beat, s.length, orig_n and orig_n.velocity or self.default_vel)
        new_sel[cloned.id] = true
        new_snaps[i] = {
          note       = cloned,
          start_beat = s.start_beat,
          pitch      = s.pitch,
          length     = s.length,
        }
        if orig_n and orig_n.id == note.id then
          new_primary = cloned
        end
      end
      self.selected_ids = new_sel
      if new_primary then
        note = new_primary
        self.drag_note = new_primary
        self.primary_sel_id = new_primary.id
      end
      self.drag_snaps = new_snaps
      self._ctrl_selected = (#new_snaps > 1)
      just_cloned = true
    end

    local snaps = self.drag_snaps or { { note = note, start_beat = self.drag_orig_start, pitch = self.drag_orig_pitch, length = self.drag_orig_len } }
    local raw_db = beat - self.drag_mouse_beat
    local db
    if (self.snap_mode or 1) == 2 then
      -- Relative snap: preserve initial micro-timing offset
      db = Model.snap_delta(self, raw_db)
    else
      local target_start = Model.snap_round(self, self.drag_orig_start + raw_db)
      db = target_start - self.drag_orig_start
    end
    local dp = pitch - self.drag_mouse_pitch

    -- Clamp group bounds so no selected note goes out of [0, +inf) x [0, 127]
    for i = 1, #snaps do
      local s = snaps[i]
      if s.start_beat + db < 0 then db = -s.start_beat end
      if s.pitch + dp < 0 then dp = -s.pitch end
      if s.pitch + dp > 127 then dp = 127 - s.pitch end
    end

    local changed = false
    local old_pitch = note.pitch
    for i = 1, #snaps do
      local s = snaps[i]
      local sn = s.note
      local nb = max(0.0, s.start_beat + db)
      local np = max(0, min(127, s.pitch + dp))
      if sn.start_beat ~= nb or sn.pitch ~= np then
        sn.start_beat = nb
        sn.pitch      = np
        changed = true
      end
    end

    if changed or just_cloned then
      self.last_note_len = note.length
      Model.recompute_max_end(self)
      Playback.sync_note_modified(self, note)
      if changed and note.pitch ~= old_pitch and self.preview_on_edit ~= false then
        Playback.start_audition(self, note.pitch, note.velocity)
      end
      local prefix = self.drag_is_dup and "DUP " or ""
      self.hud_text = string.format("%s%s (%d)  %.2fb", prefix, Model.pitch_name(note.pitch), note.pitch, note.start_beat)
      if just_cloned then self._dirty_l1 = true end
      self._dirty_l2 = true
      self._dirty_l3 = true
      self:flush_repaint()
    end

  elseif mode == "resize" then
    if self.drag_moved then
      self._last_note_click_time = nil
    end
    local snaps = self.drag_snaps or { { note = note, start_beat = self.drag_orig_start, pitch = self.drag_orig_pitch, length = self.drag_orig_len } }
    local min_len = self.snap_enabled and Model.get_grid_step(self) or 0.0625
    local end_beat = Model.snap_round(self, beat)
    local target_len = max(min_len, end_beat - self.drag_orig_start)
    local d_len = target_len - self.drag_orig_len

    local changed = false
    for i = 1, #snaps do
      local s = snaps[i]
      local nl = max(min_len, s.length + d_len)
      if s.note.length ~= nl then
        s.note.length = nl
        changed = true
      end
    end
    if changed then
      self.last_note_len = note.length
      Model.recompute_max_end(self)
      Playback.sync_note_modified(self, note)
      self.hud_text = string.format("%s (%d)  Len %.2f", Model.pitch_name(note.pitch), note.pitch, note.length)
      self._dirty_l2 = true
      self._dirty_l3 = true
      self:flush_repaint()
    end

  elseif mode == "create" then
    if (self.default_len_mode or 1) == 2 then
      -- GRD mode: dragging while creating adjusts note length
      if abs(x - self.drag_start_x) >= 3 then
        local min_len = self.snap_enabled and Model.get_grid_step(self) or 0.0625
        local end_beat = Model.snap_round(self, beat)
        local new_len = max(min_len, end_beat - note.start_beat)
        if new_len ~= note.length then
          note.length = new_len
          self.last_note_len = new_len
          Model.recompute_max_end(self)
          Playback.sync_note_modified(self, note)
          self.hud_text = string.format("%s (%d)  %.2fb  Len %.2f", Model.pitch_name(note.pitch), note.pitch, note.start_beat, note.length)
          self._dirty_l2 = true
          self._dirty_l3 = true
          self:flush_repaint()
        end
      end
    else
      -- LST mode (default) / preset length modes: dragging while creating moves note position cleanly
      local raw_db = beat - self.drag_mouse_beat
      local db
      if (self.snap_mode or 1) == 2 then
        db = Model.snap_delta(self, raw_db)
      else
        local target_start = Model.snap_round(self, self.drag_orig_start + raw_db)
        db = target_start - self.drag_orig_start
      end
      local dp = pitch - self.drag_mouse_pitch
      local nb = max(0.0, self.drag_orig_start + db)
      local np = max(0, min(127, self.drag_orig_pitch + dp))
      if nb ~= note.start_beat or np ~= note.pitch then
        local old_pitch = note.pitch
        note.start_beat = nb
        note.pitch      = np
        Model.recompute_max_end(self)
        Playback.sync_note_modified(self, note)
        if np ~= old_pitch and self.preview_on_edit ~= false then
          Playback.start_audition(self, note.pitch, note.velocity)
        end
        self.hud_text = string.format("%s (%d)  %.2fb  Len %.2f", Model.pitch_name(note.pitch), note.pitch, note.start_beat, note.length)
        self._dirty_l2 = true
        self._dirty_l3 = true
        self:flush_repaint()
      end
    end
  end
end

-- ============================================================================
-- Mouse Up
-- ============================================================================

function Input.mouse_up(self, x, y)
  local mode = self.drag_mode

  if self.audition_pitch ~= nil then
    Playback.stop_audition(self)
  end

  if mode == "bpm_drag" then
    self:save_state()
  elseif mode == "move" or mode == "resize" or mode == "create" then
    if self.drag_note then
      self.last_note_len = self.drag_note.length
    end
    if self._collapse_on_up_id and not self.drag_moved then
      local snap_group = {}
      if self.selected_ids then
        for k, v in pairs(self.selected_ids) do snap_group[k] = v end
      end
      self._last_note_group_ids = snap_group
      Model.select_only(self, self._collapse_on_up_id)
      self._ctrl_selected = false
    end
    self.events_dirty = true
    if self.playing then Model.rebuild_events(self) end
    if mode == "move" and self._shift_dup_armed then
      if not self._shift_dup_done then
        -- Released without dragging >= 3px -> fallback to Shift+Click add-to-selection
        if self.drag_note then
          self.selected_ids = self._shift_prev_sel or {}
          self.selected_ids[self.drag_note.id] = true
          self.primary_sel_id = self.drag_note.id
          self._ctrl_selected = (Model.count_selected(self) > 1)
        end
        self._pending_undo_snap = nil
      else
        if self._pending_undo_snap then
          Model.push_undo(self, self._pending_undo_snap)
          self._pending_undo_snap = nil
        end
        self:outlet(4, "edited", { "duplicate", self.drag_snaps and #self.drag_snaps or 1 })
        self:save_state()
      end
    elseif mode == "move" or mode == "resize" then
      if self._pending_undo_snap then
        if not Model.snapshots_equal(self._pending_undo_snap, Model.capture_snapshot(self)) then
          Model.push_undo(self, self._pending_undo_snap)
        end
        self._pending_undo_snap = nil
      end
      self:outlet(4, "edited", { mode })
      self:save_state()
    elseif mode == "create" then
      self:save_state()
    end
  end

  self._pending_undo_snap  = nil
  self._collapse_on_up_id  = nil
  self._shift_dup_armed    = nil
  self._shift_dup_done     = nil
  self._shift_prev_sel     = nil
  self._shift_hit_was_sel  = nil
  self.drag_is_dup         = nil
  self.drag_orig_pan_extra = nil
  self.drag_scroll_per_px  = nil
  self.drag_scroll_min     = nil
  self.drag_scroll_max     = nil
  self.drag_mode   = nil
  self.drag_note   = nil
  self.drag_snaps  = nil
  self.drag_axis   = nil
  self.hud_text    = nil
  self.marquee_x0  = nil
  self.marquee_y0  = nil
  self.marquee_x1  = nil
  self.marquee_y1  = nil

  self._dirty_l1 = true
  self._dirty_l2 = true
  self._dirty_l3 = true
  self:flush_repaint()

  local _ = x
  local __ = y
end

-- ============================================================================
-- Hover Feedback (mouse_enter / mouse_move / mouse_exit)
-- ============================================================================

function Input.mouse_enter(self, x, y)
  self._mouse_inside = true
  Input.mouse_move(self, x, y)
end

function Input.mouse_move(self, x, y)
  self._mouse_inside = true
  self.hover_x = x
  self.hover_y = y
  if self.drag_mode then return end

  local w, h = self:get_size()
  local layout = Layout.compute(self, w, h)

  local new_region, new_btn, new_pitch, new_note_id, new_tail = nil, nil, nil, nil, false

  if Layout.in_rect(x, y, layout.toolbar) then
    for name, r in pairs(layout.btns) do
      if name ~= "info_area" and name ~= "bpm" then
        if Layout.in_rect(x, y, r) then
          new_region = "btn"
          new_btn = name
          break
        end
      end
    end
  elseif Layout.in_rect(x, y, layout.hzoom) then
    new_region = "hzoom"
  elseif Layout.in_rect(x, y, layout.vzoom) then
    new_region = "vzoom"
  elseif Layout.in_rect(x, y, layout.corner_bl) then
    new_region = "corner_bl"
  elseif Layout.in_rect(x, y, layout.keyboard) then
    new_region = "keyboard"
    new_pitch  = Layout.py_to_pitch(self, layout, y)
  elseif Layout.in_rect(x, y, layout.roll) then
    local hit, is_tail = Model.hit_test_px(self, layout, x, y)
    if hit then
      new_region  = "note"
      new_note_id = hit.id
      new_tail    = is_tail
    end
  end

  if new_region ~= self.hover_region
     or new_btn ~= self.hover_btn
     or new_pitch ~= self.hover_pitch
     or new_note_id ~= self.hover_note_id
     or new_tail ~= self.hover_note_tail then
    self.hover_region    = new_region
    self.hover_btn       = new_btn
    self.hover_pitch     = new_pitch
    self.hover_note_id   = new_note_id
    self.hover_note_tail = new_tail
    self._dirty_l3 = true
    self:flush_repaint()
  end
end

function Input.mouse_exit(self, x, y)
  self._mouse_inside = false
  if self.hover_region or self.hover_note_id or self.hover_pitch or self.hover_btn then
    self.hover_region    = nil
    self.hover_btn       = nil
    self.hover_pitch     = nil
    self.hover_note_id   = nil
    self.hover_note_tail = false
    self._dirty_l3 = true
    self:flush_repaint()
  end
  local _ = x
  local __ = y
end

return Input
