-- ============================================================================
-- pr_theme.lua — Stateless Theme & Color Palette Engine for Piano Roll
-- Follows plugdata's dynamic ObjectThemeManager (pd.bg_color / fg_color / sel_color)
-- while supporting Dark / Light / Custom overrides and user-customizable colors.
-- ============================================================================

local Theme = {}

local floor = math.floor
local max   = math.max
local min   = math.min

local function clamp_byte(v)
  v = floor((tonumber(v) or 0) + 0.5)
  if v < 0 then return 0 end
  if v > 255 then return 255 end
  return v
end

local function normalize_rgb(c, dr, dg, db)
  if type(c) == "table" and type(c[1]) == "number" then
    return {
      clamp_byte(c[1]),
      clamp_byte(c[2] or c[1]),
      clamp_byte(c[3] or c[1]),
    }
  end
  return { dr, dg, db }
end

local function mix(a, b, t)
  local u = 1.0 - t
  return {
    clamp_byte(a[1] * u + b[1] * t),
    clamp_byte(a[2] * u + b[2] * t),
    clamp_byte(a[3] * u + b[3] * t),
  }
end

local function shift_lum(c, delta)
  return {
    clamp_byte(c[1] + delta),
    clamp_byte(c[2] + delta),
    clamp_byte(c[3] + delta),
  }
end

local function luminance(c)
  return 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3]
end

local function read_host_colors()
  local raw_bg  = pd and pd.bg_color and pd.bg_color()
  local raw_fg  = pd and pd.fg_color and pd.fg_color()
  local fn_sel  = pd and rawget(pd, "sel_color")
  local raw_sel = (type(fn_sel) == "function") and fn_sel() or nil

  local has_host_bg = (type(raw_bg) == "table" and type(raw_bg[1]) == "number")
  local has_host_fg = (type(raw_fg) == "table" and type(raw_fg[1]) == "number")

  local bg  = has_host_bg and normalize_rgb(raw_bg, 35, 37, 42) or { 35, 37, 42 }
  local fg  = has_host_fg and normalize_rgb(raw_fg, 224, 227, 232) or { 224, 227, 232 }
  local sel = normalize_rgb(raw_sel, 78, 201, 176)
  return bg, fg, sel
end

function Theme.clamp_rgb(c, fallback)
  local fb = fallback or { 78, 201, 176 }
  return normalize_rgb(c, fb[1], fb[2], fb[3])
end

function Theme.scale_rgb(c, factor)
  return {
    clamp_byte(c[1] * factor),
    clamp_byte(c[2] * factor),
    clamp_byte(c[3] * factor),
  }
end

function Theme.contrast_text(c)
  return (luminance(c) > 145) and { 20, 22, 26 } or { 248, 250, 252 }
end

function Theme.resolve(self)
  local host_bg, host_fg, host_sel = read_host_colors()
  local mode = self.theme_mode or 1

  -- Check cache key so we don't rebuild palette every frame unless colors/mode changed
  local nc = normalize_rgb(self.note_color, 78, 201, 176)
  local sc = normalize_rgb(self.selected_color, 255, 198, 92)
  local pc = normalize_rgb(self.playhead_color, 255, 92, 92)
  local lc = normalize_rgb(self.loop_color, 96, 175, 255)
  local gc = normalize_rgb(self.grid_color, 96, 102, 114)
  local g_con = max(0.25, min(2.0, tonumber(self.grid_contrast) or 1.0))
  local cb = normalize_rgb(self.custom_bg_color, 34, 36, 42)

  local sig = string.format(
    "%d:%d,%d,%d:%d,%d,%d:%d,%d,%d:%d,%d,%d:%d,%d,%d:%d,%d,%d:%d,%d,%d:%.3f:%d,%d,%d",
    mode,
    host_bg[1], host_bg[2], host_bg[3],
    host_fg[1], host_fg[2], host_fg[3],
    nc[1], nc[2], nc[3],
    sc[1], sc[2], sc[3],
    pc[1], pc[2], pc[3],
    lc[1], lc[2], lc[3],
    gc[1], gc[2], gc[3],
    g_con,
    cb[1], cb[2], cb[3]
  )

  if self._palette and self._palette_sig == sig then
    return self._palette
  end

  local bg, fg
  if mode == 2 then
    -- Dark studio theme
    bg = { 32, 34, 39 }
    fg = { 226, 229, 235 }
  elseif mode == 3 then
    -- Light studio theme
    bg = { 235, 237, 241 }
    fg = { 34, 37, 44 }
  elseif mode == 4 then
    -- Custom base background
    bg = cb
    local is_l = (luminance(bg) > 128)
    fg = is_l and { 28, 30, 36 } or { 228, 232, 238 }
  else
    -- Auto (Plugdata host theme)
    bg = host_bg
    fg = host_fg
  end

  local lum = luminance(bg)
  local is_light = (lum > 128)

  local roll_white = is_light and shift_lum(bg, 6) or shift_lum(bg, -4)
  local roll_black = is_light and mix(bg, fg, 0.08) or shift_lum(bg, -11)

  local pal = {
    is_light          = is_light,
    bg                = bg,
    fg                = fg,
    host_sel          = host_sel,
    border            = mix(bg, fg, is_light and 0.24 or 0.20),

    -- Chrome: Toolbar & Ruler
    toolbar_bg        = is_light and mix(bg, fg, 0.06) or shift_lum(bg, 8),
    toolbar_border    = mix(bg, fg, 0.16),
    toolbar_btn       = is_light and mix(bg, fg, 0.10) or shift_lum(bg, 16),
    toolbar_btn_hover = is_light and mix(bg, fg, 0.18) or shift_lum(bg, 26),
    toolbar_btn_on    = nc,
    toolbar_text      = fg,
    toolbar_muted     = mix(bg, fg, 0.55),
    toolbar_sep       = mix(bg, fg, 0.16),

    ruler_bg          = is_light and mix(bg, fg, 0.04) or shift_lum(bg, 2),
    ruler_border      = mix(bg, fg, 0.18),
    ruler_tick_major  = mix(bg, fg, 0.50),
    ruler_tick_minor  = mix(bg, fg, 0.22),
    ruler_text        = mix(bg, fg, 0.78),

    -- Roll grid (alpha-blended from customizable grid_color so contrast deepens uniformly on white & black rows)
    roll_white_row    = roll_white,
    roll_black_row    = roll_black,
    grid_color        = gc,
    grid_row_line     = gc,
    grid_row_a        = min(0.92, max(0.06, 0.28 * g_con)),
    grid_octave       = gc,
    grid_octave_a     = min(1.00, max(0.16, 0.68 * g_con)),
    grid_bar          = gc,
    grid_bar_a        = min(1.00, max(0.22, 0.86 * g_con)),
    grid_beat         = gc,
    grid_beat_a       = min(0.96, max(0.12, 0.54 * g_con)),
    grid_sub          = gc,
    grid_sub_a        = min(0.90, max(0.08, 0.34 * g_con)),
    seq_end           = { 215, 95, 95 },

    -- Piano keyboard
    key_white         = is_light and { 246, 247, 250 } or { 218, 221, 228 },
    key_white_alt     = is_light and { 238, 240, 245 } or { 206, 210, 218 },
    key_white_border  = is_light and { 188, 192, 200 } or { 125, 130, 140 },
    key_black         = is_light and { 52, 55, 64 } or { 28, 30, 36 },
    key_black_hi      = is_light and { 78, 82, 94 } or { 48, 52, 62 },
    key_text          = is_light and { 75, 80, 92 } or { 58, 62, 72 },
    key_hover         = mix(nc, { 255, 255, 255 }, 0.25),
    key_active        = nc,

    -- Notes
    note_fill         = nc,
    note_border       = is_light and Theme.scale_rgb(nc, 0.65) or mix(nc, { 255, 255, 255 }, 0.25),
    note_selected     = sc,
    note_active       = mix(nc, { 255, 255, 255 }, 0.42),
    note_text         = Theme.contrast_text(nc),

    -- Overlays
    playhead          = pc,
    loop_fill         = lc,
    loop_border       = mix(lc, { 255, 255, 255 }, 0.20),
    marquee_fill      = lc,
    marquee_border    = mix(lc, { 255, 255, 255 }, 0.35),

    -- Scrollbars & zoom grips
    scroll_track      = is_light and mix(bg, fg, 0.09) or shift_lum(bg, -8),
    scroll_thumb      = mix(bg, fg, is_light and 0.32 or 0.28),
    scroll_thumb_hi   = mix(bg, fg, is_light and 0.48 or 0.44),
    zoom_grip_bg      = is_light and mix(bg, fg, 0.14) or shift_lum(bg, 10),
    zoom_grip_hover   = is_light and mix(bg, fg, 0.24) or shift_lum(bg, 22),
    zoom_grip_fg      = mix(bg, fg, 0.80),

    -- Live HUD
    hud_bg            = is_light and { 250, 251, 254 } or { 22, 24, 29 },
    hud_fg            = is_light and { 24, 26, 32 } or { 240, 244, 250 },
    hud_border        = nc,
  }

  self._palette = pal
  self._palette_sig = sig
  return pal
end

return Theme
