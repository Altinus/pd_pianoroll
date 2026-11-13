-- ============================================================================
-- pr_model.lua — Stateless Data Model, Snap/Grid Engine, Event Compiler & Voices
-- ============================================================================

local Layout = require("pr_layout")

local Model = {}

local floor = math.floor
local ceil  = math.ceil
local abs   = math.abs
local max   = math.max
local min   = math.min
local sort  = table.sort

-- LuaJIT FFI availability for zero-overhead contiguous C voice counters
local has_ffi, ffi = pcall(require, "ffi")
local use_ffi = (type(jit) == "table") and has_ffi and (ffi ~= nil)

-- Precomputed pitch lookup tables (0..127) -> zero allocation during render
local NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }
local PITCH_LABELS = {}
local BLACK_PITCH = {}
for p = 0, 127 do
  local pc = p % 12
  local oct = floor(p / 12) - 1
  PITCH_LABELS[p] = NOTE_NAMES[pc + 1] .. tostring(oct)
  BLACK_PITCH[p] = (pc == 1 or pc == 3 or pc == 6 or pc == 8 or pc == 10)
end

Model.PITCH_LABELS = PITCH_LABELS
Model.BLACK_PITCH  = BLACK_PITCH

-- Grid divisions (1-based combo indices)
Model.GRID_DIVS = {
  { label = "1/1",   beats = 0.0,        is_bar = true },
  { label = "1/2",   beats = 2.0 },
  { label = "1/4",   beats = 1.0 },
  { label = "1/8",   beats = 0.5 },
  { label = "1/16",  beats = 0.25 },
  { label = "1/32",  beats = 0.125 },
  { label = "1/4T",  beats = 2.0 / 3.0 },
  { label = "1/8T",  beats = 1.0 / 3.0 },
  { label = "1/16T", beats = 1.0 / 6.0 },
}

Model.GRID_LABELS = {}
for i = 1, #Model.GRID_DIVS do
  Model.GRID_LABELS[i] = Model.GRID_DIVS[i].label
end

-- Snap modes (1-based combo indices)
Model.SNAP_MODES = {
  { label = "Absolute Grid",      short = "ABS" },
  { label = "Relative Offset",    short = "REL" },
  { label = "Adaptive",           short = "ADP" },
  { label = "Visible Grid Lines", short = "VIS" },
}

Model.SNAP_MODE_LABELS = {}
for i = 1, #Model.SNAP_MODES do
  Model.SNAP_MODE_LABELS[i] = Model.SNAP_MODES[i].label
end

-- Default new-note length modes (1-based combo indices; Mode 1 follows last touched note)
Model.DEF_LEN_MODES = {
  "Last Note",
  "Grid Step",
  "1/4 Beat",
  "1/2 Beat",
  "1 Beat",
}

function Model.pitch_name(p)
  return PITCH_LABELS[p] or "?"
end

function Model.is_black_key(p)
  return BLACK_PITCH[p] == true
end

function Model.init_voices(self)
  if use_ffi then
    self.voice_counts = ffi.new("uint16_t[128]")
    self.voice_vels   = ffi.new("uint8_t[128]")
  else
    local vc, vv = {}, {}
    for p = 0, 127 do
      vc[p] = 0
      vv[p] = 0
    end
    self.voice_counts = vc
    self.voice_vels   = vv
  end
  self.active_note_ids = {}
  self.audition_pitch  = nil
  self._sorted_pitches = {}
  self._sorted_vels    = {}
end

function Model.get_base_grid_step(self)
  local idx = self.grid_div_idx or 5
  local div = Model.GRID_DIVS[idx] or Model.GRID_DIVS[5]
  if div.is_bar then
    return max(1.0, self.timesig_num or 4)
  end
  return div.beats
end

-- Visual grid density thresholds (minimum pixels between consecutive grid lines)
Model.MIN_SUB_GRID_PX   = 4.5
Model.MIN_MAJOR_GRID_PX = 6.0

local function coarsen_step(step, ppb, tsig, min_sub_px, min_major_px)
  local guard = 0
  while guard < 16 do
    local limit = (step < 1.0 - 1e-4) and min_sub_px or min_major_px
    if step * ppb >= limit or step >= 256.0 then
      break
    end
    guard = guard + 1
    if step < 0.99 then
      local nxt = step * 2.0
      -- Snap triplet coarsening cleanly onto beat boundary (1.0) once past 1/4T (2/3 beat)
      if abs(step - 2.0 / 3.0) < 0.02 then
        nxt = 1.0
      elseif nxt > 0.7 and nxt < 1.0 then
        nxt = 1.0
      end
      step = nxt
    elseif step < tsig - 0.01 then
      local half_bar = (tsig >= 4 and (tsig % 2 == 0)) and (tsig * 0.5) or tsig
      if step < half_bar - 0.01 then
        step = half_bar
      else
        step = tsig
      end
    else
      step = step * 2.0
    end
  end
  return step
end

function Model.get_draw_grid_step(self)
  local sm   = self.snap_mode or 1
  local ppb  = self.px_per_beat or Layout.DEF_PPB
  local tsig = max(1, self.timesig_num or 4)
  local step = Model.get_base_grid_step(self)
  if sm == 3 then
    -- Adaptive: also allow finer subdivisions when zoomed far in
    local min_step = 0.0625
    while step * ppb > 96.0 and step > min_step do
      step = step * 0.5
    end
  end
  return coarsen_step(step, ppb, tsig, Model.MIN_SUB_GRID_PX, Model.MIN_MAJOR_GRID_PX)
end

function Model.get_grid_step(self)
  local sm = self.snap_mode or 1
  if sm == 3 or sm == 4 then
    return Model.get_draw_grid_step(self)
  end
  return Model.get_base_grid_step(self)
end

function Model.get_default_note_length(self)
  local mode = self.default_len_mode or 1
  if mode == 1 then
    if self.last_note_len and self.last_note_len > 0 then
      return max(0.03125, self.last_note_len)
    end
    return Model.get_grid_step(self)
  end
  if mode == 2 then return Model.get_grid_step(self) end
  if mode == 3 then return 0.25 end
  if mode == 4 then return 0.5 end
  if mode == 5 then return 1.0 end
  return Model.get_grid_step(self)
end

function Model.describe_len_mode(self)
  local m = self.default_len_mode or 1
  if m == 1 then return "L:LST" end
  if m == 2 then return "L:GRD" end
  if m == 3 then return "L:1/4" end
  if m == 4 then return "L:1/2" end
  if m == 5 then return "L:1B" end
  return "L:LST"
end

function Model.snap_floor(self, beat)
  if not self.snap_enabled then return max(0.0, beat) end
  local step = Model.get_grid_step(self)
  return max(0.0, floor(beat / step + 1e-9) * step)
end

function Model.snap_round(self, beat)
  if not self.snap_enabled then return max(0.0, beat) end
  local step = Model.get_grid_step(self)
  return max(0.0, floor(beat / step + 0.5) * step)
end

function Model.snap_delta(self, dbeat)
  if not self.snap_enabled then return dbeat end
  local step = Model.get_grid_step(self)
  return floor(dbeat / step + 0.5) * step
end

function Model.find_note_by_id(self, id)
  if not id then return nil, nil end
  local notes = self.notes
  for i = 1, #notes do
    if notes[i].id == id then
      return notes[i], i
    end
  end
  return nil, nil
end

function Model.is_selected(self, id)
  return self.selected_ids and self.selected_ids[id] == true
end

function Model.select_only(self, id)
  local sel = {}
  if id then sel[id] = true end
  self.selected_ids = sel
  self.primary_sel_id = id
end

function Model.toggle_select(self, id)
  if not id then return end
  if not self.selected_ids then self.selected_ids = {} end
  if self.selected_ids[id] then
    self.selected_ids[id] = nil
    if self.primary_sel_id == id then
      self.primary_sel_id = next(self.selected_ids)
    end
  else
    self.selected_ids[id] = true
    self.primary_sel_id = id
  end
end

function Model.clear_selection(self)
  self.selected_ids = {}
  self.primary_sel_id = nil
end

function Model.select_all(self)
  local sel = {}
  local notes = self.notes
  for i = 1, #notes do
    sel[notes[i].id] = true
  end
  self.selected_ids = sel
  self.primary_sel_id = notes[1] and notes[1].id or nil
end

function Model.count_selected(self)
  local c = 0
  local sel = self.selected_ids
  if not sel then return 0 end
  local notes = self.notes
  for i = 1, #notes do
    if sel[notes[i].id] then c = c + 1 end
  end
  return c
end

function Model.get_selected_notes(self)
  local out = {}
  local sel = self.selected_ids
  if not sel then return out end
  local notes = self.notes
  for i = 1, #notes do
    if sel[notes[i].id] then
      out[#out + 1] = notes[i]
    end
  end
  return out
end

function Model.recompute_max_end(self)
  local max_end = 0.0
  local notes = self.notes
  for i = 1, #notes do
    local e = notes[i].start_beat + notes[i].length
    if e > max_end then max_end = e end
  end
  self.max_end_beat = max_end
  return max_end
end

function Model.add_note(self, pitch, start_beat, length, velocity, channel, track)
  pitch      = max(0, min(127, floor((tonumber(pitch) or 60) + 0.5)))
  start_beat = max(0.0, tonumber(start_beat) or 0.0)
  length     = max(0.03125, tonumber(length) or Model.get_default_note_length(self))
  velocity   = max(1, min(127, floor((tonumber(velocity) or self.default_vel or 100) + 0.5)))

  local note = {
    id         = self.next_id,
    pitch      = pitch,
    start_beat = start_beat,
    length     = length,
    velocity   = velocity,
    channel    = channel,
    track      = track,
  }
  self.next_id = self.next_id + 1
  local notes = self.notes
  notes[#notes + 1] = note
  if start_beat + length > (self.max_end_beat or 0) then
    self.max_end_beat = start_beat + length
  end
  self.events_dirty = true
  return note
end

function Model.remove_note(self, note)
  if not note then return false end
  local notes = self.notes
  for i = #notes, 1, -1 do
    if notes[i] == note then
      table.remove(notes, i)
      if self.selected_ids then self.selected_ids[note.id] = nil end
      if self.primary_sel_id == note.id then
        self.primary_sel_id = self.selected_ids and next(self.selected_ids) or nil
      end
      Model.recompute_max_end(self)
      self.events_dirty = true
      return true
    end
  end
  return false
end

function Model.remove_selected(self)
  local sel = self.selected_ids
  if not sel then return {} end
  local removed = {}
  local notes = self.notes
  for i = #notes, 1, -1 do
    local note = notes[i]
    if sel[note.id] then
      removed[#removed + 1] = note
      table.remove(notes, i)
    end
  end
  if #removed > 0 then
    self.selected_ids = {}
    self.primary_sel_id = nil
    Model.recompute_max_end(self)
    self.events_dirty = true
  end
  return removed
end

function Model.clear_notes(self)
  self.notes = {}
  self.selected_ids = {}
  self.primary_sel_id = nil
  self.max_end_beat = 0.0
  self.events = {}
  self.event_cursor = 1
  self.events_dirty = false
end

function Model.transpose_selected(self, semitones)
  semitones = floor((tonumber(semitones) or 0) + 0.5)
  if semitones == 0 then return false end
  local targets = Model.get_selected_notes(self)
  if #targets == 0 then targets = self.notes end
  if #targets == 0 then return false end
  for i = 1, #targets do
    local n = targets[i]
    n.pitch = max(0, min(127, n.pitch + semitones))
  end
  self.events_dirty = true
  return true
end

function Model.quantize_notes(self, strength)
  strength = max(0.0, min(1.0, tonumber(strength) or 1.0))
  local step = Model.get_grid_step(self)
  local targets = Model.get_selected_notes(self)
  if #targets == 0 then targets = self.notes end
  if #targets == 0 then return false end
  for i = 1, #targets do
    local n = targets[i]
    local q_start = floor(n.start_beat / step + 0.5) * step
    n.start_beat = max(0.0, n.start_beat + (q_start - n.start_beat) * strength)
  end
  Model.recompute_max_end(self)
  self.events_dirty = true
  return true
end

function Model.hit_test_px(self, layout, x, y)
  local notes = self.notes
  local n = #notes
  if n == 0 then return nil, false end

  local ppb = self.px_per_beat
  local ppp = self.px_per_pitch
  local rx = layout.roll.x
  local ry = layout.roll.y
  local vb = self.view_beat
  local vt = self.view_pitch_top

  for i = n, 1, -1 do
    local note = notes[i]
    local y1 = ry + (vt - note.pitch) * ppp
    local y2 = y1 + ppp
    if y >= y1 and y < y2 then
      local x1 = rx + (note.start_beat - vb) * ppb
      local x2 = x1 + note.length * ppb
      local bw = x2 - x1
      local tail_inner = (bw >= 12) and 7.0 or (bw * 0.35)
      local tail_outer = 4.0
      if x >= x1 and x <= x2 + tail_outer then
        local is_tail = (x >= x2 - tail_inner)
        return note, is_tail
      end
    end
  end
  return nil, false
end

function Model.rebuild_events(self)
  local ev = {}
  local notes = self.notes
  local n = #notes
  local max_end = 0.0

  for i = 1, n do
    local note = notes[i]
    local sb = note.start_beat
    local eb = sb + note.length
    ev[#ev + 1] = { time = sb, kind = 1, pitch = note.pitch, vel = note.velocity, id = note.id }
    ev[#ev + 1] = { time = eb, kind = 0, pitch = note.pitch, vel = 0,             id = note.id }
    if eb > max_end then max_end = eb end
  end

  sort(ev, function(a, b)
    if a.time ~= b.time then return a.time < b.time end
    if a.kind ~= b.kind then return a.kind < b.kind end -- noteoff (0) before noteon (1)
    return a.pitch < b.pitch
  end)

  self.events       = ev
  self.event_cursor = 1
  self.events_dirty = false
  self.max_end_beat = max_end
end

function Model.collect_sorted_active_pitches(self)
  local vc = self.voice_counts
  local vv = self.voice_vels
  local p_out = self._sorted_pitches
  local v_out = self._sorted_vels
  local k = 0
  for p = 0, 127 do
    if vc[p] > 0 then
      k = k + 1
      p_out[k] = p
      v_out[k] = vv[p]
    end
  end
  for i = k + 1, #p_out do
    p_out[i] = nil
    v_out[i] = nil
  end
  return p_out, v_out, k
end

function Model.serialize_notes(self)
  local notes = self.notes
  local atoms = {}
  local k = 0
  for i = 1, #notes do
    local n = notes[i]
    atoms[k + 1] = n.pitch
    atoms[k + 2] = n.start_beat
    atoms[k + 3] = n.length
    atoms[k + 4] = n.velocity
    k = k + 4
  end
  return atoms
end

function Model.note_count_string(self)
  local n = #self.notes
  local s = Model.count_selected(self)
  if s > 0 then
    return string.format("%d notes (%d sel)", n, s)
  end
  return string.format("%d notes", n)
end

function Model.format_beat_pos(self, beat)
  local tsig = max(1, self.timesig_num or 4)
  local bar = floor(beat / tsig) + 1
  local rem = beat - (bar - 1) * tsig
  local b_in_bar = floor(rem) + 1
  local frac = floor((rem - floor(rem)) * 4) + 1
  return string.format("%d.%d.%d", bar, b_in_bar, frac)
end

-- Check intersection between a note and a beat/pitch marquee box
function Model.select_in_box(self, b_min, b_max, p_min, p_max, additive)
  local sel = additive and (self.selected_ids or {}) or {}
  local notes = self.notes
  local first_id = nil
  for i = 1, #notes do
    local n = notes[i]
    local n_end = n.start_beat + n.length
    if n.pitch >= p_min and n.pitch <= p_max
       and n_end >= b_min and n.start_beat <= b_max then
      sel[n.id] = true
      if not first_id then first_id = n.id end
    end
  end
  self.selected_ids = sel
  self.primary_sel_id = first_id or next(sel)
end

function Model.describe_grid(self)
  local div = Model.GRID_DIVS[self.grid_div_idx or 5] or Model.GRID_DIVS[5]
  return div.label
end

function Model.describe_snap_mode(self)
  local sm = Model.SNAP_MODES[self.snap_mode or 1] or Model.SNAP_MODES[1]
  return sm.short
end

function Model.is_empty_note_check(val)
  return abs(val) < 1e-9
end

-- ============================================================================
-- Undo / Redo History Pool (Bounded Deep Snapshot Stack)
-- ============================================================================

Model.MAX_UNDO = 64

function Model.init_history(self)
  self.undo_stack = {}
  self.redo_stack = {}
end

local function clone_notes_list(notes)
  local out = {}
  if not notes then return out end
  for i = 1, #notes do
    local n = notes[i]
    out[i] = {
      pitch      = n.pitch,
      start_beat = n.start_beat,
      length     = n.length,
      velocity   = n.velocity,
      id         = n.id,
      channel    = n.channel,
      track      = n.track,
    }
  end
  return out
end

local function clone_midi_tracks(tracks)
  if not tracks then return nil end
  local out = {}
  for i = 1, #tracks do
    local t = tracks[i]
    out[i] = {
      raw_idx    = t.raw_idx,
      ordinal    = t.ordinal,
      name       = t.name,
      notes      = clone_notes_list(t.notes),
      note_count = t.note_count,
    }
  end
  return out
end

local function clone_sel_set(sel)
  local out = {}
  if not sel then return out end
  for k, v in pairs(sel) do
    if v then out[k] = true end
  end
  return out
end

function Model.capture_snapshot(self)
  return {
    notes          = clone_notes_list(self.notes),
    selected_ids   = clone_sel_set(self.selected_ids),
    primary_sel_id = self.primary_sel_id,
    last_note_len  = self.last_note_len,
    midi_tracks    = clone_midi_tracks(self.midi_tracks),
    midi_track_idx = self.midi_track_idx or 0,
  }
end

function Model.snapshots_equal(a, b)
  if not a or not b then return false end
  if (a.midi_track_idx or 0) ~= (b.midi_track_idx or 0) then return false end
  local na, nb = a.notes, b.notes
  if #na ~= #nb then return false end
  for i = 1, #na do
    local x, y = na[i], nb[i]
    if x.id ~= y.id
       or x.pitch ~= y.pitch
       or abs(x.start_beat - y.start_beat) > 1e-9
       or abs(x.length - y.length) > 1e-9
       or x.velocity ~= y.velocity then
      return false
    end
  end
  return true
end

local function restore_snapshot(self, snap)
  self.notes          = clone_notes_list(snap.notes)
  self.selected_ids   = clone_sel_set(snap.selected_ids)
  self.primary_sel_id = snap.primary_sel_id
  self.midi_tracks    = clone_midi_tracks(snap.midi_tracks)
  self.midi_track_idx = snap.midi_track_idx or 0
  if snap.last_note_len and snap.last_note_len > 0 then
    self.last_note_len = snap.last_note_len
  end
  local max_id = 0
  for i = 1, #self.notes do
    local id = self.notes[i].id or 0
    if id > max_id then max_id = id end
  end
  if max_id >= (self.next_id or 1) then
    self.next_id = max_id + 1
  end
  Model.recompute_max_end(self)
  self.events_dirty = true
end

function Model.push_undo(self, pre_snap)
  if not self.undo_stack then self.undo_stack = {} end
  if not self.redo_stack then self.redo_stack = {} end
  local snap = pre_snap or Model.capture_snapshot(self)
  local stack = self.undo_stack
  if #stack > 0 and Model.snapshots_equal(stack[#stack], snap) then
    return false
  end
  stack[#stack + 1] = snap
  if #stack > Model.MAX_UNDO then
    table.remove(stack, 1)
  end
  self.redo_stack = {}
  return true
end

function Model.can_undo(self)
  return self.undo_stack and #self.undo_stack > 0
end

function Model.can_redo(self)
  return self.redo_stack and #self.redo_stack > 0
end

function Model.undo(self)
  if not Model.can_undo(self) then return false end
  local cur = Model.capture_snapshot(self)
  local target = table.remove(self.undo_stack)
  if not self.redo_stack then self.redo_stack = {} end
  self.redo_stack[#self.redo_stack + 1] = cur
  if #self.redo_stack > Model.MAX_UNDO then
    table.remove(self.redo_stack, 1)
  end
  restore_snapshot(self, target)
  return true
end

function Model.redo(self)
  if not Model.can_redo(self) then return false end
  local cur = Model.capture_snapshot(self)
  local target = table.remove(self.redo_stack)
  if not self.undo_stack then self.undo_stack = {} end
  self.undo_stack[#self.undo_stack + 1] = cur
  if #self.undo_stack > Model.MAX_UNDO then
    table.remove(self.undo_stack, 1)
  end
  restore_snapshot(self, target)
  return true
end

-- ============================================================================
-- Clipboard (Copy / Cut / Paste / Duplicate across selections & instances)
-- ============================================================================

local SHARED_CLIPBOARD = nil

function Model.has_clipboard(self)
  local cb = SHARED_CLIPBOARD or (self and self.clipboard)
  return cb ~= nil and cb.items ~= nil and #cb.items > 0
end

function Model.copy_selected(self)
  local sel = Model.get_selected_notes(self)
  local n = #sel
  if n == 0 then return 0 end

  sort(sel, function(a, b)
    if a.start_beat ~= b.start_beat then return a.start_beat < b.start_beat end
    if a.pitch ~= b.pitch then return a.pitch < b.pitch end
    return (a.id or 0) < (b.id or 0)
  end)

  local min_start = sel[1].start_beat
  local max_end   = sel[1].start_beat + sel[1].length
  for i = 2, n do
    if sel[i].start_beat < min_start then min_start = sel[i].start_beat end
    local e = sel[i].start_beat + sel[i].length
    if e > max_end then max_end = e end
  end

  local items = {}
  for i = 1, n do
    local s = sel[i]
    items[i] = {
      pitch    = s.pitch,
      rel_beat = s.start_beat - min_start,
      length   = s.length,
      velocity = s.velocity,
    }
  end

  local step = max(0.0625, Model.get_grid_step(self))
  local raw_span = max(0.0625, max_end - min_start)
  local aligned_span = self.snap_enabled
    and max(step, ceil(raw_span / step - 1e-6) * step)
    or raw_span

  local cb = {
    items          = items,
    base_beat      = min_start,
    span           = aligned_span,
    copy_playhead  = self.playhead_beat or 0.0,
    paste_playhead = self.playhead_beat or 0.0,
    paste_count    = 0,
    last_paste_end = nil,
    is_cut         = false,
  }
  SHARED_CLIPBOARD = cb
  self.clipboard   = cb
  return n
end

function Model.cut_selected(self)
  local count = Model.copy_selected(self)
  if count == 0 then return {} end
  local cb = SHARED_CLIPBOARD or self.clipboard
  if cb then cb.is_cut = true end
  Model.push_undo(self)
  return Model.remove_selected(self)
end

function Model.paste_clipboard(self, target_beat)
  local cb = SHARED_CLIPBOARD or self.clipboard
  if not cb or not cb.items or #cb.items == 0 then return {} end

  local paste_start
  local pb = self.playhead_beat or 0.0
  local pb_snapped = Model.snap_round(self, pb)

  if type(target_beat) == "number" then
    paste_start = max(0.0, target_beat)
  elseif (cb.paste_count or 0) >= 1
         and cb.last_paste_end ~= nil
         and abs(pb - (cb.paste_playhead or pb)) <= 1e-4 then
    paste_start = max(0.0, cb.last_paste_end)
  elseif abs(pb - (cb.copy_playhead or pb)) > 1e-4 then
    paste_start = max(0.0, pb_snapped)
  elseif pb_snapped > 1e-4 and abs(pb_snapped - (cb.base_beat or 0.0)) > 1e-4 then
    paste_start = max(0.0, pb_snapped)
  elseif cb.is_cut then
    paste_start = max(0.0, cb.base_beat or 0.0)
  else
    paste_start = max(0.0, (cb.base_beat or 0.0) + (cb.span or 1.0))
  end

  Model.push_undo(self)

  local pasted = {}
  local new_sel = {}
  local first_id = nil
  for i = 1, #cb.items do
    local item = cb.items[i]
    local note = Model.add_note(
      self,
      item.pitch,
      paste_start + item.rel_beat,
      item.length,
      item.velocity
    )
    pasted[#pasted + 1] = note
    new_sel[note.id] = true
    if not first_id then first_id = note.id end
  end

  self.selected_ids   = new_sel
  self.primary_sel_id = first_id
  cb.last_paste_end   = paste_start + (cb.span or 1.0)
  cb.paste_playhead   = pb
  cb.paste_count      = (cb.paste_count or 0) + 1
  cb.is_cut           = false
  if #pasted > 0 then
    self.last_note_len = pasted[#pasted].length
  end
  Model.recompute_max_end(self)
  self.events_dirty = true
  return pasted, paste_start
end

function Model.duplicate_selected(self)
  if Model.count_selected(self) == 0 then return {} end
  local cb = SHARED_CLIPBOARD
  if not cb or (cb.paste_count or 0) == 0 then
    Model.copy_selected(self)
    cb = SHARED_CLIPBOARD or self.clipboard
  else
    -- Duplicate directly after current selection regardless of stale clipboard
    Model.copy_selected(self)
    cb = SHARED_CLIPBOARD or self.clipboard
  end
  if not cb then return {} end
  return Model.paste_clipboard(self, (cb.base_beat or 0.0) + (cb.span or 1.0))
end

return Model
