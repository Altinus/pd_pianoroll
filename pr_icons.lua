-- ============================================================================
-- pr_icons.lua — Cached Vector SVG Icon Library for NanoVG (g:draw_svg)
--   * Explicit #RRGGBB hex + fill-opacity / stroke-opacity (no <style>/currentColor)
--   * Memoized per (name, size, hex, alpha_q) for zero per-frame allocation
-- ============================================================================

local Icons = {}

local floor = math.floor
local max   = math.max
local min   = math.min

local svg_cache = {}

local function to_hex(rgb)
  local r = max(0, min(255, floor((rgb[1] or 220) + 0.5)))
  local g = max(0, min(255, floor((rgb[2] or 220) + 0.5)))
  local b = max(0, min(255, floor((rgb[3] or 220) + 0.5)))
  return string.format("#%02x%02x%02x", r, g, b)
end

-- All paths authored in normalized 14x14 coordinate space (viewBox="0 0 14 14").
-- NanoSVG honors fill-opacity / stroke-opacity separately from #RRGGBB hex.
local function build_body(name, c, a)
  if name == "play" then
    return string.format(
      '<path d="M4.2,2.5 L11.5,7 L4.2,11.5 Z" fill="%s" fill-opacity="%s"/>',
      c, a
    )
  elseif name == "pause" then
    return string.format(
      '<rect x="3.5" y="2.8" width="2.6" height="8.4" rx="0.6" fill="%s" fill-opacity="%s"/>' ..
      '<rect x="7.9" y="2.8" width="2.6" height="8.4" rx="0.6" fill="%s" fill-opacity="%s"/>',
      c, a, c, a
    )
  elseif name == "stop" then
    return string.format(
      '<rect x="3.4" y="3.4" width="7.2" height="7.2" rx="0.8" fill="%s" fill-opacity="%s"/>',
      c, a
    )
  elseif name == "loop" then
    return string.format(
      '<path d="M3.0,6.4 V5.0 A2.2,2.2 0 0 1 5.2,2.8 H10.2" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.45" stroke-linecap="round"/>' ..
      '<path d="M8.6,1.4 L11.2,2.8 L8.6,4.2 Z" fill="%s" fill-opacity="%s"/>' ..
      '<path d="M11.0,7.6 V9.0 A2.2,2.2 0 0 1 8.8,11.2 H3.8" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.45" stroke-linecap="round"/>' ..
      '<path d="M5.4,9.8 L2.8,11.2 L5.4,12.6 Z" fill="%s" fill-opacity="%s"/>',
      c, a, c, a, c, a, c, a
    )
  elseif name == "snap" then
    -- Classic DAW U-Magnet with distinct pole tips
    return string.format(
      '<path d="M3.8,4.6 V7.6 A3.2,3.2 0 0 0 10.2,7.6 V4.6" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.85" stroke-linecap="butt"/>' ..
      '<rect x="2.85" y="2.2" width="1.9" height="1.9" rx="0.35" fill="%s" fill-opacity="%s"/>' ..
      '<rect x="9.25" y="2.2" width="1.9" height="1.9" rx="0.35" fill="%s" fill-opacity="%s"/>',
      c, a, c, a, c, a
    )
  elseif name == "snap_abs" then
    -- Absolute grid: aligned columns + dot locked onto grid line
    return string.format(
      '<line x1="3.0" y1="2.4" x2="3.0" y2="11.6" stroke="%s" stroke-opacity="%s" stroke-width="1.2" stroke-linecap="round"/>' ..
      '<line x1="7.0" y1="2.4" x2="7.0" y2="11.6" stroke="%s" stroke-opacity="%s" stroke-width="1.2" stroke-linecap="round"/>' ..
      '<line x1="11.0" y1="2.4" x2="11.0" y2="11.6" stroke="%s" stroke-opacity="%s" stroke-width="1.2" stroke-linecap="round"/>' ..
      '<rect x="5.4" y="5.4" width="5.6" height="3.2" rx="0.8" fill="%s" fill-opacity="%s"/>',
      c, a, c, a, c, a, c, a
    )
  elseif name == "snap_rel" then
    -- Relative snap: grid reference + offset block + delta arrow
    return string.format(
      '<line x1="2.8" y1="2.4" x2="2.8" y2="11.6" stroke="%s" stroke-opacity="%s" stroke-width="1.2" stroke-linecap="round"/>' ..
      '<path d="M4.2,5.0 H9.8 M8.0,3.5 L10.0,5.0 L8.0,6.5" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.35" stroke-linecap="round" stroke-linejoin="round"/>' ..
      '<rect x="5.4" y="8.0" width="5.8" height="3.0" rx="0.8" fill="%s" fill-opacity="%s"/>',
      c, a, c, a, c, a
    )
  elseif name == "snap_adp" then
    -- Adaptive snap: progressively spaced grid lines scaling with zoom
    return string.format(
      '<line x1="2.4" y1="2.5" x2="2.4" y2="11.5" stroke="%s" stroke-opacity="%s" stroke-width="1.2" stroke-linecap="round"/>' ..
      '<line x1="4.5" y1="2.5" x2="4.5" y2="11.5" stroke="%s" stroke-opacity="%s" stroke-width="1.2" stroke-linecap="round"/>' ..
      '<line x1="7.5" y1="2.5" x2="7.5" y2="11.5" stroke="%s" stroke-opacity="%s" stroke-width="1.2" stroke-linecap="round"/>' ..
      '<line x1="11.4" y1="2.5" x2="11.4" y2="11.5" stroke="%s" stroke-opacity="%s" stroke-width="1.2" stroke-linecap="round"/>' ..
      '<path d="M2.2,9.2 L11.6,4.8" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.35" stroke-linecap="round"/>',
      c, a, c, a, c, a, c, a, c, a
    )
  elseif name == "snap_vis" then
    -- Visible grid lines snap: crisp eye icon
    return string.format(
      '<path d="M1.6,7.0 C3.8,3.3 10.2,3.3 12.4,7.0 C10.2,10.7 3.8,10.7 1.6,7.0 Z" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.35" stroke-linejoin="round"/>' ..
      '<circle cx="7.0" cy="7.0" r="1.9" fill="%s" fill-opacity="%s"/>',
      c, a, c, a
    )
  elseif name == "len_lst" then
    -- Last-Note Length mode: source note bar + inherit link to target note bar
    return string.format(
      '<rect x="2.2" y="2.6" width="6.2" height="2.8" rx="0.8" fill="%s" fill-opacity="%s"/>' ..
      '<path d="M3.8,5.6 V9.4 H5.4" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round"/>' ..
      '<rect x="5.6" y="8.0" width="6.2" height="2.8" rx="0.8" fill="%s" fill-opacity="%s"/>',
      c, a, c, a, c, a
    )
  elseif name == "len_grd" then
    -- Grid-Step Length mode: note framed squarely between two grid bars
    return string.format(
      '<line x1="3.0" y1="2.4" x2="3.0" y2="11.6" stroke="%s" stroke-opacity="%s" stroke-width="1.3" stroke-linecap="round"/>' ..
      '<line x1="11.0" y1="2.4" x2="11.0" y2="11.6" stroke="%s" stroke-opacity="%s" stroke-width="1.3" stroke-linecap="round"/>' ..
      '<rect x="4.0" y="5.2" width="6.0" height="3.6" rx="0.8" fill="%s" fill-opacity="%s"/>',
      c, a, c, a, c, a
    )
  elseif name == "len_fixed" then
    -- Fixed note length indicator
    return string.format(
      '<rect x="2.5" y="5.0" width="6.8" height="4.0" rx="0.9" fill="%s" fill-opacity="%s"/>' ..
      '<line x1="11.0" y1="3.0" x2="11.0" y2="11.0" stroke="%s" stroke-opacity="%s" stroke-width="1.4" stroke-linecap="round"/>',
      c, a, c, a
    )
  elseif name == "shift_dup" then
    -- FL-style Shift+Drag Duplicate: original note + stepped clone + '+' glyph
    return string.format(
      '<rect x="2.0" y="2.4" width="6.6" height="3.4" rx="0.9" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.3"/>' ..
      '<rect x="5.4" y="8.2" width="6.6" height="3.4" rx="0.9" fill="%s" fill-opacity="%s"/>' ..
      '<path d="M10.4,2.4 V5.6 M8.8,4.0 H12.0" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.35" stroke-linecap="round"/>',
      c, a, c, a, c, a
    )
  elseif name == "undo" then
    return string.format(
      '<path d="M4.6,4.8 H8.8 C10.6,4.8 11.7,5.9 11.7,7.6 C11.7,9.3 10.6,10.4 8.8,10.4 H4.2" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.5" stroke-linecap="round"/>' ..
      '<path d="M5.7,2.5 L2.7,4.8 L5.7,7.1 Z" fill="%s" fill-opacity="%s"/>',
      c, a, c, a
    )
  elseif name == "redo" then
    return string.format(
      '<path d="M9.4,4.8 H5.2 C3.4,4.8 2.3,5.9 2.3,7.6 C2.3,9.3 3.4,10.4 5.2,10.4 H9.8" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.5" stroke-linecap="round"/>' ..
      '<path d="M8.3,2.5 L11.3,4.8 L8.3,7.1 Z" fill="%s" fill-opacity="%s"/>',
      c, a, c, a
    )
  elseif name == "cut" then
    -- Scissors: crossed blades + finger loops
    return string.format(
      '<circle cx="4.2" cy="9.9" r="1.7" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.3"/>' ..
      '<circle cx="9.8" cy="9.9" r="1.7" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.3"/>' ..
      '<path d="M5.2,8.5 L10.3,2.5 M8.8,8.5 L3.7,2.5" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.35" stroke-linecap="round"/>',
      c, a, c, a, c, a
    )
  elseif name == "copy" then
    -- Overlapping documents
    return string.format(
      '<path d="M4.2,3.8 V2.4 H10.8 V9.2 H9.4" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/>' ..
      '<rect x="2.6" y="4.2" width="6.4" height="7.4" rx="0.9" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.35"/>',
      c, a, c, a
    )
  elseif name == "paste" then
    -- Clipboard with top clip + lines
    return string.format(
      '<rect x="3.0" y="3.0" width="8.0" height="8.8" rx="1.0" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.3"/>' ..
      '<rect x="5.1" y="1.8" width="3.8" height="2.0" rx="0.6" fill="%s" fill-opacity="%s"/>' ..
      '<path d="M5.0,6.4 H9.0 M5.0,8.7 H8.2" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.2" stroke-linecap="round"/>',
      c, a, c, a, c, a
    )
  elseif name == "fit" then
    -- Four outward corner frame brackets (Zoom Fit All)
    return string.format(
      '<path d="M2.3,5.2 V2.3 H5.2 M8.8,2.3 H11.7 V5.2 M11.7,8.8 V11.7 H8.8 M5.2,11.7 H2.3 V8.8" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.45" stroke-linecap="round" stroke-linejoin="round"/>' ..
      '<rect x="5.4" y="5.4" width="3.2" height="3.2" rx="0.5" fill="%s" fill-opacity="%s"/>',
      c, a, c, a
    )
  elseif name == "clr" then
    -- Trash can (clear pattern)
    return string.format(
      '<path d="M2.4,3.8 H11.6 M5.2,3.8 V2.4 H8.8 V3.8" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.35" stroke-linecap="round" stroke-linejoin="round"/>' ..
      '<path d="M3.6,3.8 L4.3,11.4 H9.7 L10.4,3.8" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.3" stroke-linejoin="round"/>' ..
      '<path d="M5.9,5.8 V9.6 M8.1,5.8 V9.6" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.15" stroke-linecap="round"/>',
      c, a, c, a, c, a
    )
  elseif name == "follow" then
    -- Playhead stem + cap triangle with chasing forward arrow
    return string.format(
      '<line x1="10.2" y1="3.4" x2="10.2" y2="12.0" stroke="%s" stroke-opacity="%s" stroke-width="1.35" stroke-linecap="round"/>' ..
      '<path d="M8.1,2.0 L12.3,2.0 L10.2,4.4 Z" fill="%s" fill-opacity="%s"/>' ..
      '<path d="M2.0,7.8 H7.2 M5.4,5.7 L7.6,7.8 L5.4,9.9" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/>',
      c, a, c, a, c, a
    )
  elseif name == "ret_start" then
    -- Return-to-start anchor line with left return arrow
    return string.format(
      '<line x1="2.8" y1="2.6" x2="2.8" y2="11.4" stroke="%s" stroke-opacity="%s" stroke-width="1.5" stroke-linecap="round"/>' ..
      '<path d="M11.2,4.4 V7.4 H5.4" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.45" stroke-linecap="round" stroke-linejoin="round"/>' ..
      '<path d="M6.8,5.1 L3.9,7.4 L6.8,9.7 Z" fill="%s" fill-opacity="%s"/>',
      c, a, c, a, c, a
    )
  elseif name == "time_stretch" then
    -- Horizontal left/right double arrow for group time-stretch handle
    return string.format(
      '<path d="M4.2,7.0 H9.8" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.5" stroke-linecap="round"/>' ..
      '<path d="M5.2,4.1 L1.8,7.0 L5.2,9.9 Z" fill="%s" fill-opacity="%s"/>' ..
      '<path d="M8.8,4.1 L12.2,7.0 L8.8,9.9 Z" fill="%s" fill-opacity="%s"/>',
      c, a, c, a, c, a
    )
  elseif name == "reset" then
    -- Circular view reset arrow around center anchor dot
    return string.format(
      '<path d="M10.8,5.8 A4.2,4.2 0 1 0 10.6,9.0" fill="none" stroke="%s" stroke-opacity="%s" stroke-width="1.45" stroke-linecap="round"/>' ..
      '<path d="M11.8,3.2 L11.4,6.4 L8.4,5.6 Z" fill="%s" fill-opacity="%s"/>' ..
      '<circle cx="7.0" cy="7.0" r="1.4" fill="%s" fill-opacity="%s"/>',
      c, a, c, a, c, a
    )
  end

  return string.format('<circle cx="7.0" cy="7.0" r="3.0" fill="%s" fill-opacity="%s"/>', c, a)
end

function Icons.get_svg(name, size, rgb, alpha)
  local sz = floor((size or 14) + 0.5)
  local c = to_hex(rgb)
  local aq = floor(max(0.0, min(1.0, alpha or 1.0)) * 20 + 0.5) / 20.0
  local a_str = string.format("%.2f", aq)
  local key = name .. ":" .. tostring(sz) .. ":" .. c .. ":" .. a_str
  local cached = svg_cache[key]
  if cached then return cached end

  local body = build_body(name, c, a_str)
  local xml = string.format(
    '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 14 14">%s</svg>',
    sz, sz, body
  )
  svg_cache[key] = xml
  return xml
end

function Icons.draw(g, name, r, rgb, alpha, max_sz)
  if not r or r.w <= 0 or r.h <= 0 then return end
  local cap = max_sz or 14
  local sz = floor(max(8, min(cap, r.w - 4, r.h - 4)))
  local svg = Icons.get_svg(name, sz, rgb, alpha)
  local x = r.x + (r.w - sz) * 0.5
  local y = r.y + (r.h - sz) * 0.5
  g:draw_svg(svg, x, y)
end

return Icons
