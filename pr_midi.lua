-- ============================================================================
-- pr_midi.lua — Standard MIDI File (.mid) Type 0/1 Import, Export & Track Switch
-- Pure LuaJIT implementation with Windows UTF-8 FFI file I/O + io.open fallback.
-- ============================================================================

local Model    = require("pr_model")
local Playback = require("pr_playback")
local Layout   = require("pr_layout")

local Midi = {}

local floor  = math.floor
local ceil   = math.ceil
local max    = math.max
local min    = math.min
local abs    = math.abs
local sort   = table.sort
local concat = table.concat
local char   = string.char
local byte   = string.byte
local sub    = string.sub

local has_ffi, ffi = pcall(require, "ffi")
local win32_ready = false
local k32 = nil
local INVALID_HANDLE = nil

if has_ffi and ffi and ffi.os == "Windows" then
  local ok_def = pcall(ffi.cdef, [[
    int MultiByteToWideChar(unsigned int CodePage, uint32_t dwFlags,
                            const char* lpMultiByteStr, int cbMultiByte,
                            uint16_t* lpWideCharStr, int cchWideChar);
    void* CreateFileW(const uint16_t* lpFileName, uint32_t dwDesiredAccess,
                      uint32_t dwShareMode, void* lpSecurityAttributes,
                      uint32_t dwCreationDisposition, uint32_t dwFlagsAndAttributes,
                      void* hTemplateFile);
    int GetFileSizeEx(void* hFile, int64_t* lpFileSize);
    int ReadFile(void* hFile, void* lpBuffer, uint32_t nNumberOfBytesToRead,
                 uint32_t* lpNumberOfBytesRead, void* lpOverlapped);
    int WriteFile(void* hFile, const void* lpBuffer, uint32_t nNumberOfBytesToWrite,
                  uint32_t* lpNumberOfBytesWritten, void* lpOverlapped);
    int CloseHandle(void* hObject);
  ]])
  local ok_k32, lib = pcall(ffi.load, "kernel32")
  if (ok_def or pcall(function() return ffi.sizeof("uint16_t") end)) and ok_k32 and lib then
    k32 = lib
    INVALID_HANDLE = ffi.cast("void*", -1)
    win32_ready = true
  end
end

local function utf8_to_wide(str)
  local lib = k32
  if not (win32_ready and lib) then return nil end
  local len = lib.MultiByteToWideChar(65001, 0, str, -1, nil, 0)
  if len <= 0 then return nil end
  local buf = ffi.new("uint16_t[?]", len)
  if lib.MultiByteToWideChar(65001, 0, str, -1, buf, len) <= 0 then
    return nil
  end
  return buf
end

-- ============================================================================
-- Path Resolution & Binary File I/O
-- ============================================================================

local function trim_str(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Midi.strip_quotes(path)
  local s = trim_str(tostring(path or ""))
  if (#s >= 2) and ((sub(s, 1, 1) == '"' and sub(s, -1) == '"')
                    or (sub(s, 1, 1) == "'" and sub(s, -1) == "'")) then
    s = sub(s, 2, -2)
  end
  -- Unescape Pd symbol space escapes ("\ ") if present
  s = s:gsub("\\ ", " ")
  return s
end

local function is_abs_path(p)
  if p:match("^[A-Za-z]:[/\\]") then return true end
  if sub(p, 1, 2) == "\\\\" or sub(p, 1, 2) == "//" then return true end
  if sub(p, 1, 1) == "/" then return true end
  return false
end

function Midi.resolve_path(self, raw_path)
  local p = Midi.strip_quotes(raw_path)
  if p == "" then return "" end
  if is_abs_path(p) then return p end

  local base = (self and type(self._canvaspath) == "string" and self._canvaspath ~= "" and self._canvaspath)
            or (self and type(self._loadpath) == "string" and self._loadpath ~= "" and self._loadpath)
            or (pd and type(rawget(pd, "_loadpath")) == "string" and rawget(pd, "_loadpath"))
  if base and base ~= "" then
    local last = sub(base, -1)
    if last ~= "/" and last ~= "\\" then
      base = base .. "/"
    end
    return base .. p
  end
  return p
end

function Midi.parse_import_atoms(atoms)
  if not atoms or #atoms == 0 then return "", nil end
  local n = #atoms
  local track_opt = nil
  local path_end = n

  if n >= 2 then
    local tail = atoms[n]
    local tail_num = tonumber(tail)
    local tail_str = tostring(tail):lower()
    if tail_str == "all" then
      track_opt = 0
      path_end = n - 1
    elseif tail_num ~= nil and abs(tail_num - floor(tail_num + 0.5)) < 1e-6 then
      track_opt = max(0, floor(tail_num + 0.5))
      path_end = n - 1
    end
  end

  local parts = {}
  for i = 1, path_end do
    parts[i] = tostring(atoms[i])
  end
  return trim_str(concat(parts, " ")), track_opt
end

function Midi.parse_export_atoms(atoms)
  if not atoms or #atoms == 0 then return "" end
  local parts = {}
  for i = 1, #atoms do
    parts[i] = tostring(atoms[i])
  end
  local path = Midi.strip_quotes(concat(parts, " "))
  if path ~= "" and not path:lower():match("%.midi?$") then
    path = path .. ".mid"
  end
  return path
end

function Midi.read_bytes(path)
  if type(path) ~= "string" or path == "" then
    return nil, "Empty file path"
  end

  local lib = k32
  if win32_ready and lib then
    local wpath = utf8_to_wide(path)
    if wpath then
      -- GENERIC_READ=0x80000000, FILE_SHARE_READ=1, OPEN_EXISTING=3, FILE_ATTRIBUTE_NORMAL=0x80
      local h = lib.CreateFileW(wpath, 0x80000000, 1, nil, 3, 0x80, nil)
      if h ~= nil and h ~= INVALID_HANDLE then
        local sz_buf = ffi.new("int64_t[1]")
        if lib.GetFileSizeEx(h, sz_buf) ~= 0 then
          local sz = tonumber(sz_buf[0]) or 0
          if sz <= 0 then
            lib.CloseHandle(h)
            return "", nil
          end
          if sz > 64 * 1024 * 1024 then
            lib.CloseHandle(h)
            return nil, "MIDI file too large (>64 MB)"
          end
          local buf = ffi.new("uint8_t[?]", sz)
          local read_n = ffi.new("uint32_t[1]")
          local ok = lib.ReadFile(h, buf, sz, read_n, nil)
          lib.CloseHandle(h)
          if ok ~= 0 then
            return ffi.string(buf, tonumber(read_n[0]) or 0), nil
          end
        else
          lib.CloseHandle(h)
        end
      end
    end
  end

  local f, err = io.open(path, "rb")
  if not f then
    return nil, "Cannot open file: " .. tostring(err or path)
  end
  local data = f:read("*a")
  f:close()
  if not data then
    return nil, "Failed to read file: " .. path
  end
  return data, nil
end

function Midi.write_bytes(path, data)
  if type(path) ~= "string" or path == "" then
    return false, "Empty file path"
  end
  data = data or ""

  local lib = k32
  if win32_ready and lib then
    local wpath = utf8_to_wide(path)
    if wpath then
      -- GENERIC_WRITE=0x40000000, CREATE_ALWAYS=2, FILE_ATTRIBUTE_NORMAL=0x80
      local h = lib.CreateFileW(wpath, 0x40000000, 0, nil, 2, 0x80, nil)
      if h ~= nil and h ~= INVALID_HANDLE then
        local total = #data
        if total == 0 then
          lib.CloseHandle(h)
          return true, nil
        end
        local written = ffi.new("uint32_t[1]")
        local ok = lib.WriteFile(h, data, total, written, nil)
        lib.CloseHandle(h)
        if ok ~= 0 and (tonumber(written[0]) or 0) == total then
          return true, nil
        end
        return false, "Win32 WriteFile failed for: " .. path
      end
    end
  end

  local f, err = io.open(path, "wb")
  if not f then
    return false, "Cannot write file: " .. tostring(err or path)
  end
  local ok, werr = f:write(data)
  f:close()
  if not ok then
    return false, "Write failed: " .. tostring(werr or path)
  end
  return true, nil
end

-- ============================================================================
-- Binary Helpers & Variable-Length Quantity (VLQ)
-- ============================================================================

local function read_u16(s, p)
  local a, b = byte(s, p, p + 1)
  if not b then return nil end
  return a * 256 + b
end

local function read_u24(s, p)
  local a, b, c = byte(s, p, p + 2)
  if not c then return nil end
  return (a * 256 + b) * 256 + c
end

local function read_u32(s, p)
  local a, b, c, d = byte(s, p, p + 3)
  if not d then return nil end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function read_vlq(s, p, end_p)
  local val = 0
  for _ = 1, 4 do
    if p > end_p then return val, p end
    local b = byte(s, p)
    p = p + 1
    if b < 128 then
      return val * 128 + b, p
    end
    val = val * 128 + (b - 128)
  end
  return val, p
end

local function encode_u16(n)
  n = floor(max(0, min(65535, n)))
  return char(floor(n / 256) % 256, n % 256)
end

local function encode_u24(n)
  n = floor(max(0, min(16777215, n)))
  return char(floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
end

local function encode_u32(n)
  n = floor(max(0, n))
  return char(
    floor(n / 16777216) % 256,
    floor(n / 65536) % 256,
    floor(n / 256) % 256,
    n % 256
  )
end

local function encode_vlq(n)
  n = floor(max(0, n))
  if n < 128 then return char(n) end
  local bytes = {}
  bytes[1] = n % 128
  n = floor(n / 128)
  while n > 0 do
    bytes[#bytes + 1] = 128 + (n % 128)
    n = floor(n / 128)
  end
  local rev = {}
  for i = #bytes, 1, -1 do
    rev[#rev + 1] = char(bytes[i])
  end
  return concat(rev)
end

local function clean_track_name(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("%z", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return nil end
  if #s > 36 then s = sub(s, 1, 36) end
  return s
end

-- ============================================================================
-- SMF Decoder (Type 0 / 1 / 2)
-- ============================================================================

function Midi.decode(bytes)
  if type(bytes) ~= "string" or #bytes < 14 then
    return nil, "Invalid MIDI file (too short)"
  end

  -- Locate MThd header (tolerate optional RIFF/RMID header prefix if present)
  local pos = 1
  if sub(bytes, 1, 4) ~= "MThd" then
    local found = bytes:find("MThd", 1, true)
    if not found then
      return nil, "Not a valid MIDI file (missing MThd)"
    end
    pos = found
  end

  local hdr_len = read_u32(bytes, pos + 4)
  if not hdr_len or hdr_len < 6 or (pos + 8 + hdr_len - 1) > #bytes then
    return nil, "Corrupt MThd header"
  end

  local format   = read_u16(bytes, pos + 8)
  local ntracks  = read_u16(bytes, pos + 10)
  local division = read_u16(bytes, pos + 12)
  pos = pos + 8 + hdr_len

  local is_smpte = (division >= 0x8000)
  local ppq = division
  local smpte_ticks_per_sec = 0
  if is_smpte then
    local upper = floor(division / 256)
    local fps = 256 - upper
    if fps == 29 then fps = 29.97 end
    local subframes = division % 256
    smpte_ticks_per_sec = max(1.0, fps * max(1, subframes))
    ppq = 480
  elseif ppq <= 0 then
    return nil, "Invalid MIDI division (PPQ == 0)"
  end

  local first_tempo_tick = nil
  local detected_bpm = nil
  local detected_timesig = nil

  local raw_tracks = {}
  local raw_idx = 0
  local len = #bytes

  while pos + 7 <= len do
    local tag = sub(bytes, pos, pos + 3)
    local clen = read_u32(bytes, pos + 4)
    if not clen then break end
    local cstart = pos + 8
    local cend = min(len, cstart + clen - 1)
    pos = cstart + clen

    if tag == "MTrk" then
      raw_idx = raw_idx + 1
      local p = cstart
      local abs_tick = 0
      local running = nil
      local trk_name = nil
      local open_notes = {}
      local pending_notes = {}

      local function close_pending(item, end_tick)
        pending_notes[#pending_notes + 1] = {
          pitch      = item.pitch,
          start_tick = item.tick,
          end_tick   = max(item.tick + 1, end_tick),
          velocity   = item.vel,
          channel    = item.ch,
          track      = raw_idx,
        }
      end

      while p <= cend do
        local delta
        delta, p = read_vlq(bytes, p, cend)
        abs_tick = abs_tick + delta
        if p > cend then break end

        local b = byte(bytes, p)
        local status, d1
        if b < 128 then
          if not running then
            -- Skip orphan data byte safely
            p = p + 1
          else
            status = running
            d1 = b
            p = p + 1
          end
        else
          status = b
          p = p + 1
        end

        if status then
          if status == 0xFF then
            running = nil
            if p > cend then break end
            local meta_type = byte(bytes, p)
            p = p + 1
            local mlen
            mlen, p = read_vlq(bytes, p, cend)
            local mstart = p
            p = min(cend + 1, p + mlen)
            if meta_type == 0x03 and trk_name == nil and mlen > 0 and mstart <= cend then
              trk_name = clean_track_name(sub(bytes, mstart, min(cend, mstart + mlen - 1)))
            elseif meta_type == 0x51 and mlen >= 3 and (mstart + 2) <= cend then
              local us = read_u24(bytes, mstart)
              if us and us > 0 then
                if first_tempo_tick == nil or abs_tick <= first_tempo_tick then
                  first_tempo_tick = abs_tick
                  detected_bpm = 60000000.0 / us
                end
              end
            elseif meta_type == 0x58 and mlen >= 2 and (mstart + 1) <= cend and detected_timesig == nil then
              local nn = byte(bytes, mstart)
              local dd = byte(bytes, mstart + 1)
              if nn and nn > 0 and dd and dd <= 6 then
                local q_beats = nn * (4.0 / (2 ^ dd))
                detected_timesig = max(1, min(16, floor(q_beats + 0.5)))
              end
            elseif meta_type == 0x2F then
              break
            end
          elseif status == 0xF0 or status == 0xF7 then
            running = nil
            local slen
            slen, p = read_vlq(bytes, p, cend)
            p = min(cend + 1, p + slen)
          elseif status >= 0xF1 then
            if status < 0xF8 then running = nil end
            if status == 0xF1 or status == 0xF3 then
              p = p + 1
            elseif status == 0xF2 then
              p = p + 2
            end
          elseif status >= 0x80 then
            running = status
            local kind = floor(status / 16)
            local ch   = (status % 16) + 1
            if not d1 then
              if p > cend then break end
              d1 = byte(bytes, p)
              p = p + 1
            end
            if kind == 0xC or kind == 0xD then
              -- 1-data-byte channel messages already consumed d1
            else
              if p > cend then break end
              local d2 = byte(bytes, p)
              p = p + 1
              if kind == 0x9 and d2 > 0 then
                local pitch = min(127, d1 % 128)
                local key = ch * 128 + pitch
                local q = open_notes[key]
                if not q then
                  q = {}
                  open_notes[key] = q
                end
                q[#q + 1] = {
                  pitch = pitch,
                  tick  = abs_tick,
                  vel   = max(1, min(127, d2)),
                  ch    = ch,
                }
              elseif kind == 0x8 or (kind == 0x9 and d2 == 0) then
                local pitch = min(127, d1 % 128)
                local key = ch * 128 + pitch
                local q = open_notes[key]
                if q and #q > 0 then
                  local item = table.remove(q, 1)
                  close_pending(item, abs_tick)
                end
              end
            end
          end
        end
      end

      -- Close any hanging notes gracefully at end of track
      local fallback_dur = max(1, floor(ppq * 0.25 + 0.5))
      for _, q in pairs(open_notes) do
        for i = 1, #q do
          local item = q[i]
          close_pending(item, max(abs_tick, item.tick + fallback_dur))
        end
      end

      raw_tracks[raw_idx] = {
        raw_idx       = raw_idx,
        name          = trk_name,
        pending_notes = pending_notes,
        end_tick      = abs_tick,
      }
    end
  end

  if raw_idx == 0 then
    return nil, "MIDI file contains no MTrk track chunks"
  end

  local eff_bpm = detected_bpm or 120.0
  local function tick_to_beat(t)
    if is_smpte then
      return (t / smpte_ticks_per_sec) * (eff_bpm / 60.0)
    end
    return t / ppq
  end

  local note_tracks = {}
  local all_notes = {}
  local max_end_beat = 0.0

  for i = 1, raw_idx do
    local trk = raw_tracks[i]
    local notes = {}
    local pnotes = trk.pending_notes
    for j = 1, #pnotes do
      local pn = pnotes[j]
      local sb = max(0.0, tick_to_beat(pn.start_tick))
      local eb = max(sb + 0.03125, tick_to_beat(pn.end_tick))
      local ln = max(0.03125, eb - sb)
      local note = {
        pitch      = pn.pitch,
        start_beat = sb,
        length     = ln,
        velocity   = pn.velocity,
        channel    = pn.ch,
        track      = trk.raw_idx,
      }
      notes[#notes + 1] = note
      all_notes[#all_notes + 1] = note
      if sb + ln > max_end_beat then max_end_beat = sb + ln end
    end

    sort(notes, function(a, b)
      if a.start_beat ~= b.start_beat then return a.start_beat < b.start_beat end
      return a.pitch < b.pitch
    end)

    trk.notes = notes
    trk.pending_notes = nil
    if #notes > 0 then
      note_tracks[#note_tracks + 1] = {
        raw_idx    = trk.raw_idx,
        ordinal    = #note_tracks + 1,
        name       = trk.name,
        notes      = notes,
        note_count = #notes,
      }
    end
  end

  sort(all_notes, function(a, b)
    if a.start_beat ~= b.start_beat then return a.start_beat < b.start_beat end
    if a.pitch ~= b.pitch then return a.pitch < b.pitch end
    return (a.track or 0) < (b.track or 0)
  end)

  return {
    format       = format,
    ntracks_hdr  = ntracks,
    raw_tracks   = raw_tracks,
    note_tracks  = note_tracks,
    all_notes    = all_notes,
    ppq          = ppq,
    bpm          = detected_bpm,
    timesig_num  = detected_timesig,
    max_end_beat = max_end_beat,
  }, nil
end

-- ============================================================================
-- SMF Encoder (Type 0 for Single Track, Type 1 for Multi-Track)
-- ============================================================================

local function encode_track_chunk(events, meta_prefix_chunks)
  sort(events, function(a, b)
    if a.tick ~= b.tick then return a.tick < b.tick end
    if a.order ~= b.order then return a.order < b.order end
    return a.pitch < b.pitch
  end)

  local out = {}
  if meta_prefix_chunks then
    for i = 1, #meta_prefix_chunks do
      out[#out + 1] = meta_prefix_chunks[i]
    end
  end

  local cur_tick = 0
  for i = 1, #events do
    local ev = events[i]
    local dt = max(0, ev.tick - cur_tick)
    cur_tick = ev.tick
    out[#out + 1] = encode_vlq(dt)
    out[#out + 1] = ev.data
  end

  -- Meta End of Track (0xFF 0x2F 0x00)
  out[#out + 1] = char(0x00, 0xFF, 0x2F, 0x00)
  local body = concat(out)
  return "MTrk" .. encode_u32(#body) .. body
end

function Midi.encode(notes, opts)
  opts = opts or {}
  local ppq      = max(48, min(960, floor((opts.ppq or 480) + 0.5)))
  local bpm      = max(20.0, min(300.0, tonumber(opts.bpm) or 120.0))
  local tsig_num = max(1, min(16, floor((tonumber(opts.timesig_num) or 4) + 0.5)))
  local us_per_q = floor(60000000.0 / bpm + 0.5)

  -- Tempo + TimeSig meta events placed at delta=0 of Track 1
  local meta1 = {
    char(0x00, 0xFF, 0x51, 0x03) .. encode_u24(us_per_q),
    char(0x00, 0xFF, 0x58, 0x04, tsig_num, 0x02, 0x18, 0x08),
  }

  -- Group notes by optional .track tag while preserving relative order
  local track_map = {}
  local track_keys = {}
  for i = 1, #(notes or {}) do
    local n = notes[i]
    local tk = floor(tonumber(n.track) or 1)
    if tk < 1 then tk = 1 end
    local bucket = track_map[tk]
    if not bucket then
      bucket = {}
      track_map[tk] = bucket
      track_keys[#track_keys + 1] = tk
    end
    bucket[#bucket + 1] = n
  end

  if #track_keys == 0 then
    track_keys[1] = 1
    track_map[1] = {}
  else
    sort(track_keys)
  end

  local track_names = opts.track_names or {}
  local format = (#track_keys > 1) and 1 or 0
  local chunks = {}

  for idx = 1, #track_keys do
    local tk = track_keys[idx]
    local tnotes = track_map[tk]
    local events = {}
    for j = 1, #tnotes do
      local n = tnotes[j]
      local pitch = max(0, min(127, floor((n.pitch or 60) + 0.5)))
      local vel   = max(1, min(127, floor((n.velocity or 100) + 0.5)))
      local ch    = max(1, min(16, floor((tonumber(n.channel) or 1) + 0.5))) - 1
      local t_on  = max(0, floor((n.start_beat or 0.0) * ppq + 0.5))
      local t_off = max(t_on + 1, floor(((n.start_beat or 0.0) + max(0.03125, n.length or 0.25)) * ppq + 0.5))
      events[#events + 1] = {
        tick  = t_on,
        order = 2, -- Note Off precedes Note On at identical tick
        pitch = pitch,
        data  = char(0x90 + ch, pitch, vel),
      }
      events[#events + 1] = {
        tick  = t_off,
        order = 1,
        pitch = pitch,
        data  = char(0x80 + ch, pitch, 0),
      }
    end

    local prefix = (idx == 1) and { meta1[1], meta1[2] } or {}
    local tname = track_names[tk]
    if type(tname) == "string" and tname ~= "" then
      prefix[#prefix + 1] = char(0x00, 0xFF, 0x03) .. encode_vlq(#tname) .. tname
    end
    chunks[idx] = encode_track_chunk(events, prefix)
  end

  local header = "MThd" .. encode_u32(6) .. encode_u16(format) .. encode_u16(#chunks) .. encode_u16(ppq)
  return header .. concat(chunks)
end

-- ============================================================================
-- PianoRoll Integration: Multi-Track State Sync, Switcher & Import/Export
-- ============================================================================

local function clone_track_notes(src_notes, default_track_num)
  local out = {}
  if not src_notes then return out end
  for i = 1, #src_notes do
    local n = src_notes[i]
    out[i] = {
      pitch      = n.pitch,
      start_beat = n.start_beat,
      length     = n.length,
      velocity   = n.velocity,
      channel    = n.channel,
      track      = n.track or default_track_num,
    }
  end
  return out
end

local function load_notes_list(self, src_notes)
  Model.clear_notes(self)
  for i = 1, #src_notes do
    local s = src_notes[i]
    Model.add_note(self, s.pitch, s.start_beat, s.length, s.velocity, s.channel, s.track)
  end
  if #self.notes > 0 then
    self.last_note_len = self.notes[#self.notes].length
  end
  Model.rebuild_events(self)
end

function Midi.sync_active_track_edits(self)
  local tracks = self.midi_tracks
  if not tracks or #tracks == 0 then return end

  local cur_idx = self.midi_track_idx or 0
  if cur_idx > 0 and tracks[cur_idx] then
    local raw = tracks[cur_idx].raw_idx
    local cloned = clone_track_notes(self.notes, raw)
    tracks[cur_idx].notes = cloned
    tracks[cur_idx].note_count = #cloned
  elseif cur_idx == 0 then
    local by_raw = {}
    for i = 1, #tracks do
      by_raw[tracks[i].raw_idx] = {}
      tracks[i].notes = by_raw[tracks[i].raw_idx]
      tracks[i].note_count = 0
    end
    local fallback_raw = tracks[1].raw_idx
    for i = 1, #self.notes do
      local n = self.notes[i]
      local raw = n.track or fallback_raw
      local bucket = by_raw[raw] or by_raw[fallback_raw]
      bucket[#bucket + 1] = {
        pitch      = n.pitch,
        start_beat = n.start_beat,
        length     = n.length,
        velocity   = n.velocity,
        channel    = n.channel,
        track      = raw,
      }
    end
    for i = 1, #tracks do
      tracks[i].note_count = #tracks[i].notes
    end
  end
end

function Midi.clear_tracks(self)
  self.midi_tracks = nil
  self.midi_track_idx = 0
end

local function center_pitch_if_offscreen(self)
  if #self.notes == 0 then return end
  local w, h = self:get_size()
  local layout = Layout.compute(self, w, h)
  local roll_h = max(1, layout.roll.h)
  local ppp = self.px_per_pitch or Layout.DEF_PPP
  local vis_p = roll_h / ppp
  local top_p = self.view_pitch_top or 82.0
  local bot_p = top_p - vis_p

  local lo_p, hi_p = 127, 0
  local any_visible = false
  for i = 1, #self.notes do
    local p = self.notes[i].pitch
    if p < lo_p then lo_p = p end
    if p > hi_p then hi_p = p end
    if p >= bot_p and p <= top_p then
      any_visible = true
    end
  end
  if not any_visible then
    local mid = (lo_p + hi_p) * 0.5
    self.view_pitch_top = max(0.0, min(127.0, mid + vis_p * 0.5))
    Layout.clamp_view(self, layout)
  end
end

function Midi.switch_track(self, target)
  local tracks = self.midi_tracks
  if not tracks or #tracks == 0 then return false end

  local n_tr = #tracks
  local cur_idx = self.midi_track_idx or 0
  local next_idx = cur_idx

  if target == nil or target == "next" then
    next_idx = (cur_idx + 1) % (n_tr + 1)
  elseif target == "prev" then
    next_idx = (cur_idx + n_tr) % (n_tr + 1)
  elseif target == "all" or target == 0 then
    next_idx = 0
  else
    local num = tonumber(target)
    if num ~= nil then
      num = floor(num + 0.5)
      if num <= 0 then
        next_idx = 0
      else
        local matched = nil
        for i = 1, n_tr do
          if tracks[i].raw_idx == num then
            matched = i
            break
          end
        end
        if not matched and num <= n_tr then
          matched = num
        end
        if not matched then
          return false, "MIDI Track " .. tostring(num) .. " not available"
        end
        next_idx = matched
      end
    end
  end

  if next_idx == cur_idx then
    return true
  end

  Midi.sync_active_track_edits(self)
  Model.push_undo(self)
  Playback.release_playback_voices(self)

  self.midi_track_idx = next_idx
  if next_idx == 0 then
    local merged = {}
    for i = 1, n_tr do
      local tn = tracks[i].notes
      for j = 1, #tn do
        merged[#merged + 1] = tn[j]
      end
    end
    sort(merged, function(a, b)
      if a.start_beat ~= b.start_beat then return a.start_beat < b.start_beat end
      return a.pitch < b.pitch
    end)
    load_notes_list(self, merged)
    self.hud_text = string.format("MIDI Track: ALL (%d tracks, %d notes)", n_tr, #self.notes)
  else
    local trk = tracks[next_idx]
    load_notes_list(self, trk.notes)
    local label = trk.name and (" (" .. trk.name .. ")") or ""
    self.hud_text = string.format("MIDI Track %d%s: %d notes", trk.raw_idx, label, #self.notes)
  end

  center_pitch_if_offscreen(self)
  if self.playing then
    Playback.seek_beat(self, self.playhead_beat or 0.0)
  end

  local active_trk = (next_idx > 0) and tracks[next_idx] or nil
  self:outlet(4, "midi_track", {
    next_idx,
    active_trk and active_trk.raw_idx or 0,
    #self.notes,
    active_trk and (active_trk.name or "") or "all",
  })
  self:save_state()
  self._dirty_l1 = true
  self._dirty_l2 = true
  self._dirty_l3 = true
  self:flush_repaint()
  return true
end

function Midi.get_track_pill_label(self)
  local tracks = self.midi_tracks
  if not tracks or #tracks <= 1 then return nil end
  local idx = self.midi_track_idx or 0
  if idx == 0 or not tracks[idx] then
    return "ALL"
  end
  return "T" .. tostring(tracks[idx].raw_idx)
end

function Midi.describe_active_track(self)
  local tracks = self.midi_tracks
  if not tracks or #tracks <= 1 then return "MIDI Track" end
  local idx = self.midi_track_idx or 0
  if idx == 0 or not tracks[idx] then
    return string.format("MIDI Track: ALL (%d tracks) — Click to switch", #tracks)
  end
  local trk = tracks[idx]
  local nm = trk.name and (" (" .. trk.name .. ")") or ""
  return string.format("MIDI Track %d%s: %d notes — Click to switch", trk.raw_idx, nm, #trk.notes)
end

local function compute_synced_length(max_end_beat, tsig_num)
  local bar = max(1, tsig_num or 4)
  if max_end_beat <= 0.0 then
    return max(4.0, bar * 1.0)
  end
  local bars = ceil(max(0.1, max_end_beat - 1e-4) / bar)
  return max(4.0, min(2048.0, bars * bar))
end

function Midi.import_from_file(self, raw_path, track_opt)
  local path = Midi.resolve_path(self, raw_path)
  if path == "" then
    return false, "import_midi: missing file path"
  end

  local bytes, rerr = Midi.read_bytes(path)
  if not bytes then
    return false, rerr
  end

  local parsed, perr = Midi.decode(bytes)
  if not parsed then
    return false, perr
  end

  local explicit_single = (track_opt ~= nil and track_opt > 0)
  local chosen_notes = nil
  local chosen_raw_track = nil

  if explicit_single then
    local raw_trk = parsed.raw_tracks[track_opt]
    if not raw_trk then
      return false, string.format("MIDI Track %d not found (file has %d track chunk(s))",
                                  track_opt, #parsed.raw_tracks)
    end
    chosen_notes = raw_trk.notes or {}
    chosen_raw_track = raw_trk
  else
    chosen_notes = parsed.all_notes or {}
  end

  -- Overwrite cleanly (undoable)
  Playback.release_playback_voices(self)
  if self.playing then Playback.emit_empty_list(self) end
  Model.push_undo(self)

  -- Sync Time Signature & BPM from MIDI file
  if parsed.timesig_num then
    self.timesig_num = max(1, min(16, parsed.timesig_num))
  end
  if parsed.bpm then
    Playback.set_bpm(self, parsed.bpm)
  end

  if explicit_single then
    Midi.clear_tracks(self)
    load_notes_list(self, chosen_notes)
    local trk_max = 0.0
    for i = 1, #chosen_notes do
      local e = chosen_notes[i].start_beat + chosen_notes[i].length
      if e > trk_max then trk_max = e end
    end
    self.length_beats = compute_synced_length(trk_max, self.timesig_num)
    local label = chosen_raw_track and chosen_raw_track.name and (" (" .. chosen_raw_track.name .. ")") or ""
    self.hud_text = string.format("Imported Track %d%s: %d notes", track_opt, label, #self.notes)
  else
    if #parsed.note_tracks > 1 then
      local stored = {}
      for i = 1, #parsed.note_tracks do
        local nt = parsed.note_tracks[i]
        stored[i] = {
          raw_idx    = nt.raw_idx,
          ordinal    = nt.ordinal,
          name       = nt.name,
          notes      = clone_track_notes(nt.notes, nt.raw_idx),
          note_count = nt.note_count,
        }
      end
      self.midi_tracks = stored
      self.midi_track_idx = 0
    else
      Midi.clear_tracks(self)
    end
    load_notes_list(self, chosen_notes)
    self.length_beats = compute_synced_length(parsed.max_end_beat or 0.0, self.timesig_num)
    local trk_info = (#parsed.note_tracks > 1) and string.format(" (%d tracks)", #parsed.note_tracks) or ""
    self.hud_text = string.format("Imported%s: %d notes, %.1f BPM",
                                  trk_info, #self.notes, self.bpm or 120.0)
  end

  self.playhead_beat = 0.0
  Playback.emit_pos(self)
  if self.playing then
    Playback.seek_beat(self, 0.0)
  end

  self:outlet(4, "imported", {
    path,
    #self.notes,
    explicit_single and 1 or max(1, #parsed.note_tracks),
    self.bpm or 120.0,
    self.length_beats,
  })
  return true, path
end

function Midi.export_to_file(self, raw_path)
  local path = Midi.resolve_path(self, raw_path)
  if path == "" then
    return false, "export_midi: missing file path"
  end

  local track_names = {}
  if self.midi_tracks then
    for i = 1, #self.midi_tracks do
      local t = self.midi_tracks[i]
      if t.name then
        track_names[t.raw_idx] = t.name
      end
    end
  end

  local bytes = Midi.encode(self.notes, {
    bpm         = self.bpm or 120.0,
    timesig_num = self.timesig_num or 4,
    ppq         = 480,
    track_names = track_names,
  })

  local ok, werr = Midi.write_bytes(path, bytes)
  if not ok then
    return false, werr
  end

  self.hud_text = string.format("Exported %d notes -> %s", #self.notes, path:match("([^/\\]+)$") or path)
  self:outlet(4, "exported", { path, #self.notes })
  self._dirty_l3 = true
  self:flush_repaint()
  return true, path
end

return Midi
