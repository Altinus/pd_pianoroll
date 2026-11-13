-- ============================================================================
-- pr_playback.lua — Stateless Transport, Scheduler, Loop & MIDI Output Protocol
-- ============================================================================

local Model = require("pr_model")

local Playback = {}

local floor = math.floor
local max   = math.max
local min   = math.min

local function copy_array(src, n)
  local dst = {}
  for i = 1, n do
    dst[i] = src[i]
  end
  return dst
end

local function sync_voices_from_pitches(pitches, n)
  -- Helper returning whether two sorted pitch lists differ
  return pitches, n
end
local _ = sync_voices_from_pitches

function Playback.voice_inc(self, pitch, vel)
  local vc = self.voice_counts
  local prev = vc[pitch]
  vc[pitch] = prev + 1
  self.voice_vels[pitch] = vel or self.default_vel or 100
  return prev == 0
end

function Playback.voice_dec(self, pitch)
  local vc = self.voice_counts
  local prev = vc[pitch]
  if prev <= 1 then
    vc[pitch] = 0
    self.voice_vels[pitch] = 0
    return prev > 0
  else
    vc[pitch] = prev - 1
    return false
  end
end

function Playback.emit_active_list(self)
  local pitches, vels, count = Model.collect_sorted_active_pitches(self)
  local out_p = copy_array(pitches, count)
  if count > 0 then
    local out_v = copy_array(vels, count)
    self:outlet(2, "velocities", out_v)
  end
  self:outlet(1, "list", out_p)
end

function Playback.emit_empty_list(self)
  self:outlet(1, "list", {})
end

function Playback.emit_pos(self)
  local b = self.playhead_beat or 0.0
  local bps = (self.bpm or 120.0) / 60.0
  local sec = b / bps
  self.playhead_sec = sec
  local tsig = max(1, self.timesig_num or 4)
  local bar = floor(b / tsig) + 1
  local bin = (b - (bar - 1) * tsig) + 1
  self:outlet(3, "pos", { b, sec, bar, bin })
end

function Playback.emit_loop(self)
  local en = (self.loop_enabled and self.loop_start ~= nil and self.loop_end ~= nil) and 1 or 0
  local ls = self.loop_start or 0
  local le = self.loop_end or 0
  self:outlet(3, "loop", { en, ls, le })
end

function Playback.release_playback_voices(self)
  local active = self.active_note_ids
  local off_pitches = {}
  local list_changed = false
  for id, pitch in pairs(active) do
    active[id] = nil
    if Playback.voice_dec(self, pitch) then
      list_changed = true
      off_pitches[#off_pitches + 1] = pitch
    end
  end
  if #off_pitches > 0 then
    table.sort(off_pitches)
    for i = 1, #off_pitches do
      self:outlet(2, "noteoff", { off_pitches[i], 0 })
    end
  end
  return list_changed
end

function Playback.all_voices_off(self)
  local vc = self.voice_counts
  local off_pitches = {}
  for p = 0, 127 do
    if vc[p] > 0 then
      vc[p] = 0
      self.voice_vels[p] = 0
      off_pitches[#off_pitches + 1] = p
    end
  end
  self.active_note_ids = {}
  self.audition_pitch  = nil
  for i = 1, #off_pitches do
    self:outlet(2, "noteoff", { off_pitches[i], 0 })
  end
  return #off_pitches > 0
end

local function activate_notes_spanning(self, beat)
  local notes = self.notes
  local active = self.active_note_ids
  local changed = false
  for i = 1, #notes do
    local note = notes[i]
    if note.start_beat <= beat and beat < (note.start_beat + note.length) then
      if not active[note.id] then
        active[note.id] = note.pitch
        if Playback.voice_inc(self, note.pitch, note.velocity) then
          changed = true
          self:outlet(2, "noteon", { note.pitch, note.velocity })
        end
      end
    end
  end
  return changed
end

local function find_cursor_after(events, beat)
  local c, n = 1, #events
  while c <= n and events[c].time <= beat do
    c = c + 1
  end
  return c
end

local function process_events_until(self, limit_beat, inclusive_end)
  local ev = self.events
  local c = self.event_cursor
  local n = #ev
  local active = self.active_note_ids
  local list_changed = false

  while c <= n do
    local e = ev[c]
    if inclusive_end then
      if e.time > limit_beat then break end
    else
      if e.time >= limit_beat then break end
    end

    if e.kind == 1 then
      if not active[e.id] then
        active[e.id] = e.pitch
        if Playback.voice_inc(self, e.pitch, e.vel) then
          list_changed = true
          self:outlet(2, "noteon", { e.pitch, e.vel })
        end
      end
    else
      if active[e.id] then
        local p = active[e.id]
        active[e.id] = nil
        if Playback.voice_dec(self, p) then
          list_changed = true
          self:outlet(2, "noteoff", { p, 0 })
        end
      end
    end
    c = c + 1
  end

  self.event_cursor = c
  return list_changed
end

function Playback.start_audition(self, pitch, vel)
  pitch = max(0, min(127, floor(pitch + 0.5)))
  vel   = max(1, min(127, floor((vel or self.default_vel or 100) + 0.5)))
  if self.audition_pitch == pitch then return end

  local changed = false
  if self.audition_pitch ~= nil then
    local old_p = self.audition_pitch
    self.audition_pitch = nil
    if Playback.voice_dec(self, old_p) then
      changed = true
      self:outlet(2, "noteoff", { old_p, 0 })
    end
  end

  self.audition_pitch = pitch
  if Playback.voice_inc(self, pitch, vel) then
    changed = true
    self:outlet(2, "noteon", { pitch, vel })
  end

  if changed and self.preview_to_out1 ~= false then
    Playback.emit_active_list(self)
  end
  self._dirty_l2 = true
  self:flush_repaint()
end

function Playback.stop_audition(self)
  if self.audition_pitch == nil then return end
  local old_p = self.audition_pitch
  self.audition_pitch = nil
  local changed = false
  if Playback.voice_dec(self, old_p) then
    changed = true
    self:outlet(2, "noteoff", { old_p, 0 })
  end
  if changed and self.preview_to_out1 ~= false then
    Playback.emit_active_list(self)
  end
  self._dirty_l2 = true
  self:flush_repaint()
end

function Playback.sync_note_removed(self, note)
  if not note then return end
  local active = self.active_note_ids
  local p = active[note.id]
  if p ~= nil then
    active[note.id] = nil
    if Playback.voice_dec(self, p) then
      self:outlet(2, "noteoff", { p, 0 })
      Playback.emit_active_list(self)
    end
  end
end

function Playback.sync_note_modified(self, note)
  self.events_dirty = true
  if not self.playing or not note then return end
  local active = self.active_note_ids
  local ph = self.playhead_beat
  local should_be_active = (note.start_beat <= ph and ph < note.start_beat + note.length)
  local was_active_pitch = active[note.id]
  local changed = false

  if was_active_pitch ~= nil and (not should_be_active or was_active_pitch ~= note.pitch) then
    active[note.id] = nil
    if Playback.voice_dec(self, was_active_pitch) then
      changed = true
      self:outlet(2, "noteoff", { was_active_pitch, 0 })
    end
  end
  if should_be_active and active[note.id] == nil then
    active[note.id] = note.pitch
    if Playback.voice_inc(self, note.pitch, note.velocity) then
      changed = true
      self:outlet(2, "noteon", { note.pitch, note.velocity })
    end
  end
  Model.rebuild_events(self)
  self.event_cursor = find_cursor_after(self.events, ph)
  if changed then
    Playback.emit_active_list(self)
  end
end

function Playback.start(self)
  if self.playing then return end
  if self.events_dirty then Model.rebuild_events(self) end

  Playback.release_playback_voices(self)

  local ph = self.playhead_beat or 0.0
  -- If playhead sits past loop_end while looping is enabled, snap to loop_start
  if self.loop_enabled and self.loop_start and self.loop_end and self.loop_end > self.loop_start then
    if ph >= self.loop_end or ph < 0 then
      ph = self.loop_start
      self.playhead_beat = ph
    end
  end

  local changed = activate_notes_spanning(self, ph)
  self.event_cursor = find_cursor_after(self.events, ph)

  self.playing      = true
  self.last_systime = pd.systime()

  self:outlet(3, "playing", { 1 })
  Playback.emit_pos(self)
  if changed then
    Playback.emit_active_list(self)
  end

  if self.tick_clock then self.tick_clock:delay(self.tick_ms or 2) end
  if self.redraw_clock then self.redraw_clock:delay(self.redraw_ms or 33) end
  self._dirty_l1 = true
  self._dirty_l2 = true
  self._dirty_l3 = true
  self:flush_repaint()
end

function Playback.pause(self)
  local was_playing = self.playing
  self.playing = false
  if self.tick_clock then self.tick_clock:unset() end
  if self.redraw_clock then self.redraw_clock:unset() end

  Playback.all_voices_off(self)

  self:outlet(3, "playing", { 0 })
  Playback.emit_pos(self)
  -- User requirement: clear sorted MIDI list output on pause
  Playback.emit_empty_list(self)

  if was_playing then
    self._dirty_l1 = true
    self._dirty_l2 = true
    self._dirty_l3 = true
    self:flush_repaint()
  else
    self._dirty_l2 = true
    self._dirty_l3 = true
    self:flush_repaint()
  end
end

function Playback.stop(self)
  self.playing = false
  if self.tick_clock then self.tick_clock:unset() end
  if self.redraw_clock then self.redraw_clock:unset() end

  Playback.all_voices_off(self)

  if self.loop_enabled and self.loop_start ~= nil and self.loop_end ~= nil and self.loop_end > self.loop_start then
    self.playhead_beat = self.loop_start
  else
    self.playhead_beat = 0.0
  end

  self:outlet(3, "playing", { 0 })
  Playback.emit_pos(self)
  Playback.emit_empty_list(self)

  self._dirty_l1 = true
  self._dirty_l2 = true
  self._dirty_l3 = true
  self:flush_repaint()
end

function Playback.seek_beat(self, beat)
  beat = max(0.0, tonumber(beat) or 0.0)
  if self.events_dirty then Model.rebuild_events(self) end

  local changed = false
  if self.playing then
    if Playback.release_playback_voices(self) then changed = true end
    self.playhead_beat = beat
    if activate_notes_spanning(self, beat) then changed = true end
    self.event_cursor = find_cursor_after(self.events, beat)
    self.last_systime = pd.systime()
  else
    self.playhead_beat = beat
  end

  Playback.emit_pos(self)
  if self.playing and changed then
    Playback.emit_active_list(self)
  elseif self.playing then
    Playback.emit_active_list(self)
  end

  self._dirty_l2 = true
  self._dirty_l3 = true
  self:flush_repaint()
end

function Playback.set_bpm(self, bpm)
  self.bpm = max(20.0, min(300.0, tonumber(bpm) or 120.0))
  self.playhead_sec = (self.playhead_beat or 0.0) * 60.0 / self.bpm
  self:outlet(3, "bpm", { self.bpm })
end

function Playback.on_tick(self)
  if not self.playing then return end

  if self.events_dirty then
    Model.rebuild_events(self)
    self.event_cursor = find_cursor_after(self.events, self.playhead_beat)
  end

  local now = pd.systime()
  local dt_ms = pd.timesince(self.last_systime)
  self.last_systime = now

  if dt_ms < 0 then dt_ms = 0 end
  local bps      = (self.bpm or 120.0) / 60.0
  local old_beat = self.playhead_beat or 0.0
  local new_beat = old_beat + (dt_ms / 1000.0) * bps

  local list_changed = false
  local has_loop = self.loop_enabled and self.loop_start ~= nil and self.loop_end ~= nil
                   and (self.loop_end > self.loop_start)

  if has_loop and old_beat < self.loop_end and new_beat >= self.loop_end then
    -- Process everything up to loop_end (including noteoffs at loop_end)
    if process_events_until(self, self.loop_end, true) then
      list_changed = true
    end
    if Playback.release_playback_voices(self) then
      list_changed = true
    end

    local loop_len = self.loop_end - self.loop_start
    local wrapped = self.loop_start + ((new_beat - self.loop_start) % loop_len)
    self.playhead_beat = self.loop_start
    if activate_notes_spanning(self, self.loop_start) then
      list_changed = true
    end
    self.event_cursor = find_cursor_after(self.events, self.loop_start)
    if wrapped > self.loop_start then
      if process_events_until(self, wrapped, true) then
        list_changed = true
      end
    end
    new_beat = wrapped
  else
    if process_events_until(self, new_beat, true) then
      list_changed = true
    end
  end

  self.playhead_beat = new_beat
  Playback.emit_pos(self)

  if list_changed then
    Playback.emit_active_list(self)
    self._dirty_l2 = true
  end

  -- Check end of sequence when loop is off
  local end_limit = max(self.length_beats or 16, (self.max_end_beat or 0) + 0.25)
  if (not has_loop) and (self.event_cursor > #self.events) and (new_beat >= end_limit) then
    if self.auto_rewind ~= false then
      Playback.stop(self)
    else
      Playback.pause(self)
    end
    return
  end

  if self.tick_clock then
    self.tick_clock:delay(self.tick_ms or 2)
  end
end

return Playback
