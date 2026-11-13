-- ============================================================================
-- pr_render.lua — Stateless 3-Layer NanoVG Vector Renderer for Piano Roll
--   Layer 1 (paint):         Chrome, toolbar, ruler, keyboard, grid, scrollbars
--   Layer 2 (paint_layer_2): Loop region, MIDI notes, active sounding keys
--   Layer 3 (paint_layer_3): Playhead, marquee box, hover handles, live HUD
-- ============================================================================

local Theme  = require("pr_theme")
local Layout = require("pr_layout")
local Model  = require("pr_model")

local Render = {}

local floor = math.floor
local ceil  = math.ceil
local abs   = math.abs
local max   = math.max
local min   = math.min

local TOP_LEFT_ALIGN    = TOP_LEFT or 0
local CENTER_ALIGN      = CENTER or 4
local CENTER_LEFT_ALIGN = CENTER_LEFT or 3

local function clip_rect(x, y, w, h, bx, by, bw, bh)
  local x1 = max(x, bx)
  local y1 = max(y, by)
  local x2 = min(x + w, bx + bw)
  local y2 = min(y + h, by + bh)
  local cw = x2 - x1
  local ch = y2 - y1
  if cw <= 0 or ch <= 0 then return nil end
  return x1, y1, cw, ch
end

local function fill_rrect(g, x, y, w, h, r)
  if w <= 0 or h <= 0 then return end
  local rad = min(r, w * 0.5, h * 0.5)
  if rad < 0.5 then
    g:fill_rect(x, y, w, h)
  else
    g:fill_rounded_rect(x, y, w, h, rad)
  end
end

local function stroke_rrect(g, x, y, w, h, r, lw)
  if w <= 0 or h <= 0 then return end
  local rad = min(r, w * 0.5, h * 0.5)
  if rad < 0.5 then
    g:stroke_rect(x, y, w, h, lw)
  else
    g:stroke_rounded_rect(x, y, w, h, rad, lw)
  end
end

local function set_rgb(g, c, a)
  g:set_color(c[1], c[2], c[3], a or 1.0)
end

-- ============================================================================
-- Layer 1 Helpers: Toolbar, Ruler, Keyboard, Grid, Scrollbars & Zoom Grips
-- ============================================================================

local function draw_toolbar(self, g, layout, pal)
  local tb = layout.toolbar
  if tb.h <= 0 then return end

  set_rgb(g, pal.toolbar_bg, 1.0)
  g:fill_rect(tb.x, tb.y, tb.w, tb.h)
  set_rgb(g, pal.toolbar_border, 1.0)
  g:draw_line(tb.x, tb.y + tb.h - 0.5, tb.x + tb.w, tb.y + tb.h - 0.5, 1.0)

  local btns = layout.btns
  local fs = max(8, min(11, tb.h - 16))

  local function draw_pill(r, active, col_on, label, text_col, text_alpha)
    if not r then return end
    if active then
      set_rgb(g, col_on or pal.toolbar_btn_on, 0.92)
    else
      set_rgb(g, pal.toolbar_btn, 1.0)
    end
    fill_rrect(g, r.x, r.y, r.w, r.h, 4)
    set_rgb(g, pal.toolbar_border, 0.9)
    stroke_rrect(g, r.x, r.y, r.w, r.h, 4, 0.8)
    if label then
      if active then
        set_rgb(g, Theme.contrast_text(col_on or pal.toolbar_btn_on), 1.0)
      else
        set_rgb(g, text_col or pal.toolbar_text, text_alpha or 0.95)
      end
      g:draw_text(label, r.x + r.w * 0.5, r.y + r.h * 0.5, r.w, fs, CENTER_ALIGN)
    end
  end

  -- Play / Pause button
  if btns.play then
    local r = btns.play
    draw_pill(r, self.playing, pal.note_fill, nil)
    local cx = r.x + r.w * 0.5
    local cy = r.y + r.h * 0.5
    if self.playing then
      set_rgb(g, Theme.contrast_text(pal.note_fill), 1.0)
      local bh = max(6, floor(r.h * 0.52))
      g:fill_rect(cx - 4, cy - bh * 0.5, 2.6, bh)
      g:fill_rect(cx + 1.4, cy - bh * 0.5, 2.6, bh)
    else
      set_rgb(g, pal.toolbar_text, 1.0)
      local sz = max(3.5, min(5.5, r.h * 0.28))
      local p = Path(cx - sz * 0.65, cy - sz)
      p:line_to(cx + sz * 0.95, cy)
      p:line_to(cx - sz * 0.65, cy + sz)
      p:close()
      g:fill_path(p)
    end
  end

  -- Stop button
  if btns.stop then
    local r = btns.stop
    draw_pill(r, false, nil, nil)
    set_rgb(g, pal.toolbar_text, 0.92)
    local sq = max(5, min(8, floor(r.h * 0.42)))
    g:fill_rect(r.x + (r.w - sq) * 0.5, r.y + (r.h - sq) * 0.5, sq, sq)
  end

  -- Loop button
  if btns.loop then
    draw_pill(btns.loop, self.loop_enabled, pal.loop_fill, "LOOP")
  end

  -- BPM widget: [-] [BPM] [+]
  if btns.bpm then
    local r = btns.bpm
    local mw = (btns.bpm_minus and btns.bpm_minus.w) or 13
    set_rgb(g, pal.toolbar_btn, 1.0)
    fill_rrect(g, r.x, r.y, r.w, r.h, 4)
    set_rgb(g, pal.toolbar_border, 0.9)
    stroke_rrect(g, r.x, r.y, r.w, r.h, 4, 0.8)

    -- Dividers
    set_rgb(g, pal.toolbar_sep, 0.8)
    g:draw_line(r.x + mw, r.y + 2, r.x + mw, r.y + r.h - 2, 0.8)
    g:draw_line(r.x + r.w - mw, r.y + 2, r.x + r.w - mw, r.y + r.h - 2, 0.8)

    local cy_txt = r.y + r.h * 0.5
    set_rgb(g, pal.toolbar_muted, 1.0)
    g:draw_text("-", r.x + mw * 0.5, cy_txt, mw, fs, CENTER_ALIGN)
    g:draw_text("+", r.x + r.w - mw * 0.5, cy_txt, mw, fs, CENTER_ALIGN)

    set_rgb(g, pal.toolbar_text, 1.0)
    local bpm_str = (abs(self.bpm - floor(self.bpm)) < 0.05)
      and string.format("%d", floor(self.bpm + 0.5))
      or string.format("%.1f", self.bpm)
    g:draw_text(bpm_str, r.x + r.w * 0.5, cy_txt, r.w - mw * 2, fs, CENTER_ALIGN)
  end

  -- Grid division pill
  if btns.grid then
    draw_pill(btns.grid, false, nil, Model.describe_grid(self))
  end

  -- Snap toggle, Snap Mode pill & Note Length Mode pill
  if btns.snap then
    draw_pill(btns.snap, self.snap_enabled, pal.note_fill, "SNAP")
  end
  if btns.snap_mode then
    local sm_active = ((self.snap_mode or 1) == 4)
    draw_pill(btns.snap_mode, sm_active, pal.loop_fill, Model.describe_snap_mode(self), pal.toolbar_muted)
  end
  if btns.len_mode then
    local is_last = ((self.default_len_mode or 1) == 1)
    draw_pill(btns.len_mode, is_last, pal.note_fill, Model.describe_len_mode(self), pal.toolbar_muted)
  end

  -- Undo / Redo / Cut / Copy / Paste action pills
  local has_sel = (Model.count_selected(self) > 0)
  local has_cb  = Model.has_clipboard(self)
  if btns.undo then
    local ok = Model.can_undo(self)
    draw_pill(btns.undo, false, nil, "UND", ok and pal.toolbar_text or pal.toolbar_muted, ok and 0.95 or 0.38)
  end
  if btns.redo then
    local ok = Model.can_redo(self)
    draw_pill(btns.redo, false, nil, "RDO", ok and pal.toolbar_text or pal.toolbar_muted, ok and 0.95 or 0.38)
  end
  if btns.cut then
    draw_pill(btns.cut, false, nil, "CUT", has_sel and pal.toolbar_text or pal.toolbar_muted, has_sel and 0.95 or 0.38)
  end
  if btns.copy then
    draw_pill(btns.copy, false, nil, "CPY", has_sel and pal.toolbar_text or pal.toolbar_muted, has_sel and 0.95 or 0.38)
  end
  if btns.paste then
    draw_pill(btns.paste, false, nil, "PST", has_cb and pal.toolbar_text or pal.toolbar_muted, has_cb and 0.95 or 0.38)
  end

  -- Fit & Clear
  if btns.fit then
    draw_pill(btns.fit, false, nil, "FIT")
  end
  if btns.clr then
    draw_pill(btns.clr, false, nil, "CLR")
  end

  -- Status info text
  if btns.info_area then
    local r = btns.info_area
    set_rgb(g, pal.toolbar_muted, 0.9)
    local info_str = Model.note_count_string(self)
    g:draw_text(info_str, r.x + 2, r.y + r.h * 0.5, r.w - 4, fs, CENTER_LEFT_ALIGN)
  end

  -- Keyname modifier indicator badges [C][S][A]
  local kd = self.keys_down or {}
  local ctrl_on  = kd["Control_L"] or kd["Control_R"] or kd["Ctrl"]
  local shift_on = kd["Shift_L"] or kd["Shift_R"] or kd["Shift"]
  local alt_on   = kd["Alt_L"] or kd["Alt_R"] or kd["Alt"]
  draw_pill(btns.mod_ctrl,  ctrl_on,  pal.loop_border,   "C", pal.toolbar_muted)
  draw_pill(btns.mod_shift, shift_on, pal.note_selected, "S", pal.toolbar_muted)
  draw_pill(btns.mod_alt,   alt_on,   pal.note_fill,     "A", pal.toolbar_muted)
end

local function draw_ruler(self, g, layout, pal)
  local rl = layout.ruler
  if rl.h <= 0 or rl.w <= 0 then return end

  -- Corner above keyboard
  local ctl = layout.corner_tl
  if ctl.w > 0 and ctl.h > 0 then
    set_rgb(g, pal.toolbar_bg, 1.0)
    g:fill_rect(ctl.x, ctl.y, ctl.w, ctl.h)
    set_rgb(g, pal.ruler_border, 1.0)
    g:draw_line(ctl.x, ctl.y + ctl.h - 0.5, ctl.x + ctl.w, ctl.y + ctl.h - 0.5, 1.0)
    g:draw_line(ctl.x + ctl.w - 0.5, ctl.y, ctl.x + ctl.w - 0.5, ctl.y + ctl.h, 1.0)
    set_rgb(g, pal.toolbar_muted, 0.9)
    local fs = max(8, min(10, ctl.h - 8))
    g:draw_text(string.format("%d/4", self.timesig_num or 4), ctl.x + ctl.w * 0.5, ctl.y + ctl.h * 0.5, ctl.w, fs, CENTER_ALIGN)
  end

  set_rgb(g, pal.ruler_bg, 1.0)
  g:fill_rect(rl.x, rl.y, rl.w, rl.h)
  set_rgb(g, pal.ruler_border, 1.0)
  g:draw_line(rl.x, rl.y + rl.h - 0.5, rl.x + rl.w, rl.y + rl.h - 0.5, 1.0)

  local ppb = self.px_per_beat
  local vb  = self.view_beat
  local tsig = max(1, self.timesig_num or 4)
  local b_start = floor(vb)
  local b_end   = ceil(vb + rl.w / ppb)

  -- Adaptive bar label stride so labels never overlap when zoomed out
  local px_per_bar = ppb * tsig
  local bar_stride = 1
  while px_per_bar * bar_stride < 34 do
    bar_stride = bar_stride * 2
  end

  local fs = max(8, min(10, rl.h - 8))
  for b = b_start, b_end do
    local x = rl.x + (b - vb) * ppb
    if x >= rl.x and x <= rl.x + rl.w then
      if b % tsig == 0 then
        local bar_num = floor(b / tsig) + 1
        set_rgb(g, pal.ruler_tick_major, 0.95)
        g:draw_line(x, rl.y + 4, x, rl.y + rl.h, 1.1)
        if ((bar_num - 1) % bar_stride == 0) and (x + 20 <= rl.x + rl.w + 14) then
          set_rgb(g, pal.ruler_text, 0.95)
          g:draw_text(tostring(bar_num), x + 3, rl.y + 3, 28, fs, TOP_LEFT_ALIGN)
        end
      elseif ppb >= 18 then
        set_rgb(g, pal.ruler_tick_minor, 0.85)
        g:draw_line(x, rl.y + rl.h - 6, x, rl.y + rl.h, 0.8)
      end
    end
  end
end

local function draw_keyboard(self, g, layout, pal)
  local kb = layout.keyboard
  if kb.w <= 0 or kb.h <= 0 then return end

  local ppp   = self.px_per_pitch
  local top_p = self.view_pitch_top
  local p_hi  = min(127, ceil(top_p))
  local p_lo  = max(0, floor(top_p - kb.h / ppp) - 1)
  local black_w = floor(kb.w * 0.58)

  -- Base white key strip
  set_rgb(g, pal.key_white, 1.0)
  g:fill_rect(kb.x, kb.y, kb.w, kb.h)

  for p = p_lo, p_hi do
    local y1 = layout.roll.y + (top_p - p) * ppp
    local cy, ch
    local cx, _, cw, cch = clip_rect(kb.x, y1, kb.w, ppp, kb.x, kb.y, kb.w, kb.h)
    if cx and cch > 0 then
      cy, ch = y1, ppp
      local cy_clip = max(kb.y, y1)
      local ch_clip = min(kb.y + kb.h, y1 + ppp) - cy_clip

      if Model.is_black_key(p) then
        -- Right tail shows white key separator
        set_rgb(g, pal.key_white_alt, 1.0)
        g:fill_rect(kb.x + black_w, cy_clip, kb.w - black_w, ch_clip)
        if ppp >= 5.5 and ch_clip >= 2 then
          local mid_y = y1 + ppp * 0.5
          if mid_y >= kb.y and mid_y <= kb.y + kb.h then
            set_rgb(g, pal.key_white_border, 0.65)
            g:draw_line(kb.x + black_w, mid_y, kb.x + kb.w, mid_y, 0.7)
          end
        end
        -- Black key body
        set_rgb(g, pal.key_black, 1.0)
        fill_rrect(g, kb.x, cy_clip + 0.3, black_w, max(1, ch_clip - 0.6), 1.5)
        if ch_clip >= 4 then
          set_rgb(g, pal.key_black_hi, 0.8)
          g:draw_line(kb.x + 1, cy_clip + 1, kb.x + black_w - 2, cy_clip + 1, 0.8)
        end
      else
        -- Bottom divider for white keys (stronger on C / F boundary; thin keys hide non-C/F dividers)
        local pc = p % 12
        local bot_y = y1 + ppp
        if bot_y >= kb.y and bot_y <= kb.y + kb.h then
          local strong = (pc == 0 or pc == 5)
          if strong or ppp >= 5.5 then
            set_rgb(g, pal.key_white_border, strong and 0.9 or 0.45)
            g:draw_line(kb.x, bot_y, kb.x + kb.w, bot_y, strong and 0.9 or 0.6)
          end
        end

        -- Label C notes centered cleanly inside the C white key
        if pc == 0 and ch >= 7 and ch_clip >= 7 then
          local mid_y = y1 + ppp * 0.5
          if mid_y >= kb.y + 4 and mid_y <= kb.y + kb.h - 4 then
            local fs = max(7, min(10, floor(ppp * 0.78)))
            set_rgb(g, pal.key_text, 0.95)
            g:draw_text(Model.pitch_name(p), kb.x + 4, mid_y, kb.w - 6, fs, CENTER_LEFT_ALIGN)
          end
        end
      end
      local _ = cw
    end
  end

  -- Right separator border of keyboard
  set_rgb(g, pal.border, 1.0)
  g:draw_line(kb.x + kb.w - 0.5, kb.y, kb.x + kb.w - 0.5, kb.y + kb.h, 1.0)
end

local function draw_grid(self, g, layout, pal)
  local roll = layout.roll
  if roll.w <= 0 or roll.h <= 0 then return end

  local ppb   = self.px_per_beat
  local ppp   = self.px_per_pitch
  local vb    = self.view_beat
  local top_p = self.view_pitch_top
  local tsig  = max(1, self.timesig_num or 4)

  -- Base roll background
  set_rgb(g, pal.roll_white_row, 1.0)
  g:fill_rect(roll.x, roll.y, roll.w, roll.h)

  -- Horizontal pitch rows
  local p_hi = min(127, ceil(top_p))
  local p_lo = max(0, floor(top_p - roll.h / ppp) - 1)
  local hi_rows = (self.highlight_rows ~= false)

  for p = p_lo, p_hi do
    local y1 = roll.y + (top_p - p) * ppp
    local cy1 = max(roll.y, y1)
    local cy2 = min(roll.y + roll.h, y1 + ppp)
    local ch  = cy2 - cy1
    if ch > 0 then
      if hi_rows and Model.is_black_key(p) then
        set_rgb(g, pal.roll_black_row, 1.0)
        g:fill_rect(roll.x, cy1, roll.w, ch)
      end
      local bot_y = y1 + ppp
      if bot_y >= roll.y and bot_y <= roll.y + roll.h then
        if p % 12 == 0 then
          set_rgb(g, pal.grid_octave, pal.grid_octave_a or 0.68)
          g:draw_line(roll.x, bot_y, roll.x + roll.w, bot_y, 1.0)
        elseif ppp >= 5.5 then
          set_rgb(g, pal.grid_row_line, pal.grid_row_a or 0.28)
          g:draw_line(roll.x, bot_y, roll.x + roll.w, bot_y, 0.6)
        end
      end
    end
  end

  -- Vertical grid lines synced to active grid setting & zoom density limit
  local step = Model.get_draw_grid_step(self)
  local min_major_px = Model.MIN_MAJOR_GRID_PX or 6.0
  local bar_step = tsig
  while bar_step * ppb < min_major_px and bar_step < 256.0 do
    bar_step = bar_step * 2.0
  end

  local vb_end = vb + roll.w / ppb

  -- 1. Subdivisions (only when grid division < 1 beat and within readable density limit)
  if step < 1.0 - 1e-4 then
    local first_i = floor(vb / step)
    local last_i  = ceil(vb_end / step)
    for i = first_i, last_i do
      local b = i * step
      local x = roll.x + (b - vb) * ppb
      if x >= roll.x and x <= roll.x + roll.w then
        local near_beat = math.abs(b - floor(b + 0.5)) < 1e-4
        if not near_beat then
          set_rgb(g, pal.grid_sub, pal.grid_sub_a or 0.34)
          g:draw_line(x, roll.y, x, roll.y + roll.h, 0.55)
        end
      end
    end
  end

  -- 2. Beats or Half-bars (strictly filtered by active grid step & density limit)
  if step <= 1.0 + 1e-4 then
    if ppb >= min_major_px then
      local b_first = floor(vb)
      local b_last  = ceil(vb_end)
      for b = b_first, b_last do
        if math.abs(b - floor(b / bar_step + 0.5) * bar_step) >= 1e-4 then
          local x = roll.x + (b - vb) * ppb
          if x >= roll.x and x <= roll.x + roll.w then
            set_rgb(g, pal.grid_beat, pal.grid_beat_a or 0.54)
            g:draw_line(x, roll.y, x, roll.y + roll.h, 0.75)
          end
        end
      end
    end
  elseif step < bar_step - 1e-4 then
    local first_i = floor(vb / step)
    local last_i  = ceil(vb_end / step)
    for i = first_i, last_i do
      local b = i * step
      if math.abs(b - floor(b / bar_step + 0.5) * bar_step) >= 1e-4 then
        local x = roll.x + (b - vb) * ppb
        if x >= roll.x and x <= roll.x + roll.w then
          set_rgb(g, pal.grid_beat, pal.grid_beat_a or 0.54)
          g:draw_line(x, roll.y, x, roll.y + roll.h, 0.8)
        end
      end
    end
  end

  -- 3. Bar lines (coarsened cleanly via bar_step when zoomed very small)
  local bar_first = floor(vb / bar_step)
  local bar_last  = ceil(vb_end / bar_step)
  for k = bar_first, bar_last do
    local b = k * bar_step
    local x = roll.x + (b - vb) * ppb
    if x >= roll.x and x <= roll.x + roll.w then
      set_rgb(g, pal.grid_bar, pal.grid_bar_a or 0.86)
      g:draw_line(x, roll.y, x, roll.y + roll.h, 1.1)
    end
  end

  -- Sequence length end marker
  local end_x = roll.x + ((self.length_beats or 16) - vb) * ppb
  if end_x >= roll.x and end_x <= roll.x + roll.w then
    set_rgb(g, pal.seq_end, 0.75)
    g:draw_line(end_x, roll.y, end_x, roll.y + roll.h, 1.5)
  end
end

local function draw_scrollbars_and_zoom(self, g, layout, pal)
  -- Bottom-Left Reset Default Zoom & Position control (swapped cleanly with V-Zoom)
  local cbl = layout.corner_bl
  if cbl.w > 0 and cbl.h > 0 then
    set_rgb(g, pal.zoom_grip_bg, 1.0)
    g:fill_rect(cbl.x, cbl.y, cbl.w, cbl.h)
    set_rgb(g, pal.border, 0.85)
    g:stroke_rect(cbl.x + 0.5, cbl.y + 0.5, cbl.w - 1, cbl.h - 1, 0.8)

    local cy = cbl.y + cbl.h * 0.5
    local ix = cbl.x + (cbl.w >= 36 and 10 or cbl.w * 0.5)
    local sz = max(3, min(4.2, min(cbl.w, cbl.h) * 0.28))
    set_rgb(g, pal.zoom_grip_fg, 0.92)
    g:stroke_rect(ix - sz, cy - sz, sz * 2, sz * 2, 1.0)
    g:fill_rect(ix - 1, cy - 1, 2, 2)
    if cbl.w >= 36 then
      local fs = max(7, min(9, cbl.h - 6))
      g:draw_text("RST", cbl.x + 17 + (cbl.w - 17) * 0.5, cy, cbl.w - 18, fs, CENTER_ALIGN)
    end
  end

  -- Bottom Horizontal Scrollbar
  local hs = layout.hscroll
  if hs.w > 0 and hs.h > 0 then
    set_rgb(g, pal.scroll_track, 1.0)
    g:fill_rect(hs.x, hs.y, hs.w, hs.h)
    set_rgb(g, pal.border, 0.65)
    g:draw_line(hs.x, hs.y + 0.5, hs.x + hs.w, hs.y + 0.5, 0.8)
    local ht = layout.h_thumb
    if ht.w > 0 and ht.h > 0 then
      set_rgb(g, pal.scroll_thumb, 0.95)
      fill_rrect(g, ht.x, ht.y, ht.w, ht.h, ht.h * 0.5)
    end
  end

  -- Top-Right H-Zoom grip (drag Left/Right)
  local hz = layout.hzoom
  if hz.w > 0 and hz.h > 0 then
    set_rgb(g, pal.zoom_grip_bg, 1.0)
    g:fill_rect(hz.x, hz.y, hz.w, hz.h)
    set_rgb(g, pal.border, 0.85)
    g:stroke_rect(hz.x + 0.5, hz.y + 0.5, hz.w - 1, hz.h - 1, 0.8)

    local cx = hz.x + hz.w * 0.5
    local cy = hz.y + hz.h * 0.5
    local aw = max(3, min(5, hz.w * 0.34))
    set_rgb(g, pal.zoom_grip_fg, 0.95)
    -- Double-headed horizontal arrow <->
    g:draw_line(cx - aw, cy, cx + aw, cy, 1.2)
    g:draw_line(cx - aw + 2.5, cy - 3, cx - aw, cy, 1.2)
    g:draw_line(cx - aw + 2.5, cy + 3, cx - aw, cy, 1.2)
    g:draw_line(cx + aw - 2.5, cy - 3, cx + aw, cy, 1.2)
    g:draw_line(cx + aw - 2.5, cy + 3, cx + aw, cy, 1.2)
  end

  -- Right Vertical Scrollbar
  local vs = layout.vscroll
  if vs.w > 0 and vs.h > 0 then
    set_rgb(g, pal.scroll_track, 1.0)
    g:fill_rect(vs.x, vs.y, vs.w, vs.h)
    set_rgb(g, pal.border, 0.65)
    g:draw_line(vs.x + 0.5, vs.y, vs.x + 0.5, vs.y + vs.h, 0.8)
    local vt = layout.v_thumb
    if vt.w > 0 and vt.h > 0 then
      set_rgb(g, pal.scroll_thumb, 0.95)
      fill_rrect(g, vt.x, vt.y, vt.w, vt.h, vt.w * 0.5)
    end
  end

  -- Bottom-Right V-Zoom grip (drag Up/Down, symmetric with H-Zoom at top-right)
  local vz = layout.vzoom
  if vz.w > 0 and vz.h > 0 then
    set_rgb(g, pal.zoom_grip_bg, 1.0)
    g:fill_rect(vz.x, vz.y, vz.w, vz.h)
    set_rgb(g, pal.border, 0.85)
    g:stroke_rect(vz.x + 0.5, vz.y + 0.5, vz.w - 1, vz.h - 1, 0.8)

    local cx = vz.x + vz.w * 0.5
    local cy = vz.y + vz.h * 0.5
    local ah = max(3, min(5, vz.h * 0.34))
    set_rgb(g, pal.zoom_grip_fg, 0.95)
    -- Double-headed vertical arrow
    g:draw_line(cx, cy - ah, cx, cy + ah, 1.2)
    g:draw_line(cx - 3, cy - ah + 2.5, cx, cy - ah, 1.2)
    g:draw_line(cx + 3, cy - ah + 2.5, cx, cy - ah, 1.2)
    g:draw_line(cx - 3, cy + ah - 2.5, cx, cy + ah, 1.2)
    g:draw_line(cx + 3, cy + ah - 2.5, cx, cy + ah, 1.2)
  end
end

function Render.paint_layer_1(self, g)
  local w, h = self:get_size()
  local layout = Layout.compute(self, w, h)
  Layout.clamp_view(self, layout)
  local pal = Theme.resolve(self)

  set_rgb(g, pal.bg, 1.0)
  g:fill_all()

  draw_grid(self, g, layout, pal)
  draw_keyboard(self, g, layout, pal)
  draw_ruler(self, g, layout, pal)
  draw_toolbar(self, g, layout, pal)
  draw_scrollbars_and_zoom(self, g, layout, pal)

  set_rgb(g, pal.border, 0.95)
  g:stroke_rect(0.5, 0.5, w - 1, h - 1, 1.0)
end

-- ============================================================================
-- Layer 2: Loop Region, MIDI Notes, Sounding Piano Keys
-- ============================================================================

function Render.paint_layer_2(self, g)
  local w, h = self:get_size()
  local layout = Layout.compute(self, w, h)
  local pal = Theme.resolve(self)

  local roll = layout.roll
  local rl   = layout.ruler
  local kb   = layout.keyboard
  local ppb  = self.px_per_beat
  local ppp  = self.px_per_pitch
  local vb   = self.view_beat
  local top_p = self.view_pitch_top

  -- 1. Loop region overlay (on ruler + subtle tint on roll)
  if self.loop_start ~= nil and self.loop_end ~= nil and self.loop_end > self.loop_start then
    local lx1 = Layout.beat_to_px(self, layout, self.loop_start)
    local lx2 = Layout.beat_to_px(self, layout, self.loop_end)
    local enabled = self.loop_enabled

    if rl.h > 0 then
      local cx, cy, cw, ch = clip_rect(lx1, rl.y + 1, lx2 - lx1, max(4, rl.h - 2), rl.x, rl.y, rl.w, rl.h)
      if cx then
        set_rgb(g, pal.loop_fill, enabled and 0.30 or 0.12)
        g:fill_rect(cx, cy, cw, ch)
        set_rgb(g, pal.loop_border, enabled and 0.95 or 0.40)
        g:fill_rect(cx, rl.y + 1, cw, 3)
      end
      if lx1 >= rl.x and lx1 <= rl.x + rl.w then
        set_rgb(g, pal.loop_border, enabled and 0.95 or 0.45)
        g:draw_line(lx1, rl.y + 1, lx1, rl.y + rl.h, 1.5)
      end
      if lx2 >= rl.x and lx2 <= rl.x + rl.w then
        set_rgb(g, pal.loop_border, enabled and 0.95 or 0.45)
        g:draw_line(lx2, rl.y + 1, lx2, rl.y + rl.h, 1.5)
      end
    end

    if roll.w > 0 and roll.h > 0 then
      local cx, cy, cw, ch = clip_rect(lx1, roll.y, lx2 - lx1, roll.h, roll.x, roll.y, roll.w, roll.h)
      if cx then
        set_rgb(g, pal.loop_fill, enabled and 0.08 or 0.03)
        g:fill_rect(cx, cy, cw, ch)
      end
      if lx1 >= roll.x and lx1 <= roll.x + roll.w then
        set_rgb(g, pal.loop_border, enabled and 0.55 or 0.22)
        g:draw_line(lx1, roll.y, lx1, roll.y + roll.h, 1.0)
      end
      if lx2 >= roll.x and lx2 <= roll.x + roll.w then
        set_rgb(g, pal.loop_border, enabled and 0.55 or 0.22)
        g:draw_line(lx2, roll.y, lx2, roll.y + roll.h, 1.0)
      end
    end
  end

  -- 2. MIDI Notes
  local notes   = self.notes
  local n_notes = #notes
  if n_notes > 0 and roll.w > 0 and roll.h > 0 then
    local b_lo = vb - 0.5
    local b_hi = vb + roll.w / ppb + 0.5
    local p_hi = min(127, ceil(top_p) + 1)
    local p_lo = max(0, floor(top_p - roll.h / ppp) - 1)

    local sel_ids    = self.selected_ids or {}
    local active_ids = self.active_note_ids or {}
    local vel_shade  = (self.velocity_shade ~= false)
    local show_names = (self.show_note_names ~= false)

    for i = 1, n_notes do
      local note = notes[i]
      local sb = note.start_beat
      local ln = note.length
      local pitch = note.pitch
      if pitch >= p_lo and pitch <= p_hi and (sb + ln) > b_lo and sb < b_hi then
        local nx1 = roll.x + (sb - vb) * ppb
        local nx2 = nx1 + ln * ppb
        local ny1 = roll.y + (top_p - pitch) * ppp
        local ny2 = ny1 + ppp

        local cx, cy, cw, ch = clip_rect(nx1 + 0.5, ny1 + 0.5, max(1, nx2 - nx1 - 1), max(1, ny2 - ny1 - 1),
                                         roll.x, roll.y, roll.w, roll.h)
        if cx and cw >= 1 and ch >= 1 then
          local is_sel = (sel_ids[note.id] == true)
          local is_act = (active_ids[note.id] ~= nil)

          local base_col = is_sel and pal.note_selected or (is_act and pal.note_active or pal.note_fill)
          local fill_col = base_col
          if vel_shade and (not is_act) then
            local factor = 0.65 + 0.42 * (note.velocity / 127.0)
            fill_col = Theme.scale_rgb(base_col, factor)
          end

          set_rgb(g, fill_col, 0.94)
          fill_rrect(g, cx, cy, cw, ch, 2.2)

          -- Velocity left accent bar (if unclipped on left & wide enough)
          if nx1 + 1 >= roll.x and cw >= 5 and ch >= 3 then
            local v_h = max(2, (ch - 2) * (note.velocity / 127.0))
            local v_y = cy + (ch - 1) - v_h
            set_rgb(g, { 255, 255, 255 }, 0.42)
            g:fill_rect(cx + 1, v_y, min(2.5, cw * 0.3), v_h)
          end

          -- Selection or crisp note border
          if is_sel then
            if cw >= 3 and ch >= 3 then
              set_rgb(g, { 22, 24, 30 }, 0.85)
              stroke_rrect(g, cx, cy, cw, ch, 2.2, 2.0)
            end
            set_rgb(g, { 255, 255, 255 }, 0.98)
            stroke_rrect(g, cx + 0.5, cy + 0.5, max(1, cw - 1), max(1, ch - 1), 1.8, 1.1)
            -- Right tail grip notch for selected notes
            if nx2 <= roll.x + roll.w + 1 and cw >= 10 and ch >= 5 then
              set_rgb(g, { 255, 255, 255 }, 0.62)
              g:fill_rect(cx + cw - 2.6, cy + 2, 1.6, max(1, ch - 4))
            end
          elseif cw >= 3 and ch >= 3 then
            set_rgb(g, pal.note_border, 0.65)
            stroke_rrect(g, cx, cy, cw, ch, 2.2, 0.7)
          end

          -- Pitch name inside note
          if show_names and cw >= 24 and ch >= 10 then
            local fs = max(7, min(10, floor(ch - 3)))
            set_rgb(g, Theme.contrast_text(fill_col), 0.92)
            local lbl = Model.pitch_name(pitch)
            g:draw_text(lbl, cx + 5, cy + ch * 0.5, cw - 7, fs, CENTER_LEFT_ALIGN)
          end
        end
      end
    end
  end

  -- 3. Active sounding keys on piano keyboard
  if kb.w > 0 and kb.h > 0 and self.voice_counts then
    local vc = self.voice_counts
    local p_hi = min(127, ceil(top_p))
    local p_lo = max(0, floor(top_p - kb.h / ppp) - 1)
    local black_w = floor(kb.w * 0.58)
    for p = p_lo, p_hi do
      if vc[p] > 0 then
        local y1 = roll.y + (top_p - p) * ppp
        local kw_draw = Model.is_black_key(p) and black_w or kb.w
        local cx, cy, cw, ch = clip_rect(kb.x, y1, kw_draw, ppp, kb.x, kb.y, kb.w, kb.h)
        if cx then
          set_rgb(g, pal.key_active, 0.65)
          g:fill_rect(cx, cy, cw, ch)
        end
      end
    end
  end

  local _ = w
  local __ = h
end

-- ============================================================================
-- Layer 3: Playhead, Marquee Box, Hover Highlights, Live Drag HUD
-- ============================================================================

function Render.paint_layer_3(self, g)
  local w, h = self:get_size()
  local layout = Layout.compute(self, w, h)
  local pal = Theme.resolve(self)
  local roll = layout.roll
  local rl   = layout.ruler
  local kb   = layout.keyboard
  local ppp  = self.px_per_pitch
  local top_p = self.view_pitch_top

  -- 1. Hover highlights
  if self.hover_region == "keyboard" and self.hover_pitch ~= nil and kb.w > 0 then
    local y1 = roll.y + (top_p - self.hover_pitch) * ppp
    local kw_draw = Model.is_black_key(self.hover_pitch) and floor(kb.w * 0.58) or kb.w
    local cx, cy, cw, ch = clip_rect(kb.x, y1, kw_draw, ppp, kb.x, kb.y, kb.w, kb.h)
    if cx then
      set_rgb(g, pal.key_hover, 0.35)
      g:fill_rect(cx, cy, cw, ch)
    end
  elseif self.hover_region == "btn" and self.hover_btn and layout.btns[self.hover_btn] then
    local r = layout.btns[self.hover_btn]
    set_rgb(g, { 255, 255, 255 }, pal.is_light and 0.18 or 0.12)
    fill_rrect(g, r.x, r.y, r.w, r.h, 4)
  elseif self.hover_region == "hzoom" and layout.hzoom.w > 0 then
    local r = layout.hzoom
    set_rgb(g, { 255, 255, 255 }, 0.14)
    g:fill_rect(r.x, r.y, r.w, r.h)
  elseif self.hover_region == "vzoom" and layout.vzoom.w > 0 then
    local r = layout.vzoom
    set_rgb(g, { 255, 255, 255 }, 0.14)
    g:fill_rect(r.x, r.y, r.w, r.h)
  elseif self.hover_region == "corner_bl" and layout.corner_bl.w > 0 then
    local r = layout.corner_bl
    set_rgb(g, { 255, 255, 255 }, 0.14)
    g:fill_rect(r.x, r.y, r.w, r.h)
  end

  -- Hover note & tail resize indicator
  if (not self.drag_mode) and self.hover_note_id then
    local hn = Model.find_note_by_id(self, self.hover_note_id)
    if hn then
      local nx1 = Layout.beat_to_px(self, layout, hn.start_beat)
      local nx2 = nx1 + hn.length * self.px_per_beat
      local ny1 = Layout.pitch_to_py(self, layout, hn.pitch)
      local cx, cy, cw, ch = clip_rect(nx1 + 0.5, ny1 + 0.5, max(1, nx2 - nx1 - 1), max(1, ppp - 1),
                                       roll.x, roll.y, roll.w, roll.h)
      if cx then
        set_rgb(g, { 255, 255, 255 }, 0.55)
        stroke_rrect(g, cx, cy, cw, ch, 2.2, 1.2)
        if self.hover_note_tail and nx2 >= roll.x and nx2 <= roll.x + roll.w then
          set_rgb(g, pal.note_selected, 0.95)
          g:fill_rect(max(cx, cx + cw - 3.5), cy + 1, min(3.5, cw), max(1, ch - 2))
        end
      end
    end
  end

  -- 2. Marquee Selection Box (Ctrl + drag on blank roll)
  if self.drag_mode == "marquee" and self.marquee_x0 and self.marquee_x1 then
    local mx1 = min(self.marquee_x0, self.marquee_x1)
    local my1 = min(self.marquee_y0, self.marquee_y1)
    local mw  = math.abs(self.marquee_x1 - self.marquee_x0)
    local mh  = math.abs(self.marquee_y1 - self.marquee_y0)
    local cx, cy, cw, ch = clip_rect(mx1, my1, mw, mh, roll.x, roll.y, roll.w, roll.h)
    if cx then
      set_rgb(g, pal.marquee_fill, 0.18)
      g:fill_rect(cx, cy, cw, ch)
      set_rgb(g, pal.marquee_border, 0.92)
      g:stroke_rect(cx, cy, cw, ch, 1.2)
    end
  end

  -- 2b. High-Contrast Active Edit Feedback (ghost originals, ruler span, alignment guides, active halos)
  local dmode = self.drag_mode
  if (dmode == "move" or dmode == "resize" or dmode == "create") and self.drag_note then
    local is_resizing = (dmode == "resize") or (dmode == "create" and (self.default_len_mode or 1) == 2)
    local snaps = self.drag_snaps
    local targets = {}
    if snaps and #snaps > 0 then
      for i = 1, #snaps do
        if snaps[i].note then targets[#targets + 1] = snaps[i].note end
      end
    end
    if #targets == 0 then
      targets[1] = self.drag_note
    end

    local min_b, max_b = 1e9, -1e9
    for i = 1, #targets do
      local tn = targets[i]
      if tn.start_beat < min_b then min_b = tn.start_beat end
      local eb = tn.start_beat + tn.length
      if eb > max_b then max_b = eb end
    end

    -- Ruler highlight band & vertical alignment guides across roll
    local gx0 = Layout.beat_to_px(self, layout, min_b)
    local gx1 = Layout.beat_to_px(self, layout, max_b)
    if rl.h > 0 and gx1 >= roll.x and gx0 <= roll.x + roll.w then
      local rx0 = max(roll.x, gx0)
      local rx1 = min(roll.x + roll.w, gx1)
      if rx1 > rx0 then
        set_rgb(g, pal.marquee_fill, 0.34)
        g:fill_rect(rx0, rl.y + 1, rx1 - rx0, max(1, rl.h - 2))
        set_rgb(g, pal.marquee_border, 0.92)
        g:fill_rect(rx0, rl.y, rx1 - rx0, 2)
      end
    end
    if gx0 >= roll.x and gx0 <= roll.x + roll.w then
      set_rgb(g, pal.marquee_border, 0.58)
      g:draw_line(gx0, (rl.h > 0) and rl.y or roll.y, gx0, roll.y + roll.h, 1.0)
    end
    if is_resizing and gx1 >= roll.x and gx1 <= roll.x + roll.w then
      set_rgb(g, pal.note_selected, 0.72)
      g:draw_line(gx1, (rl.h > 0) and rl.y or roll.y, gx1, roll.y + roll.h, 1.1)
    end

    -- Target pitch row & keyboard key highlight for primary dragged note
    local pri = self.drag_note
    if not is_resizing then
      local py1 = Layout.pitch_to_py(self, layout, pri.pitch)
      local rcx, rcy, rcw, rch = clip_rect(roll.x, py1, roll.w, ppp, roll.x, roll.y, roll.w, roll.h)
      if rcx then
        set_rgb(g, pal.marquee_fill, 0.14)
        g:fill_rect(rcx, rcy, rcw, rch)
      end
      if kb.w > 0 then
        local kcx, kcy, kcw, kch = clip_rect(kb.x, py1, kb.w, ppp, kb.x, kb.y, kb.w, kb.h)
        if kcx then
          set_rgb(g, pal.note_selected, 0.28)
          g:fill_rect(kcx, kcy, kcw, kch)
        end
      end
    end

    -- Original position ghost outlines for moved/resized selection
    if snaps and (dmode == "move" or dmode == "resize") then
      for i = 1, #snaps do
        local s = snaps[i]
        local tn = s.note
        if tn and (math.abs(tn.start_beat - s.start_beat) > 1e-6
                   or tn.pitch ~= s.pitch
                   or math.abs(tn.length - s.length) > 1e-6) then
          local ox1 = Layout.beat_to_px(self, layout, s.start_beat)
          local ox2 = ox1 + s.length * self.px_per_beat
          local oy1 = Layout.pitch_to_py(self, layout, s.pitch)
          local ocx, ocy, ocw, och = clip_rect(ox1 + 0.5, oy1 + 0.5, max(1, ox2 - ox1 - 1), max(1, ppp - 1),
                                               roll.x, roll.y, roll.w, roll.h)
          if ocx then
            set_rgb(g, pal.marquee_fill, 0.12)
            fill_rrect(g, ocx, ocy, ocw, och, 2.0)
            set_rgb(g, pal.marquee_border, 0.60)
            stroke_rrect(g, ocx, ocy, ocw, och, 2.0, 1.0)
          end
        end
      end
    end

    -- Bright active outer halo + tail resize grip on every edited note
    for i = 1, #targets do
      local tn = targets[i]
      local tx1 = Layout.beat_to_px(self, layout, tn.start_beat)
      local tx2 = tx1 + tn.length * self.px_per_beat
      local ty1 = Layout.pitch_to_py(self, layout, tn.pitch)
      local tcx, tcy, tcw, tch = clip_rect(tx1 + 0.5, ty1 + 0.5, max(1, tx2 - tx1 - 1), max(1, ppp - 1),
                                           roll.x, roll.y, roll.w, roll.h)
      if tcx then
        set_rgb(g, pal.marquee_border, 0.85)
        stroke_rrect(g, max(roll.x, tcx - 2), max(roll.y, tcy - 2), tcw + 4, tch + 4, 3.0, 1.8)
        set_rgb(g, { 255, 255, 255 }, 0.98)
        stroke_rrect(g, tcx, tcy, tcw, tch, 2.2, 1.2)
        if is_resizing and tx2 >= roll.x and tx2 <= roll.x + roll.w then
          set_rgb(g, { 255, 255, 255 }, 0.98)
          g:fill_rect(max(tcx, tcx + tcw - 3.0), tcy + 1, min(3.5, max(2, tcw)), max(1, tch - 2))
        end
      end
    end

    -- Inline floating edit callout beside primary dragged note
    local pnx1 = Layout.beat_to_px(self, layout, pri.start_beat)
    local pny1 = Layout.pitch_to_py(self, layout, pri.pitch)
    local tag_str
    if dmode == "move" and self.drag_orig_start and self.drag_orig_pitch then
      local db = pri.start_beat - self.drag_orig_start
      local dp = pri.pitch - self.drag_orig_pitch
      if abs(db) > 1e-4 or dp ~= 0 then
        local dp_str = (dp >= 0) and string.format("+%d", dp) or tostring(dp)
        tag_str = string.format("%s  %+.2fb (%s st)", Model.pitch_name(pri.pitch), db, dp_str)
      else
        tag_str = string.format("%s  %.2fb  %d sel", Model.pitch_name(pri.pitch), pri.start_beat, #targets)
      end
    elseif is_resizing then
      tag_str = string.format("Len %.2fb (%d sel)", pri.length, #targets)
    end
    if tag_str and pnx1 <= roll.x + roll.w - 40 then
      local tw = min(140, max(74, #tag_str * 6.2 + 12))
      local th = 16
      local tx = max(roll.x + 4, min(roll.x + roll.w - tw - 4, pnx1))
      local ty = (pny1 - th - 5 >= roll.y + 4) and (pny1 - th - 5) or min(roll.y + roll.h - th - 4, pny1 + ppp + 5)
      set_rgb(g, pal.hud_bg, 0.94)
      fill_rrect(g, tx, ty, tw, th, 3.5)
      set_rgb(g, pal.marquee_border, 0.90)
      stroke_rrect(g, tx, ty, tw, th, 3.5, 0.9)
      set_rgb(g, pal.hud_fg, 1.0)
      g:draw_text(tag_str, tx + tw * 0.5, ty + th * 0.5, tw - 6, 9.0, CENTER_ALIGN)
    end
  end

  -- 3. Playhead
  if self.show_playhead ~= false then
    local px = Layout.beat_to_px(self, layout, self.playhead_beat or 0.0)
    if px >= roll.x and px <= roll.x + roll.w then
      local top_y = (rl.h > 0) and rl.y or roll.y
      local bot_y = roll.y + roll.h

      -- Soft halo
      set_rgb(g, pal.playhead, 0.18)
      g:draw_line(px, top_y, px, bot_y, 4.0)

      -- Sharp line
      set_rgb(g, pal.playhead, 0.96)
      g:draw_line(px, top_y, px, bot_y, 1.5)

      -- Playhead triangle cap in ruler
      if rl.h >= 8 then
        local cw = 5.5
        local cap_h = min(9, rl.h - 3)
        local p = Path(px - cw, rl.y + 1)
        p:line_to(px + cw, rl.y + 1)
        p:line_to(px + cw, rl.y + cap_h * 0.45)
        p:line_to(px, rl.y + cap_h + 1)
        p:line_to(px - cw, rl.y + cap_h * 0.45)
        p:close()
        set_rgb(g, pal.playhead, 1.0)
        g:fill_path(p)
      end
    end
  end

  -- 4. Floating HUD badge during active drag / zoom / scrub
  if self.hud_text and self.hud_text ~= "" and roll.w >= 110 and roll.h >= 40 then
    local text = self.hud_text
    local hud_w = min(roll.w - 16, max(90, #text * 6.4 + 16))
    local hud_h = 18
    local hx = roll.x + roll.w - hud_w - 8
    local hy = roll.y + 8
    set_rgb(g, pal.hud_bg, 0.88)
    fill_rrect(g, hx, hy, hud_w, hud_h, 4)
    set_rgb(g, pal.hud_border, 0.85)
    stroke_rrect(g, hx, hy, hud_w, hud_h, 4, 0.9)
    set_rgb(g, pal.hud_fg, 1.0)
    g:draw_text(text, hx + hud_w * 0.5, hy + hud_h * 0.5, hud_w - 8, 10, CENTER_ALIGN)
  end

  local _ = h
end

return Render
