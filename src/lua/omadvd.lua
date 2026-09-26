--[[ =========================================================================
  OmaDVD-Player — the interface.

  This script IS the application. mpv is the engine; everything the viewer
  sees is drawn here into mpv's own ASS overlay layer, which means the whole
  player is one process with one window. On a 4 GB dual-core box driving a
  tube, that is not a minor saving -- it is the reason the design works.

  Two facts shape all of it:

  1. mpv has no DVD-menu navigation. `discnav` was removed upstream years ago.
     `dvdnav://` still decrypts and reads the disc, but a disc's own animated
     menu cannot be driven. So OmaDVD does not try: it replaces the disc menu
     with its own, which has the happy side effect of being identical, legible
     and gamepad-navigable on every disc ever pressed.

  2. The output is 480i over composite. Nothing here may draw a stroke thinner
     than two scanlines, use a hairline outline where a flat fill would do, or
     put anything important outside the measured safe area. See docs/DESIGN.md.
========================================================================= ]]

local mp      = require 'mp'
local msg     = require 'mp.msg'
local options = require 'mp.options'
local utils   = require 'mp.utils'

-- ---------------------------------------------------------------------------
-- Options (set by the launcher via --script-opts=omadvd-key=value)
-- ---------------------------------------------------------------------------
local o = {
  disc_id         = "",
  disc_label      = "",
  -- Safe area, as a fraction of each edge. These are MEASURED on a real set,
  -- not the 5% broadcast standard: this tube crops noticeably more at the top.
  -- Broadcast-safe is a floor for an unknown set, not a measurement of yours.
  safe_top        = 0.10,
  safe_bottom     = 0.06,
  safe_left       = 0.05,
  safe_right      = 0.05,
  osd_timeout     = 4,
  -- Seconds paused before the screen blanks itself. A paused DVD is a bright
  -- still image held indefinitely -- the single worst thing you can do to a
  -- phosphor. OmaCRT's own screensaver cannot help here: it is vetoed by a
  -- fullscreen window, and we are always fullscreen.
  blank_after     = 240,
  prefer_alang    = "",
  prefer_slang    = "",
  auto_main_title = true,
  state_dir       = "",
}
options.read_options(o, "omadvd")

-- ---------------------------------------------------------------------------
-- Palette
--
-- ASS colours are written &HBBGGRR& -- blue first. c() takes ordinary RRGGBB
-- so the constants below can be read by a human.
-- ---------------------------------------------------------------------------
local function c(rgb)
  return "&H" .. rgb:sub(5, 6) .. rgb:sub(3, 4) .. rgb:sub(1, 2) .. "&"
end

local COL = {
  -- Warm off-white, not pure white: #FFF blooms and smears on a tube.
  ink     = c("EDEAE2"),
  dim     = c("9A968C"),
  -- Amber for selection and progress. Deliberately NOT red: composite chroma
  -- bleeds worst on saturated red, which is exactly the "no thin red text"
  -- rule in OmaCRT's research notes.
  accent  = c("F0C060"),
  onacc   = c("101008"),
  panel   = c("0E0E0E"),
  row     = c("242424"),
  track   = c("3C3C3C"),
  black   = c("000000"),
}

-- ---------------------------------------------------------------------------
-- Metrics
-- ---------------------------------------------------------------------------
local M = {}

local function round(n) return math.floor(n + 0.5) end

local function measure()
  local w, h = mp.get_osd_size()
  if not w or w <= 0 or not h or h <= 0 then w, h = 720, 480 end
  M.w, M.h = w, h
  M.x0 = round(w * o.safe_left)
  M.x1 = round(w * (1 - o.safe_right))
  M.y0 = round(h * o.safe_top)
  M.y1 = round(h * (1 - o.safe_bottom))
  M.cw = M.x1 - M.x0
  M.ch = M.y1 - M.y0
  -- Scale on the smaller axis, not on height alone. 720x480 is the design
  -- target, but the window is not always that: a compositor can tile it, and
  -- then height-only sizing overflows the width and the header runs into the
  -- clock.
  local sc = math.min(w / 720, h / 480)
  M.sc       = sc
  M.fs_head  = round(36 * sc)
  M.fs_row   = round(29 * sc)
  M.fs_small = round(23 * sc)
  -- Two scanlines at 480 lines. The floor, never the ambition.
  M.stroke   = math.max(4, round(4 * sc))
  M.pad      = round(15 * sc)
  M.rows_max = 6                  -- an item you cannot read does not exist
  M.head_h   = round(M.fs_head * 1.7)
  M.foot_h   = round(M.fs_small * 1.6)
  M.row_gap  = math.max(2, round(h * 0.008))
  local body = M.ch - M.head_h - M.foot_h
  M.row_h    = math.max(round(34 * sc), math.floor(body / M.rows_max) - M.row_gap)
end

-- ---------------------------------------------------------------------------
-- ASS drawing helpers
-- ---------------------------------------------------------------------------
local function esc(s)
  return tostring(s):gsub("\\", "\\\226\136\150"):gsub("{", "("):gsub("}", ")")
                    :gsub("\n", "\\N")
end

local function rect(a, x, y, w, h, col, alpha)
  w, h = round(w), round(h)
  if w <= 0 or h <= 0 then return end
  a[#a + 1] = string.format(
    "{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c%s\\1a&H%02X&\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}",
    round(x), round(y), col, alpha or 0, w, w, h, h)
end

-- align: ASS \an numpad alignment (7 = top-left, 8 = top-centre, 9 = top-right)
local function text(a, x, y, align, size, col, s, extra)
  a[#a + 1] = string.format(
    "{\\an%d\\pos(%d,%d)\\fs%d\\b1\\bord0\\shad0\\q2\\1c%s%s}%s",
    align, round(x), round(y), size, col, extra or "", esc(s))
end

-- Bold sans averages a shade over half the point size per glyph. Good enough
-- to keep a long disc title from running under the clock; libass gives us no
-- measurement to do better.
local function fit(s, size, width)
  local maxn = math.floor(width / (size * 0.55))
  if maxn < 1 then maxn = 1 end
  s = tostring(s)
  if #s <= maxn then return s end
  return s:sub(1, math.max(1, maxn - 1)) .. "..."
end

local overlay = mp.create_osd_overlay("ass-events")

local function paint(parts)
  overlay.res_x, overlay.res_y = M.w, M.h
  overlay.data = table.concat(parts, "\n")
  overlay:update()
end

local function wipe()
  overlay.data = ""
  overlay:update()
end

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------
local function hms(t)
  if not t then return "--:--" end
  t = math.max(0, math.floor(t + 0.5))
  local h, m, s = math.floor(t / 3600), math.floor(t % 3600 / 60), t % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

local LANG = {
  en = "English", es = "Espanol", pt = "Portugues", fr = "Francais",
  de = "Deutsch", it = "Italiano", ja = "Japanese", zh = "Chinese",
  nl = "Nederlands", sv = "Svenska", da = "Dansk", no = "Norsk",
  fi = "Suomi", pl = "Polski", ru = "Russian", ko = "Korean",
}

local function lang_name(code)
  if not code or code == "" then return nil end
  return LANG[code:lower():sub(1, 2)] or code:upper()
end

-- ---------------------------------------------------------------------------
-- Aspect ratio — the load-bearing CRT correction
--
-- The framebuffer is 720x480, which is 3:2 if you assume square pixels. The
-- tube shows that same raster as 4:3. So the framebuffer's pixel aspect is
-- 8:9 -- precisely the BT.601 geometry a DVD is already stored in.
--
-- mpv does not know any of this; it assumes square pixels and would helpfully
-- "correct" a 4:3 disc to 640x480 and pillarbox it, after which the tube
-- stretches the result 12.5% too wide. Telling mpv the display aspect is the
-- true one multiplied by (3/2)/(4/3) = 9/8 cancels the framebuffer's own
-- pixel aspect and lands a 4:3 disc 1:1 on the raster:
--
--     4:3  -> 1.3333 * 1.125 = 1.5  -> 720x480, fills the screen
--     16:9 -> 1.7778 * 1.125 = 2.0  -> 720x360, letterboxed, correct
-- ---------------------------------------------------------------------------
local PAR_FIX = 9 / 8

local ASPECTS = { "auto", "4:3", "16:9", "fill", "native" }
local aspect_i = 1
local src_dar = nil

-- ⚠️ `video-params/aspect` reflects video-aspect-override once we have set it,
-- so reading it back on a later reload compounds the correction (1.33 -> 1.5 ->
-- 1.69 ...). The demuxer's own numbers are immune, so prefer them and keep
-- video-params only as a first-load fallback.
local function read_src_dar()
  local n = mp.get_property_number("track-list/count") or 0
  for i = 0, n - 1 do
    local t = "track-list/" .. i .. "/"
    if mp.get_property(t .. "type") == "video" then
      local w   = mp.get_property_number(t .. "demux-w")
      local h   = mp.get_property_number(t .. "demux-h")
      local par = mp.get_property_number(t .. "demux-par")
      if w and h and h > 0 and par and par > 0 then return (w / h) * par end
      break
    end
  end
  if src_dar then return src_dar end
  return mp.get_property_number("video-params/aspect")
end

local function apply_aspect()
  local mode = ASPECTS[aspect_i]
  local v
  if mode == "native" then
    -- Escape hatch: mpv's own square-pixel interpretation, no correction.
    v = -1
  elseif mode == "4:3" then
    v = (4 / 3) * PAR_FIX
  elseif mode == "16:9" then
    v = (16 / 9) * PAR_FIX
  elseif mode == "fill" then
    v = (M.h > 0) and (M.w / M.h) or 1.5
  else
    local d = src_dar or mp.get_property_number("video-params/aspect")
    v = (d and d > 0) and (d * PAR_FIX) or ((4 / 3) * PAR_FIX)
  end
  mp.set_property_number("video-aspect-override", v)
end

local function aspect_detail()
  local mode = ASPECTS[aspect_i]
  if mode ~= "auto" then return mode end
  local d = src_dar
  if not d then return "auto" end
  if math.abs(d - 4 / 3) < 0.05 then return "auto (4:3)" end
  if math.abs(d - 16 / 9) < 0.06 then return "auto (16:9)" end
  return string.format("auto (%.2f)", d)
end

local DEINT = { "no", "bwdif", "yadif" }
local deint_i = 1

local PANSCAN = { 0, 0.5, 1.0 }
local panscan_i = 1

local night = false

-- ---------------------------------------------------------------------------
-- Per-disc resume
--
-- mpv's watch-later cannot be trusted for a disc: the "filename" is the
-- protocol string, identical for every DVD in the drive. OmaDVD keys its own
-- state on the disc's volume label plus serial, handed in by the launcher.
-- ---------------------------------------------------------------------------
local function state_dir()
  if o.state_dir ~= "" then return o.state_dir end
  local base = os.getenv("XDG_STATE_HOME")
  if not base or base == "" then base = (os.getenv("HOME") or ".") .. "/.local/state" end
  return base .. "/omadvd"
end

local function resume_path()
  local id = o.disc_id
  if id == "" then id = "unknown" end
  id = id:gsub("[^%w%-_%.]", "_")
  return state_dir() .. "/resume-" .. id .. ".txt"
end

local function read_resume()
  if o.disc_id == "" then return nil end
  local f = io.open(resume_path(), "r")
  if not f then return nil end
  local t = {}
  for line in f:lines() do
    local k, v = line:match("^(%w+)=(.*)$")
    if k then t[k] = tonumber(v) or v end
  end
  f:close()
  if t.pos then return t end
  return nil
end

local function save_resume()
  if o.disc_id == "" then return end
  local pos = mp.get_property_number("time-pos")
  local ed  = mp.get_property_number("edition")
  -- Below a minute there is nothing worth coming back to, and near the end the
  -- viewer is done -- offering to resume the credits is just noise.
  if not pos or pos < 60 then return end
  local dur = mp.get_property_number("duration")
  if dur and dur > 0 and pos > dur - 90 then
    os.remove(resume_path())
    return
  end
  mp.command_native({ name = "subprocess", playback_only = false,
                      args = { "mkdir", "-p", state_dir() } })
  local f = io.open(resume_path(), "w")
  if not f then return end
  f:write(string.format("pos=%.3f\nedition=%d\naid=%s\nsid=%s\nlabel=%s\n",
    pos, ed or 0,
    tostring(mp.get_property("aid") or "auto"),
    tostring(mp.get_property("sid") or "no"),
    o.disc_label))
  f:close()
end

-- ---------------------------------------------------------------------------
-- Disc model
-- ---------------------------------------------------------------------------
local disc = { titles = {}, main = nil }

-- dvdnav names each edition "title: 1 (01:26:37.667)". That embedded runtime is
-- the only per-title duration mpv exposes, so it is worth parsing: it is what
-- tells the movie apart from seven three-minute extras.
local function parse_dur(s)
  local h, m, sec = tostring(s):match("(%d+):(%d+):([%d%.]+)")
  if not h then return nil end
  return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(sec)
end

local function read_titles()
  disc.titles = {}
  local n = mp.get_property_number("edition-list/count") or 0
  local best, best_i = -1, nil
  for i = 0, n - 1 do
    local raw = mp.get_property("edition-list/" .. i .. "/title") or ""
    local dur = parse_dur(raw)
    disc.titles[#disc.titles + 1] = { id = i, dur = dur }
    if dur and dur > best then best, best_i = dur, i end
  end
  disc.main = best_i
end

local function title_label(i)
  local t = disc.titles[i + 1]
  local s = "Title " .. (i + 1)
  if t and t.dur then s = s .. "  " .. hms(t.dur) end
  return s
end

local function tracks_of(kind)
  local out = {}
  local n = mp.get_property_number("track-list/count") or 0
  for i = 0, n - 1 do
    local p = "track-list/" .. i .. "/"
    if mp.get_property(p .. "type") == kind then
      out[#out + 1] = {
        id       = mp.get_property_number(p .. "id"),
        lang     = mp.get_property(p .. "lang"),
        selected = mp.get_property_bool(p .. "selected"),
        codec    = mp.get_property(p .. "codec"),
      }
    end
  end
  return out
end

local function track_detail(kind, prop)
  local cur = mp.get_property(prop)
  if cur == "no" or cur == nil then return "Off" end
  for _, t in ipairs(tracks_of(kind)) do
    if t.selected then
      return lang_name(t.lang) or ("Track " .. tostring(t.id))
    end
  end
  return "Off"
end

-- ---------------------------------------------------------------------------
-- UI state
-- ---------------------------------------------------------------------------
local ui = {
  mode  = "hidden",   -- hidden | menu | osd | blank
  stack = {},         -- breadcrumb of menu ids
  sel   = {},         -- per-menu selection, so going back returns to your row
  rows  = {},
  title = "",
  osd_until = 0,
  paused_since = nil,
  drift = 0,
}

local render            -- forward declaration
local osd_timer, tick_timer

local function flash_osd()
  if ui.mode == "menu" then return end
  ui.mode = "osd"
  ui.osd_until = mp.get_time() + o.osd_timeout
  render()
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------
-- Switching title means switching mpv "edition", which RELOADS the encrypted
-- stream -- several seconds on a slim USB drive, since the CSS keys are fetched
-- again. So nothing here can assume it still owns the player afterwards: the
-- intent is recorded and finished off in the file-loaded handler.
local pending = { play = false, seek = nil }

-- ⚠️ On a DVD, `edition` reads back as the string "auto", so asking for it as a
-- number gives nil and every comparison looks like a change. `current-edition`
-- is the resolved index.
local function play_title(i, at)
  local cur = mp.get_property_number("current-edition")
  if i and cur ~= i then
    pending.play = true
    pending.seek = (at and at > 0) and at or nil
    ui.mode = "loading"
    render()
    mp.set_property_number("edition", i)
    return
  end
  if at and at > 0 then mp.commandv("seek", tostring(at), "absolute") end
  ui.stack = {}
  ui.mode = "hidden"
  wipe()
  mp.set_property_bool("pause", false)
end

local function eject()
  save_resume()
  local dev = mp.get_property("dvd-device")
  mp.command_native({ name = "subprocess", playback_only = false, detach = true,
                      args = { "sh", "-c",
                               string.format("sleep 0.4; eject %q >/dev/null 2>&1",
                                             dev ~= "" and dev or "/dev/sr0") } })
  mp.command("quit")
end

local function cycle_deint(d)
  deint_i = ((deint_i - 1 + d) % #DEINT) + 1
  local v = DEINT[deint_i]
  if v == "no" then
    mp.set_property("deinterlace", "no")
    mp.set_property("vf", "")
  else
    mp.set_property("deinterlace", "no")
    mp.set_property("vf", v)
  end
end

local function cycle_night()
  night = not night
  -- Dialogue on a tube's own speakers, at a volume that will not wake a house.
  mp.set_property("af", night and "dynaudnorm=f=250:g=15:p=0.9" or "")
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------
local menus = {}

menus.main = function()
  local rows, r = {}, read_resume()
  if r then
    rows[#rows + 1] = { label = "Resume", detail = hms(r.pos), act = function()
      play_title(tonumber(r.edition), r.pos)
    end }
  end
  -- Play targets the main feature, not whichever title dvdnav happened to open.
  local target = disc.main
  if not o.auto_main_title then target = mp.get_property_number("current-edition") end
  local tdur = target and disc.titles[target + 1] and disc.titles[target + 1].dur
  rows[#rows + 1] = { label = (r and "Start over" or "Play"),
                      detail = tdur and hms(tdur) or "",
                      act = function() play_title(target, 0) end }
  rows[#rows + 1] = { label = "Titles",    detail = tostring(#disc.titles), sub = "titles" }
  rows[#rows + 1] = { label = "Chapters",
                      detail = tostring(mp.get_property_number("chapter-list/count") or 0),
                      sub = "chapters" }
  rows[#rows + 1] = { label = "Audio",     detail = track_detail("audio", "aid"), sub = "audio" }
  rows[#rows + 1] = { label = "Subtitles", detail = track_detail("sub", "sid"),   sub = "subs" }
  rows[#rows + 1] = { label = "Picture",   detail = aspect_detail(),              sub = "picture" }
  rows[#rows + 1] = { label = "Eject disc", detail = "", act = eject }
  rows[#rows + 1] = { label = "Quit",       detail = "", act = function()
    save_resume(); mp.command("quit")
  end }
  return rows, (o.disc_label ~= "" and o.disc_label or "DVD")
end

menus.titles = function()
  local rows = {}
  local cur = mp.get_property_number("current-edition")
  for i, t in ipairs(disc.titles) do
    local id = t.id
    rows[#rows + 1] = {
      label  = "Title " .. i .. (id == disc.main and "   (main feature)" or ""),
      detail = t.dur and hms(t.dur) or "",
      mark   = (id == cur),
      act    = function() play_title(id, 0) end,
    }
  end
  if #rows == 0 then rows[1] = { label = "No titles found", off = true } end
  return rows, "Titles"
end

menus.chapters = function()
  local rows = {}
  local n = mp.get_property_number("chapter-list/count") or 0
  local cur = mp.get_property_number("chapter")
  for i = 0, n - 1 do
    local t = mp.get_property_number("chapter-list/" .. i .. "/time")
    rows[#rows + 1] = {
      label  = "Chapter " .. (i + 1),
      detail = hms(t),
      mark   = (cur == i),
      act    = function()
        mp.set_property_number("chapter", i)
        mp.set_property_bool("pause", false)
      end,
    }
  end
  if n == 0 then rows[1] = { label = "No chapters on this title", off = true } end
  return rows, "Chapters"
end

menus.audio = function()
  local rows = {}
  for _, t in ipairs(tracks_of("audio")) do
    local id = t.id
    rows[#rows + 1] = {
      label  = lang_name(t.lang) or ("Track " .. tostring(id)),
      detail = (t.codec or ""):upper(),
      mark   = t.selected,
      act    = function() mp.set_property_number("aid", id) end,
    }
  end
  rows[#rows + 1] = { label = "Night mode", detail = night and "ON" or "off",
                      keep = true, act = cycle_night }
  return rows, "Audio"
end

menus.subs = function()
  local rows = {}
  local off = (mp.get_property("sid") == "no")
  rows[#rows + 1] = { label = "Off", detail = "", mark = off,
                      act = function() mp.set_property("sid", "no") end }
  for _, t in ipairs(tracks_of("sub")) do
    local id = t.id
    rows[#rows + 1] = {
      label  = lang_name(t.lang) or ("Track " .. tostring(id)),
      detail = "",
      mark   = t.selected,
      act    = function() mp.set_property_number("sid", id) end,
    }
  end
  return rows, "Subtitles"
end

menus.picture = function()
  return {
    { label = "Aspect", detail = aspect_detail(), keep = true, act = function()
        aspect_i = (aspect_i % #ASPECTS) + 1; apply_aspect()
      end },
    { label = "Deinterlace", detail = DEINT[deint_i], keep = true, act = function()
        cycle_deint(1)
      end },
    { label = "Fill screen", detail = string.format("%.0f%%", PANSCAN[panscan_i] * 100),
      keep = true, act = function()
        panscan_i = (panscan_i % #PANSCAN) + 1
        mp.set_property_number("panscan", PANSCAN[panscan_i])
      end },
  }, "Picture"
end

local function rebuild()
  local id = ui.stack[#ui.stack] or "main"
  local rows, title = (menus[id] or menus.main)()
  ui.rows, ui.title = rows, title or id
  local sel = ui.sel[id] or 1
  if sel > #rows then sel = #rows end
  if sel < 1 then sel = 1 end
  ui.sel[id] = sel
end

local function open_menu(id)
  ui.stack[#ui.stack + 1] = id
  rebuild()
  ui.mode = "menu"
  render()
end

local function show_menu()
  ui.wasplaying = not mp.get_property_bool("pause")
  mp.set_property_bool("pause", true)
  ui.stack = {}
  ui.mode = "menu"
  open_menu("main")
end

local function close_menu(resume_play)
  ui.stack = {}
  ui.mode = "hidden"
  if resume_play and ui.wasplaying then mp.set_property_bool("pause", false) end
  wipe()
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------
local function draw_blank(a)
  -- Total black, plus one dim label that drifts so even IT cannot burn in.
  rect(a, 0, 0, M.w, M.h, COL.black, 0)
  local n = ui.drift
  local x = M.x0 + (n % 5) * (M.cw / 6)
  local y = M.y0 + (math.floor(n / 5) % 4) * (M.ch / 5)
  text(a, x, y, 7, M.fs_small, c("3A3A3A"), "PAUSED")
end

local function draw_loading(a)
  rect(a, 0, 0, M.w, M.h, COL.black, 0x20)
  local h = round(M.fs_head * 2.2)
  local y = round((M.h - h) / 2)
  rect(a, M.x0, y, M.cw, h, COL.panel, 0x10)
  text(a, M.w / 2, y + round((h - M.fs_head) / 2), 8, M.fs_head, COL.accent, "Loading...")
end

local function draw_osd(a)
  local pos = mp.get_property_number("time-pos") or 0
  local dur = mp.get_property_number("duration") or 0
  local paused = mp.get_property_bool("pause")
  local bar_h = math.max(M.stroke * 2, round(M.h * 0.018))
  local band_h = round(M.fs_row * 1.5) + bar_h + M.pad * 2 + M.fs_small
  local y = M.y1 - band_h

  -- A flat panel rather than an outline or a gradient: solid fills are what
  -- survive an interlaced analog path intact.
  rect(a, M.x0, y, M.cw, band_h, COL.panel, 0x28)

  local ty = y + M.pad
  local ed = mp.get_property_number("current-edition")
  local head = (o.disc_label ~= "" and o.disc_label or "DVD")
  if ed then head = head .. "   Title " .. (ed + 1) end
  local ch = mp.get_property_number("chapter")
  if ch and ch >= 0 then head = head .. "   Chapter " .. (ch + 1) end
  text(a, M.x0 + M.pad, ty, 7, M.fs_small, COL.dim, head)

  ty = ty + M.fs_small + round(M.pad * 0.5)
  text(a, M.x0 + M.pad, ty, 7, M.fs_row, COL.ink,
       (paused and "|| " or "> ") .. hms(pos))
  text(a, M.x1 - M.pad, ty, 9, M.fs_row, COL.dim, hms(dur))

  ty = ty + M.fs_row * 1.25
  local bw = M.cw - M.pad * 2
  rect(a, M.x0 + M.pad, ty, bw, bar_h, COL.track, 0x10)
  if dur > 0 then
    rect(a, M.x0 + M.pad, ty, bw * math.min(1, pos / dur), bar_h, COL.accent, 0x00)
  end
end

local function draw_menu(a)
  -- Dim the video rather than hiding it: you can still see where you are.
  rect(a, 0, 0, M.w, M.h, COL.black, 0x40)
  rect(a, M.x0, M.y0, M.cw, M.ch, COL.panel, 0x18)

  local id  = ui.stack[#ui.stack] or "main"
  local sel = ui.sel[id] or 1

  local clock = os.date("%H:%M")
  local clock_w = M.fs_small * 0.55 * (#clock + 2)
  text(a, M.x0 + M.pad, M.y0 + round(M.pad * 0.6), 7, M.fs_head, COL.ink,
       fit(ui.title, M.fs_head, M.cw - M.pad * 2 - clock_w))
  text(a, M.x1 - M.pad, M.y0 + round(M.pad * 0.6), 9, M.fs_small, COL.dim, clock)

  -- Scroll so the selected row is always on screen.
  local first = 1
  if #ui.rows > M.rows_max then
    first = math.min(math.max(1, sel - math.floor(M.rows_max / 2)), #ui.rows - M.rows_max + 1)
  end

  local y = M.y0 + M.head_h
  for i = first, math.min(#ui.rows, first + M.rows_max - 1) do
    local row = ui.rows[i]
    local on  = (i == sel)
    rect(a, M.x0 + M.pad, y, M.cw - M.pad * 2, M.row_h,
         on and COL.accent or COL.row, on and 0x00 or 0x30)
    local fg = on and COL.onacc or (row.off and COL.dim or COL.ink)
    local ty = y + round((M.row_h - M.fs_row) / 2)
    local label = (row.mark and "* " or "") .. row.label
    if row.sub then label = label .. "  >" end
    text(a, M.x0 + M.pad * 2, ty, 7, M.fs_row, fg, label)
    if row.detail and row.detail ~= "" then
      text(a, M.x1 - M.pad * 2, ty, 9, M.fs_row, on and COL.onacc or COL.dim, row.detail)
    end
    y = y + M.row_h + M.row_gap
  end

  if #ui.rows > M.rows_max then
    text(a, M.x1 - M.pad, M.y1 - M.foot_h, 9, M.fs_small, COL.dim,
         string.format("%d/%d", sel, #ui.rows))
  end
  text(a, M.x0 + M.pad, M.y1 - M.foot_h, 7, M.fs_small, COL.dim,
       (#ui.stack > 1) and "Enter select    Esc back" or "Enter select    Esc close")
end

render = function()
  measure()
  local a = {}
  if ui.mode == "blank" then
    draw_blank(a)
  elseif ui.mode == "loading" then
    draw_loading(a)
  elseif ui.mode == "menu" then
    draw_menu(a)
  elseif ui.mode == "osd" then
    draw_osd(a)
  else
    wipe()
    return
  end
  paint(a)
end

-- ---------------------------------------------------------------------------
-- Input
--
-- One key does the obvious thing in both contexts -- the menu when it is open,
-- the transport when it is not. That is what lets a three-button gamepad or a
-- couch keyboard drive the whole player without a modifier in sight.
-- ---------------------------------------------------------------------------
local function wake()
  if ui.mode == "blank" then
    ui.mode = "hidden"
    wipe()
    return true
  end
  return false
end

local function move(d)
  local id = ui.stack[#ui.stack] or "main"
  local n = #ui.rows
  if n == 0 then return end
  local i = ui.sel[id] or 1
  for _ = 1, n do
    i = ((i - 1 + d) % n) + 1
    if not ui.rows[i].off then break end
  end
  ui.sel[id] = i
  render()
end

local function activate()
  local id = ui.stack[#ui.stack] or "main"
  local row = ui.rows[ui.sel[id] or 1]
  if not row or row.off then return end
  if row.sub then open_menu(row.sub); return end
  if row.act then
    row.act()
    if row.keep then
      -- A toggle: stay put so it can be cycled without reopening the menu.
      rebuild(); render()
    else
      close_menu(false)
    end
  end
end

local function back()
  if #ui.stack > 1 then
    table.remove(ui.stack)
    rebuild()
    render()
  else
    close_menu(true)
  end
end

local function bind(key, name, fn, rep)
  mp.add_forced_key_binding(key, "omadvd-" .. name, function()
    if wake() then return end
    fn()
  end, rep and { repeatable = true } or nil)
end

bind("UP", "up", function()
  if ui.mode == "menu" then move(-1)
  else mp.commandv("add", "chapter", "1"); flash_osd() end
end, true)

bind("DOWN", "down", function()
  if ui.mode == "menu" then move(1)
  else mp.commandv("add", "chapter", "-1"); flash_osd() end
end, true)

bind("LEFT", "left", function()
  if ui.mode == "menu" then back()
  else mp.commandv("seek", "-10"); flash_osd() end
end, true)

bind("RIGHT", "right", function()
  if ui.mode == "menu" then activate()
  else mp.commandv("seek", "10"); flash_osd() end
end, true)

bind("ENTER", "select", function()
  if ui.mode == "menu" then activate() else show_menu() end
end)
bind("KP_ENTER", "select2", function()
  if ui.mode == "menu" then activate() else show_menu() end
end)

bind("ESC", "back", function()
  if ui.mode == "menu" then back() else show_menu() end
end)
bind("BS", "back2", function()
  if ui.mode == "menu" then back() else flash_osd() end
end)

bind("SPACE", "playpause", function()
  if ui.mode == "menu" then activate(); return end
  mp.commandv("cycle", "pause")
  flash_osd()
end)

bind("m", "menu", function()
  if ui.mode == "menu" then close_menu(true) else show_menu() end
end)

bind("i", "info", function() flash_osd() end)
bind("a", "audio", function() mp.commandv("cycle", "audio"); flash_osd() end)
bind("j", "sub", function() mp.commandv("cycle", "sub"); flash_osd() end)
bind("d", "deint", function() cycle_deint(1); flash_osd() end)
bind("q", "quit", function() save_resume(); mp.command("quit") end)
bind("e", "eject", eject)

-- ---------------------------------------------------------------------------
-- Burn-in watchdog
-- ---------------------------------------------------------------------------
tick_timer = mp.add_periodic_timer(1, function()
  local paused = mp.get_property_bool("pause")
  if paused and ui.mode ~= "menu" and ui.mode ~= "loading" then
    ui.paused_since = ui.paused_since or mp.get_time()
    if mp.get_time() - ui.paused_since >= o.blank_after then
      if ui.mode ~= "blank" then ui.mode = "blank"; ui.drift = 0 end
      ui.drift = ui.drift + 1
      render()
      return
    end
  else
    ui.paused_since = nil
    if ui.mode == "blank" then ui.mode = "hidden"; wipe() end
  end
  if ui.mode == "loading" then
    render()
  elseif ui.mode == "osd" then
    if mp.get_time() > ui.osd_until then
      ui.mode = "hidden"; wipe()
    else
      render()
    end
  elseif ui.mode == "menu" then
    render()   -- keeps the clock and live details honest
  end
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
local ui_started  = false
local title_fixed = false

local function pick_lang(kind, prop, want)
  if want == "" then return end
  for _, t in ipairs(tracks_of(kind)) do
    if t.lang and t.lang:lower():sub(1, 2) == want:lower():sub(1, 2) then
      mp.set_property_number(prop, t.id)
      return
    end
  end
end

mp.register_event("file-loaded", function()
  measure()
  read_titles()
  src_dar = read_src_dar()
  apply_aspect()

  -- Finishing a title change started in play_title().
  if pending.play then
    pending.play = false
    if pending.seek then
      mp.commandv("seek", tostring(pending.seek), "absolute")
      pending.seek = nil
    end
    ui.stack = {}
    ui.mode = "hidden"
    wipe()
    mp.set_property_bool("pause", false)
    return
  end

  if not ui_started then
    ui_started = true
    -- A Region 4 disc defaults to Spanish audio, a Region 2 one to German.
    -- Whatever the disc prefers, the viewer's preference wins if they set one.
    pick_lang("audio", "aid", o.prefer_alang)
    pick_lang("sub",   "sid", o.prefer_slang)
    -- ⚠️ Deliberately NOT jumping to the main title here. dvdnav opens
    -- whichever title it likes, and correcting that up front costs a full
    -- stream reload -- seconds of black screen before anything is on screen,
    -- and the menu only appears once it lands. The menu opens on whatever
    -- loaded instead, and its Play row targets the main feature, so the reload
    -- happens when the viewer asked for it and has a "Loading..." panel to
    -- look at.
    show_menu()
  end
end)

mp.observe_property("pause", "bool", function(_, v)
  if v == false then ui.paused_since = nil end
end)

mp.observe_property("osd-dimensions", "native", function()
  if ui.mode ~= "hidden" then render() end
end)

mp.register_event("end-file", function()
  -- A finished title returns to the menu; the player is the place you sit.
  if ui_started then
    mp.add_timeout(0.2, function()
      if mp.get_property("idle-active") ~= "yes" then show_menu() end
    end)
  end
end)

mp.register_event("shutdown", function() save_resume() end)

msg.info("OmaDVD-Player UI ready; disc=" .. (o.disc_label ~= "" and o.disc_label or "?"))
