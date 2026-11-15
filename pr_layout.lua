-- ============================================================================
-- pr_layout.lua — Stateless Layout & Coordinate Engine for Piano Roll
-- Guarantees resize invariance: resizing the object ONLY changes the piano roll
-- viewport extent while preserving fixed-pixel chrome & note zoom scales.
-- ============================================================================

local Layout = {}

Layout.DEF_W   = 720
Layout.DEF_H   = 380
Layout.MIN_PPB = 4.0
Layout.MAX_PPB = 480.0
Layout.DEF_PPB = 72.0
Layout.MIN_PPP = 5.0
Layout.MAX_PPP = 36.0
Layout.DEF_PPP = 13.0

local floor = math.floor
local ceil  = math.ceil
local max   = math.max
local min   = math.min

function Layout.in_rect(x, y, r)
  return r and r.w > 0 and r.h > 0
     and x >= r.x and x < (r.x + r.w)
     and y >= r.y and y < (r.y + r.h)
end

function Layout.get_h_total(self)
  local base = max(self.length_beats or 16, self.max_end_beat or 0, 4.0)
  return base + max(0.0, self._pan_extra_beats or 0.0)
end

function Layout.compute(self, w, h)
  if not w or not h then
    w, h = self:get_size()
  end
  w = max(120, floor(w))
  h = max(100, floor(h))

  -- Fixed-pixel chrome dimensions (never scaled proportionally with w/h)
  local tb_h = (self.show_toolbar ~= false) and (self.toolbar_h or 28) or 0
  local rl_h = (self.show_ruler ~= false) and (self.ruler_h or 20) or 0
  local kb_w = (self.show_keyboard ~= false) and (self.key_w or 48) or 0
  local vs_w = (self.show_scrollbars ~= false) and (self.scroll_size or 16) or 0
  local hs_h = (self.show_scrollbars ~= false) and (self.scroll_size or 16) or 0

  -- Emergency floor so roll viewport never collapses below 40x40 on extreme shrink
  local min_roll_w, min_roll_h = 40, 40
  if w - kb_w - vs_w < min_roll_w then
    local avail = max(0, w - min_roll_w)
    if kb_w + vs_w > 0 then
      local ratio = avail / (kb_w + vs_w)
      kb_w = floor(kb_w * ratio)
      vs_w = avail - kb_w
    end
  end
  if h - tb_h - rl_h - hs_h < min_roll_h then
    local avail = max(0, h - min_roll_h)
    local sum_h = tb_h + rl_h + hs_h
    if sum_h > 0 then
      local ratio = avail / sum_h
      tb_h = floor(tb_h * ratio)
      rl_h = floor(rl_h * ratio)
      hs_h = avail - tb_h - rl_h
    end
  end

  local roll_x = kb_w
  local roll_y = tb_h + rl_h
  local roll_w = max(1, w - kb_w - vs_w)
  local roll_h = max(1, h - tb_h - rl_h - hs_h)

  local toolbar   = { x = 0, y = 0, w = w, h = tb_h }
  local corner_tl = { x = 0, y = tb_h, w = kb_w, h = rl_h }
  local ruler     = { x = roll_x, y = tb_h, w = roll_w, h = rl_h }
  local keyboard  = { x = 0, y = roll_y, w = kb_w, h = roll_h }
  local roll      = { x = roll_x, y = roll_y, w = roll_w, h = roll_h }

  -- Right rail: H-Zoom grip at top (drag L/R for horizontal zoom), V-Scrollbar below
  local hz_h = (vs_w > 0) and max(18, rl_h) or 0
  if hz_h > h - tb_h - hs_h - 24 then
    hz_h = max(0, h - tb_h - hs_h - 24)
  end
  local hzoom   = { x = roll_x + roll_w, y = tb_h, w = vs_w, h = hz_h }
  local vscroll = {
    x = roll_x + roll_w,
    y = tb_h + hz_h,
    w = vs_w,
    h = max(0, (h - hs_h) - (tb_h + hz_h)),
  }

  -- Bottom rail: Reset/Fit control at bottom-left, H-Scrollbar in middle, V-Zoom grip (↕) at bottom-right
  local bl_w = (hs_h > 0) and max(36, kb_w) or 0
  if bl_w > w - vs_w - 40 then
    bl_w = max(0, w - vs_w - 40)
  end
  local corner_bl = { x = 0, y = h - hs_h, w = bl_w, h = hs_h }
  local hscroll   = { x = bl_w, y = h - hs_h, w = max(0, (w - vs_w) - bl_w), h = hs_h }
  local vzoom     = { x = roll_x + roll_w, y = h - hs_h, w = vs_w, h = hs_h }

  -- Toolbar button rectangles (fixed pixel sizes)
  local btns = {}
  if tb_h >= 14 then
    local by = 4
    local bh = max(10, tb_h - 8)
    local cx = 6
    local function add_btn(name, bw)
      if cx + bw <= w - 4 then
        btns[name] = { x = cx, y = by, w = bw, h = bh }
        cx = cx + bw + 3
        return true
      end
      return false
    end

    add_btn("play", 22)
    add_btn("stop", 20)
    add_btn("loop", 22)
    add_btn("follow", 22)
    add_btn("ret_start", 22)
    cx = cx + 2
    if add_btn("bpm", 62) then
      local r = btns.bpm
      local mw = 13
      btns.bpm_minus = { x = r.x, y = r.y, w = mw, h = r.h }
      btns.bpm_val   = { x = r.x + mw, y = r.y, w = r.w - mw * 2, h = r.h }
      btns.bpm_plus  = { x = r.x + r.w - mw, y = r.y, w = mw, h = r.h }
    end
    add_btn("grid", 36)
    add_btn("snap", 22)
    add_btn("snap_mode", 22)
    add_btn("len_mode", 22)
    add_btn("shift_dup", 22)
    cx = cx + 2
    add_btn("undo", 22)
    add_btn("redo", 22)
    add_btn("cut",  22)
    add_btn("copy", 22)
    add_btn("paste", 22)
    cx = cx + 2
    add_btn("fit", 22)
    add_btn("clr", 22)
    if self.midi_tracks and #self.midi_tracks > 1 then
      cx = cx + 2
      add_btn("midi_track", 38)
    end

    -- Right-aligned modifier status badges [C][S][A]
    local mod_w = 16
    local mod_gap = 2
    local rx = w - 6 - mod_w
    if rx > cx + 8 then
      btns.mod_alt = { x = rx, y = by, w = mod_w, h = bh }
      rx = rx - mod_w - mod_gap
    end
    if rx > cx + 8 then
      btns.mod_shift = { x = rx, y = by, w = mod_w, h = bh }
      rx = rx - mod_w - mod_gap
    end
    if rx > cx + 8 then
      btns.mod_ctrl = { x = rx, y = by, w = mod_w, h = bh }
      rx = rx - 8
    end
    if rx > cx + 40 then
      btns.info_area = { x = cx + 4, y = by, w = rx - cx - 4, h = bh }
    end
  end

  -- Scrollbar thumb geometry (total content span independent of view_beat to prevent drag jitter)
  local ppb = self.px_per_beat
  local ppp = self.px_per_pitch

  local h_visible_beats = roll_w / ppb
  local h_total_beats   = Layout.get_h_total(self)
  local h_range_beats   = max(0.0, h_total_beats - h_visible_beats)
  local h_thumb = { x = hscroll.x, y = hscroll.y + 2, w = 0, h = max(0, hscroll.h - 4) }
  if hscroll.w > 8 and hscroll.h >= 6 then
    if h_range_beats <= 1e-6 then
      h_thumb.w = hscroll.w
      h_thumb.x = hscroll.x
    else
      local ratio = min(1.0, h_visible_beats / h_total_beats)
      local tw = max(18, floor(hscroll.w * ratio))
      if tw > hscroll.w then tw = hscroll.w end
      local pos = max(0.0, min(1.0, (self.view_beat or 0) / h_range_beats))
      h_thumb.w = tw
      h_thumb.x = hscroll.x + floor(pos * max(0, hscroll.w - tw))
    end
  end

  local v_visible_pitches = roll_h / ppp
  local v_max_top         = 127.0
  local v_min_top         = min(127.0, max(0.0, v_visible_pitches - 1.0))
  local v_range_pitches   = max(0.0, v_max_top - v_min_top)
  local v_thumb = { x = vscroll.x + 2, y = vscroll.y, w = max(0, vscroll.w - 4), h = 0 }
  if vscroll.h > 8 and vscroll.w >= 6 then
    if v_range_pitches <= 1e-6 then
      v_thumb.h = vscroll.h
      v_thumb.y = vscroll.y
    else
      local ratio = min(1.0, v_visible_pitches / 128.0)
      local th = max(18, floor(vscroll.h * ratio))
      if th > vscroll.h then th = vscroll.h end
      local pos = max(0.0, min(1.0, (v_max_top - (self.view_pitch_top or 72)) / v_range_pitches))
      v_thumb.h = th
      v_thumb.y = vscroll.y + floor(pos * max(0, vscroll.h - th))
    end
  end

  return {
    w = w, h = h,
    toolbar   = toolbar,
    corner_tl = corner_tl,
    ruler     = ruler,
    hzoom     = hzoom,
    keyboard  = keyboard,
    roll      = roll,
    vscroll   = vscroll,
    corner_bl = corner_bl,
    hscroll   = hscroll,
    vzoom     = vzoom,
    btns      = btns,
    h_thumb   = h_thumb,
    v_thumb   = v_thumb,
    h_total_beats     = h_total_beats,
    h_visible_beats   = h_visible_beats,
    h_range_beats     = h_range_beats,
    v_min_top         = v_min_top,
    v_max_top         = v_max_top,
    v_visible_pitches = v_visible_pitches,
    v_range_pitches   = v_range_pitches,
  }
end

function Layout.clamp_view(self, layout)
  self.px_per_beat  = max(Layout.MIN_PPB, min(Layout.MAX_PPB, self.px_per_beat or Layout.DEF_PPB))
  self.px_per_pitch = max(Layout.MIN_PPP, min(Layout.MAX_PPP, self.px_per_pitch or Layout.DEF_PPP))

  if not layout then
    layout = Layout.compute(self)
  end

  local h_total = Layout.get_h_total(self)
  local h_vis   = layout.roll.w / self.px_per_beat
  local max_vb  = max(0.0, h_total - h_vis)
  self.view_beat = max(0.0, min(max_vb, self.view_beat or 0.0))

  local vp_vis = layout.roll.h / self.px_per_pitch
  local min_top = min(127.0, max(0.0, vp_vis - 1.0))
  self.view_pitch_top = max(min_top, min(127.0, self.view_pitch_top or 76.0))
end

function Layout.beat_to_px(self, layout, beat)
  return layout.roll.x + (beat - self.view_beat) * self.px_per_beat
end

function Layout.px_to_beat(self, layout, px)
  return self.view_beat + (px - layout.roll.x) / self.px_per_beat
end

function Layout.pitch_to_py(self, layout, pitch)
  return layout.roll.y + (self.view_pitch_top - pitch) * self.px_per_pitch
end

function Layout.py_to_pitch_float(self, layout, py)
  return self.view_pitch_top - (py - layout.roll.y) / self.px_per_pitch
end

function Layout.py_to_pitch(self, layout, py)
  local p = ceil(self.view_pitch_top - (py - layout.roll.y) / self.px_per_pitch)
  if p < 0 then return 0 end
  if p > 127 then return 127 end
  return p
end

--- Compute the clickable right-side time-stretch handle rectangle for multi-selected notes (>= 2).
function Layout.get_stretch_handle_rect(self, layout)
  local sel = self.selected_ids
  local notes = self.notes
  if not sel or not notes or #notes < 2 then return nil end

  layout = layout or Layout.compute(self)
  local roll = layout.roll
  if not roll or roll.w < 30 or roll.h < 20 then return nil end

  local count = 0
  local min_s, max_e = 1e12, -1e12
  local min_p, max_p = 128, -1
  for i = 1, #notes do
    local n = notes[i]
    if sel[n.id] then
      count = count + 1
      if n.start_beat < min_s then min_s = n.start_beat end
      local eb = n.start_beat + n.length
      if eb > max_e then max_e = eb end
      if n.pitch < min_p then min_p = n.pitch end
      if n.pitch > max_p then max_p = n.pitch end
    end
  end
  if count < 2 or max_e <= min_s then return nil end

  local x_left  = Layout.beat_to_px(self, layout, min_s)
  local x_right = Layout.beat_to_px(self, layout, max_e)
  local y_top   = Layout.pitch_to_py(self, layout, max_p)
  local y_bot   = Layout.pitch_to_py(self, layout, min_p) + (self.px_per_pitch or Layout.DEF_PPP)

  if y_bot < roll.y or y_top > roll.y + roll.h then return nil end
  if x_right < roll.x - 2 or x_right > roll.x + roll.w + 8 then return nil end

  local hw, hh = 20, 16
  local hx = floor(x_right + 6 + 0.5)
  if hx + hw > roll.x + roll.w - 2 then
    hx = max(roll.x + 2, floor(roll.x + roll.w - hw - 2))
  end

  local vis_y0 = max(roll.y, y_top)
  local vis_y1 = min(roll.y + roll.h, y_bot)
  local cy = (vis_y0 + vis_y1) * 0.5
  local hy = floor(cy - hh * 0.5 + 0.5)
  hy = max(roll.y + 2, min(roll.y + roll.h - hh - 2, hy))

  return {
    x = hx, y = hy, w = hw, h = hh,
    count = count,
    anchor_beat = min_s,
    max_end_beat = max_e,
    x_left = x_left,
    x_right = x_right,
    y_top = y_top,
    y_bot = y_bot,
  }
end

return Layout
