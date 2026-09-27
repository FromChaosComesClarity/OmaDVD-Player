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
  -- Look the disc up online. Only the volume label leaves the machine, and
  -- only to Wikipedia; everything is cached per disc afterwards.
  online          = true,
  state_dir       = "",
}
options.read_options(o, "omadvd")

-- The launcher hands us the disc it found, but a disc is not a launch-time
-- constant: the viewer can eject one and put another in without leaving the
-- player, and everything keyed on disc identity (the resume file, the header)
-- has to follow. These are refreshed on every load.
local disc_id    = o.disc_id or ""
local disc_label = o.disc_label or ""

local function shell_async(args, cb)
  mp.command_native_async(
    { name = "subprocess", args = args, capture_stdout = true, playback_only = false },
    function(ok, res)
      if cb then cb(ok and res ~= nil and res.status == 0, (res and res.stdout) or "") end
    end)
end

local function device()
  local d = mp.get_property("dvd-device")
  if not d or d == "" then return "/dev/sr0" end
  return d
end

-- ⚠️ `-P` (key="value") rather than plain columns: a disc label can contain
-- spaces, and CONQUEST OF PLANET OF THE APES parsed positionally is four
-- fields of nonsense.
--
-- ⚠️ And do NOT use SIZE to decide whether a disc is present. With the tray
-- open this drive still reports the last disc's size -- 7594151936 with
-- LABEL="" UUID="" -- so a size test says "disc!" at an empty open tray and the
-- player sits there failing to open it every two seconds. UUID and LABEL do go
-- empty, so they are the honest signal. A disc still spinning up reads empty
-- too, which costs one more two-second poll and nothing else.
local function probe_disc(cb)
  shell_async({ "lsblk", "-dn", "-b", "-P", "-o", "LABEL,UUID,SIZE", device() },
    function(ok, out)
      if not ok then cb(nil) return end
      local label = out:match('LABEL="(.-)"') or ""
      local uuid  = out:match('UUID="(.-)"')  or ""
      local size  = tonumber(out:match('SIZE="(%d*)"') or "0") or 0
      cb({ label = label, uuid = uuid, size = size,
           present = (uuid ~= "" or label ~= "") and size > 0 })
    end)
end

-- ---------------------------------------------------------------------------
-- Palette
--
-- ASS colours are written &HBBGGRR& -- blue first. c() takes ordinary RRGGBB
-- so the constants below can be read by a human.
-- ---------------------------------------------------------------------------
-- ⚠️ Declared up here, not next to its definition: the metadata callbacks
-- below repaint when an answer arrives, and a local declared later would be
-- compiled as a global lookup in them -- nil at runtime, with nothing from
-- luac to warn you.
local render

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

-- Bold sans measures about 0.42 of the point size per glyph on this font --
-- checked against a real render rather than guessed. 0.50 keeps headroom for a
-- wide string without truncating titles that would have fitted; libass gives us
-- no way to measure properly.
local function fit(s, size, width)
  local maxn = math.floor(width / (size * 0.50))
  if maxn < 1 then maxn = 1 end
  s = tostring(s)
  if #s <= maxn then return s end
  return s:sub(1, math.max(1, maxn - 1)) .. "..."
end

local function wrap(str, size, width, max_lines)
  local per = math.max(8, math.floor(width / (size * 0.52)))
  local out, line = {}, ""
  for word in tostring(str or ""):gmatch("%S+") do
    if line == "" then line = word
    elseif #line + 1 + #word <= per then line = line .. " " .. word
    else
      out[#out + 1] = line
      line = word
      if max_lines and #out >= max_lines then break end
    end
  end
  if line ~= "" and (not max_lines or #out < max_lines) then out[#out + 1] = line end
  if max_lines and #out == max_lines then
    out[#out] = out[#out]:sub(1, math.max(1, per - 1)) .. "..."
  end
  return out
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
  local id = disc_id
  if id == nil or id == "" then id = "unknown" end
  id = id:gsub("[^%w%-_%.]", "_")
  return state_dir() .. "/resume-" .. id .. ".txt"
end

local function read_resume()
  if disc_id == nil or disc_id == "" then return nil end
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
  if disc_id == nil or disc_id == "" then return end
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
    disc_label))
  f:close()
end

-- ---------------------------------------------------------------------------
-- Disc metadata
--
-- A DVD carries almost nothing: a volume label, a serial number, and the
-- runtime of each title. There is no title, no year, no cover. So this is a
-- *search*, not a lookup, and it has to survive labels like
-- CONQUEST_OF_PLANET_OF_THE_APES -- which is not the film's name (the real one
-- has another "the" in it).
--
-- Wikipedia's search absorbs that: it returns the right article for the
-- mangled label. From the article we get a plain-text synopsis and a Wikidata
-- id; from Wikidata, year, runtime, director and the IMDb id.
--
-- ⚠️ The cover needs one non-obvious step. `prop=pageimages` returns nothing
-- for a film, because a poster is a non-free file and pageimages only serves
-- freely-licensed ones. `prop=images` lists every image on the page including
-- that poster -- alongside Wikipedia's own furniture (edit pencils, category
-- symbols, Wikiquote logos), which is why the filename is scored against the
-- article title rather than simply taking the first.
--
-- Everything here is optional and entirely asynchronous. No network, no curl,
-- a disc nobody wrote an article about: the player behaves exactly as it did
-- before, and nothing waits on any of it.
-- ---------------------------------------------------------------------------
local UA = "OmaDVD-Player/1.1 (+https://github.com/FromChaosComesClarity/OmaDVD-Player)"
local WP = "https://en.wikipedia.org/w/api.php"

local meta = {}          -- title, year, runtime, director, genres, overview, poster
local candidates = {}    -- other things this disc might be, for the picker
local meta_state = "off" -- off | looking | done
local have_curl = nil

local function meta_dir() return state_dir() .. "/meta" end

local function meta_file(ext)
  local id = disc_id
  if id == nil or id == "" then id = "unknown" end
  id = id:gsub("[^%w%-_%.]", "_")
  return meta_dir() .. "/" .. id .. "." .. ext
end

local function urlenc(str)
  return (tostring(str):gsub("[^%w%-%.%_%~]", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

local function fetch_json(url, cb)
  shell_async({ "curl", "-sL", "--max-time", "12", "-A", UA, url }, function(ok, out)
    if not ok or not out or out == "" then cb(nil) return end
    local parsed = utils.parse_json(out)
    cb(parsed)
  end)
end

local function first_page(j)
  if not j or not j.query or not j.query.pages then return nil end
  for _, page in pairs(j.query.pages) do return page end
  return nil
end

-- Wikipedia's own furniture, which appears on nearly every article and is never
-- what we want.
local function is_chrome(name)
  local n = name:lower()
  if n:sub(-4) == ".svg" then return true end
  for _, bad in ipairs({ "logo", "icon", "symbol", "userbox", "ambox", "commons",
                         "question_book", "edit-", "wiki", "folder", "padlock",
                         "disambig", "portal", "generic" }) do
    if n:find(bad, 1, true) then return true end
  end
  return false
end

-- Score a filename against the article title by shared words. The poster for
-- "Conquest of the Planet of the Apes" is filed as
-- "Conquest of the planet of the apes.jpg" -- different case, same words.
-- The other direction from name_score: how much of a release's title is
-- present in the disc label. RHCP_OFF_THE_MAP contains every significant word
-- of "Off the Map", which is enough to pick it without asking anyone.
local STOP = { the = true, and_ = true, a = true, of = true, at = true,
               in_ = true, on = true, to = true, for_ = true }
local function label_score(work, label)
  local lab = label:lower()
  local hits, total = 0, 0
  for word in work:lower():gmatch("[%w]+") do
    if #word >= 3 and not STOP[word] then
      total = total + 1
      if lab:find(word, 1, true) then hits = hits + 1 end
    end
  end
  if total < 2 then return 0 end     -- one word is a coincidence, not a match
  return hits / total
end

local function name_score(file, title)
  local f = file:lower():gsub("^file:", ""):gsub("%.%w+$", "")
  local hits, total = 0, 0
  for word in title:lower():gmatch("%a+") do
    if #word > 2 then
      total = total + 1
      if f:find(word, 1, true) then hits = hits + 1 end
    end
  end
  if total == 0 then return 0 end
  return hits / total
end

-- Turn whatever we downloaded into the exact BGRA buffer overlay-add wants.
-- mpv is already here and can do it, so the AppImage needs no extra binary.
local POSTER_W, POSTER_H = 176, 250

local function make_poster_bitmap(jpg, cb)
  -- The AppImage's AppRun exports OMADVD_MPV; from source it is just mpv.
  local mpv = os.getenv("OMADVD_MPV") or "mpv"
  shell_async({ mpv, "--no-config", jpg, "--no-audio", "--really-quiet",
                -- ⚠️ overlay-add needs a buffer of exactly one size, but a
                -- poster is not that shape. force_original_aspect_ratio=decrease
                -- plus pad fits it inside the box without stretching it, and
                -- keeps the byte count fixed.
                "--vf=scale=" .. POSTER_W .. ":" .. POSTER_H ..
                ":force_original_aspect_ratio=decrease," ..
                "pad=" .. POSTER_W .. ":" .. POSTER_H .. ":(ow-iw)/2:(oh-ih)/2," ..
                "format=bgra",
                "--of=rawvideo", "--ovc=rawvideo", "--frames=1",
                "--o=" .. meta_file("bgra") }, function(ok)
    cb(ok)
  end)
end

local function meta_save()
  meta.candidates = candidates
  mp.command_native({ name = "subprocess", playback_only = false,
                      args = { "mkdir", "-p", meta_dir() } })
  local f = io.open(meta_file("json"), "w")
  if f then f:write(utils.format_json(meta)) f:close() end
end

local function meta_load_cached()
  local f = io.open(meta_file("json"), "r")
  if not f then return false end
  local body = f:read("*a"); f:close()
  local t = utils.parse_json(body or "")
  if not t or not t.title then return false end
  meta = t
  candidates = t.candidates or {}
  meta_state = "done"
  return true
end

local function poster_ready()
  local f = io.open(meta_file("bgra"), "rb")
  if not f then return false end
  local n = f:seek("end"); f:close()
  return n == POSTER_W * POSTER_H * 4
end

-- ⚠️ ASS cannot draw an image, so the cover is a second, separate overlay --
-- mpv's overlay-add, fed the raw BGRA buffer we converted earlier. It is
-- positioned in window pixels, which match our ASS units because the overlay
-- resolution is set to the window size.
local POSTER_ID = 7
local poster_shown = false

local function poster_hide()
  if not poster_shown then return end
  mp.commandv("overlay-remove", POSTER_ID)
  poster_shown = false
end

local function poster_show(x, y)
  if not poster_ready() then return false end
  mp.commandv("overlay-add", POSTER_ID, math.floor(x), math.floor(y),
              meta_file("bgra"), 0, "bgra", POSTER_W, POSTER_H, POSTER_W * 4)
  poster_shown = true
  return true
end

-- ── the chain ───────────────────────────────────────────────────────────────
local meta_lookup   -- assigned below; meta_choose calls it

local function step_poster(images, title)
  local best, best_score = nil, 0.45   -- below this it is probably not the film
  local first_raster = nil
  for _, im in ipairs(images or {}) do
    local name = im.title or ""
    if not is_chrome(name) then
      if not first_raster then first_raster = name end
      local sc = name_score(name, title)
      if sc > best_score then best, best_score = name, sc end
    end
  end
  -- Scoring by shared words only works when the file is named after the
  -- article, which is usual for films and not at all usual elsewhere: the cover
  -- of "Live at Budokan (Dream Theater album)" is filed under neither. Fall
  -- back to the first non-chrome image on the page, which is the infobox
  -- image -- the cover -- because prop=images returns them in page order.
  if not best then best = first_raster end
  if not best then meta_state = "done"; meta_save(); return end

  fetch_json(WP .. "?action=query&titles=" .. urlenc(best) ..
             "&prop=imageinfo&iiprop=url|mime&iiurlwidth=400&format=json", function(j)
    local page = first_page(j)
    local info = page and page.imageinfo and page.imageinfo[1]
    local url  = info and (info.thumburl or info.url)
    if not url then meta_state = "done"; meta_save(); return end
    mp.command_native({ name = "subprocess", playback_only = false,
                        args = { "mkdir", "-p", meta_dir() } })
    shell_async({ "curl", "-sL", "--max-time", "20", "-A", UA,
                  "-o", meta_file("jpg"), url }, function(ok)
      if not ok then meta_state = "done"; meta_save(); return end
      make_poster_bitmap(meta_file("jpg"), function(converted)
        meta.poster = converted and true or nil
        meta_state = "done"
        meta_save()
        render()
      end)
    end)
  end)
end

-- A disc labelled DREAMTHEATER resolves to the *band*, and no amount of search
-- tuning turns that into "Metropolis 2000: Scenes from New York" -- the disc
-- simply does not say. But Wikidata knows every video album that band released,
-- and there are five. Five rows on a screen is an answer; a text file is not.
--
-- P175 is "performer", so this returns nothing at all for a film -- which makes
-- it self-limiting: no need to work out first whether the hit is a group.
local lookup_label = ""
local step_release      -- defined below; step_works hands the winner to it

local function fetch_page(title, cb)
  fetch_json(WP .. "?action=query&titles=" .. urlenc(title) ..
             "&prop=extracts|pageprops|images&exintro=1&explaintext=1" ..
             "&imlimit=40&format=json", function(j) cb(first_page(j)) end)
end

local function step_works(qid, done)
  if not qid then done() return end
  local q = "SELECT ?item ?label ?typeLabel WHERE { ?item wdt:P175 wd:" .. qid ..
            " . ?item wdt:P31 ?type . ?item rdfs:label ?label ." ..
            " FILTER(lang(?label)='en') ?type rdfs:label ?typeLabel ." ..
            " FILTER(lang(?typeLabel)='en') } LIMIT 400"
  shell_async({ "curl", "-s", "--max-time", "20", "-A", UA,
                "-H", "Accept: application/sparql-results+json",
                "-G", "--data-urlencode", "query=" .. q,
                "https://query.wikidata.org/sparql" }, function(ok, out)
    if ok and out ~= "" then
      local j = utils.parse_json(out)
      local rows = j and j.results and j.results.bindings
      local works = {}
      for _, r in ipairs(rows or {}) do
        local ty = (r.typeLabel and r.typeLabel.value or ""):lower()
        -- ⚠️ "concert" also matches "concert tour", and a band has far more
        -- tours than discs -- 30 of them here, burying the five things the
        -- viewer might actually be holding. A tour is not a disc.
        local wanted = (ty:find("video album") or ty:find("film")) and not ty:find("tour")
        if wanted then
          local nm  = r.label and r.label.value
          local uri = r.item and r.item.value or ""
          if nm then
            local seen = false
            for _, w in ipairs(works) do if w.name == nm then seen = true break end end
            if not seen then
              works[#works + 1] = { name = nm, qid = uri:match("(Q%d+)$") }
            end
          end
        end
      end
      -- If one of the releases is named in the disc label, that IS the disc --
      -- no need to ask. Re-running the lookup on its own title gets its year,
      -- runtime, synopsis and cover, exactly as if the label had been good.
      local names = {}
      for _, w in ipairs(works) do names[#names + 1] = w.name end

      local best, best_score = nil, 0.79
      for _, w in ipairs(works) do
        local sc = label_score(w.name, lookup_label)
        if sc > best_score then best, best_score = w, sc end
      end
      if best then
        -- ⚠️ Do NOT re-search Wikipedia for the winner's name. "Off the Map"
        -- searches straight to a disambiguation page, and the whole point was
        -- to stop guessing. We already hold the release's Wikidata id, so go to
        -- the article it actually points at.
        candidates = names
        step_release(best.qid, best.name)
        return
      end

      -- Releases first: if the label resolved to a band, the disc is one of
      -- these, and the search hits behind them are mostly noise.
      if #works > 0 then
        local merged = {}
        for _, w in ipairs(names) do merged[#merged + 1] = w end
        for _, c in ipairs(candidates) do
          local seen = false
          for _, m in ipairs(merged) do if m == c then seen = true break end end
          if not seen and #merged < 14 then merged[#merged + 1] = c end
        end
        candidates = merged
      end
    end
    done()
  end)
end

local function step_wikidata(qid, images, title)
  if not qid then step_poster(images, title) return end
  fetch_json("https://www.wikidata.org/wiki/Special:EntityData/" .. qid .. ".json",
  function(j)
    local ent = j and j.entities and j.entities[qid]
    local claims = ent and ent.claims
    if claims then
      local function first(prop, key)
        local c = claims[prop]
        local v = c and c[1] and c[1].mainsnak and c[1].mainsnak.datavalue
        v = v and v.value
        if type(v) == "table" then return v[key] end
        return v
      end
      local when = first("P577", "time")
      if when then meta.year = tostring(when):match("(%d%d%d%d)") end
      local mins = first("P2047", "amount")
      -- ⚠️ The extra parentheses are load-bearing. gsub returns TWO values, and
      -- tonumber's second argument is a numeric base -- so tonumber(s:gsub(...))
      -- passes the replacement count as the base and throws "base out of range".
      if mins then meta.runtime = tonumber((tostring(mins):gsub("%+", ""))) end
      meta.imdb = first("P345")
    end
    step_poster(images, title)
  end)
end

-- A release we identified ourselves: its Wikidata item gives the year, the
-- runtime and -- through the sitelink -- the exact article, with no search and
-- therefore no chance of landing on a disambiguation page. ("Off the Map"
-- searches straight to one, which is how this function came to exist.)
step_release = function(wqid, name)
  meta.title = name
  if not wqid then meta_state = "done"; meta_save(); render(); return end
  fetch_json("https://www.wikidata.org/wiki/Special:EntityData/" .. wqid .. ".json",
  function(j)
    local ent = j and j.entities and j.entities[wqid]
    if ent then
      local claims = ent.claims or {}
      local function first(prop, key)
        local c = claims[prop]
        local v = c and c[1] and c[1].mainsnak and c[1].mainsnak.datavalue
        v = v and v.value
        if type(v) == "table" then return v[key] end
        return v
      end
      local when = first("P577", "time")
      if when then meta.year = tostring(when):match("(%d%d%d%d)") end
      local mins = first("P2047", "amount")
      if mins then meta.runtime = tonumber((tostring(mins):gsub("%+", ""))) end
      meta.imdb = first("P345")
      local sl = ent.sitelinks and ent.sitelinks.enwiki
      if sl and sl.title then meta.title = sl.title end
    end
    render()
    fetch_page(meta.title, function(page)
      if page then
        local ex = page.extract
        if ex and ex ~= "" then meta.overview = ex end
        step_poster(page.images, meta.title)
      else
        meta_state = "done"; meta_save(); render()
      end
    end)
  end)
end

meta_lookup = function(label)
  if meta_state == "looking" then return end
  meta_state = "looking"
  lookup_label = label
  meta = {}

  fetch_json(WP .. "?action=query&list=search&srsearch=" .. urlenc(label) ..
             "&srlimit=8&format=json", function(j)
    local hits = j and j.query and j.query.search
    if not hits or not hits[1] then meta_state = "done" return end
    -- ⚠️ "RHCP OFF THE MAP" puts "List of Red Hot Chili Peppers band members"
    -- first. A list, a disambiguation page or a discography is never the disc,
    -- and worse, it is a dead end: only a real entity has releases hanging off
    -- it, so picking one loses the works query too.
    local function junk(t)
      local n = t:lower()
      return n:find("^list of") or n:find("disambiguation") or n:find("discography")
    end
    local title
    for _, h in ipairs(hits) do
      if not junk(h.title) then title = h.title break end
    end
    title = title or hits[1].title
    -- Keep the also-rans. The top hit is a guess, and a disc labelled with
    -- nothing but a band name will guess wrong -- so the viewer needs a way to
    -- say "no, it is that one" without leaving the sofa.
    candidates = {}
    for _, h in ipairs(hits) do candidates[#candidates + 1] = h.title end
    meta.title = title

    fetch_json(WP .. "?action=query&titles=" .. urlenc(title) ..
               "&prop=extracts|pageprops|images&exintro=1&explaintext=1" ..
               "&imlimit=40&format=json", function(j2)
      local page = first_page(j2)
      if page then
        local ex = page.extract
        if ex and ex ~= "" then meta.overview = ex end
        local qid = page.pageprops and page.pageprops.wikibase_item
        render()
        step_works(qid, function() step_wikidata(qid, page.images, title) end)
      else
        meta_state = "done"
      end
    end)
  end)
end

-- The viewer's answer is written to the same <serial>.name file the manual
-- override uses, so a choice made once on screen survives every future
-- insertion of that disc -- keyed on the disc's own serial number, which is the
-- one thing a DVD does tell us reliably.
local function meta_choose(name)
  mp.command_native({ name = "subprocess", playback_only = false,
                      args = { "mkdir", "-p", meta_dir() } })
  local f = io.open(meta_file("name"), "w")
  if f then f:write(name .. "\n") f:close() end
  os.remove(meta_file("json"))
  os.remove(meta_file("bgra"))
  os.remove(meta_file("jpg"))
  meta = {}
  -- ⚠️ Do NOT set meta_state = "looking" here. meta_lookup() opens with a
  -- re-entrancy guard that returns early when it is already "looking", so
  -- setting it first makes the call a silent no-op -- the choice gets written
  -- and nothing is ever fetched for it.
  meta.title = name          -- show the chosen name while the lookup runs
  render()
  meta_lookup(name)
end

-- Kick off a lookup for whatever is in the drive, unless we already know this
-- disc or the viewer has turned the network off.
local function meta_begin()
  meta = {}
  meta_state = "off"
  if meta_load_cached() then render() return end
  if o.online ~= true then return end
  if have_curl == nil then
    have_curl = (mp.command_native({ name = "subprocess", playback_only = false,
                                     args = { "sh", "-c", "command -v curl" },
                                     capture_stdout = true }) or {}).status == 0
  end
  if not have_curl then
    msg.warn("no curl: skipping the metadata lookup")
    return
  end
  -- A name file lets a useless label be corrected by hand: a concert disc
  -- labelled DREAMTHEATER is never going to find itself.
  local nf = io.open(meta_file("name"), "r")
  local label = disc_label
  if nf then
    local forced = (nf:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
    nf:close()
    if forced ~= "" then label = forced end
  end
  if label == nil or label == "" or label == "DVD" then return end
  meta_lookup(label)
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
  mode  = "hidden",   -- hidden | menu | osd | loading | blank
  stack = {},         -- breadcrumb of menu ids
  sel   = {},         -- per-menu selection, so going back returns to your row
  rows  = {},
  title = "",
  osd_until = 0,
  last_input = 0,     -- drives burn-in blanking; a menu idles just like a pause
  blank_from = nil,   -- the mode to restore when the screen wakes
  drift = 0,
}

local show_nodisc, load_disc       -- defined once the menus exist
local back                         -- the picker hands you back to the info screen
local osd_timer, tick_timer, disc_timer
local ui_started   = false
local ejecting     = false
local loading_disc = false
-- Give up auto-loading after this many consecutive read failures of the same
-- disc, or an unreadable one turns the waiting screen into a retry loop.
local LOAD_TRIES = 3
local load_fail  = { id = "", n = 0 }

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

-- Eject used to quit. It should not: swapping discs is the one thing a DVD
-- player is expected to do without being restarted.
--
-- ⚠️ Order matters. `stop` first, because while a title is loaded libdvdnav
-- holds the device open and the tray will not budge -- the eject simply fails,
-- silently, and looks like broken hardware.
local function eject()
  save_resume()
  ejecting = true
  mp.command("stop")
  show_nodisc()
  mp.add_timeout(0.5, function()
    shell_async({ "eject", device() }, function() ejecting = false end)
  end)
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
  rows[#rows + 1] = { label = "About this disc",
                      detail = (meta_state == "looking" and "...") or (meta.year or ""),
                      sub = "info" }
  rows[#rows + 1] = { label = "Eject disc", detail = "", act = eject }
  rows[#rows + 1] = { label = "Quit",       detail = "", act = function()
    save_resume(); mp.command("quit")
  end }
  -- Prefer the name the lookup found: "Conquest of the Planet of the Apes"
  -- reads rather better across a room than CONQUEST OF PLANET OF THE APES.
  return rows, meta.title or (disc_label ~= "" and disc_label or "DVD")
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

menus.info = function()
  return {}, meta.title or disc_label
end

-- "It guessed wrong" is a normal outcome for a disc whose only clue is a band
-- name, so correcting it is one row and one press, not a text editor.
menus.pick = function()
  local rows = {}
  for _, name in ipairs(candidates) do
    local n = name
    rows[#rows + 1] = {
      label  = n,
      detail = (meta.title == n) and "current" or "",
      mark   = (meta.title == n),
      act    = function() meta_choose(n); back() end,
    }
  end
  if #rows == 0 then
    rows[1] = { label = "Nothing else to choose from", off = true }
  end
  return rows, "Which disc is this?"
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

-- Shown while the tray is empty. Everything here is reachable with the same
-- four arrows and two buttons as the rest, because "put another disc in" is a
-- thing you do from the sofa, not from a terminal.
menus.nodisc = function()
  local rows = {}
  if load_fail.n >= LOAD_TRIES then
    rows[#rows + 1] = { label = "Try again", detail = "", act = function()
      load_fail.n = 0
      load_disc()
    end }
  end
  -- Only a motorised tray obeys this. Most slim USB drives eject under power
  -- and close by hand, so the row is offered without being promised -- the
  -- watcher picks the disc up either way.
  rows[#rows + 1] = { label = "Close tray", detail = "if motorised", keep = true,
                      act = function() shell_async({ "eject", "-t", device() }) end }
  rows[#rows + 1] = { label = "Eject",      detail = "", keep = true,
                      act = function() shell_async({ "eject", device() }) end }
  rows[#rows + 1] = { label = "Quit",       detail = "", act = function() mp.command("quit") end }
  return rows, (load_fail.n >= LOAD_TRIES) and "Cannot read that disc" or "No disc"
end

local function rebuild()
  local id = ui.stack[#ui.stack] or "main"
  local rows, title = (menus[id] or menus.main)()
  ui.rows, ui.title = rows, title or id
  local sel = ui.sel[id] or 1
  if sel > #rows then sel = #rows end
  if sel < 1 then sel = 1 end   -- the info screen has none; 1 is harmless
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

show_nodisc = function()
  ui.stack = { "nodisc" }
  ui.sel["nodisc"] = 1
  rebuild()
  ui.mode = "menu"
  ui.last_input = mp.get_time()
  render()
end

-- Identify whatever is in the drive now, then load it. Everything keyed on the
-- disc -- resume file, header, titles -- is reset here, because the disc in the
-- drive is not the disc we started with.
load_disc = function()
  if loading_disc then return end
  loading_disc = true
  probe_disc(function(info)
    if not info or not info.present then loading_disc = false return end
    if info.uuid ~= load_fail.id then load_fail = { id = info.uuid, n = 0 } end
    disc_id    = (info.uuid ~= "" and info.uuid) or "unknown"
    local lab  = (info.label ~= "" and info.label or "DVD"):gsub("_", " ")
    disc_label = lab:gsub("%s+", " ")
    src_dar      = nil
    ui_started   = false
    disc.titles  = {}
    disc.main    = nil
    ui.mode = "loading"
    render()
    meta_begin()          -- a new disc is a new identity, cache included
    mp.commandv("loadfile", "dvdnav://")
  end)
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

-- Cover on the left, facts on the right, synopsis under them. The cover is not
-- drawn here -- it is a real bitmap on its own overlay (poster_show) -- so this
-- only reserves the space for it.
local function draw_info(a)
  rect(a, 0, 0, M.w, M.h, COL.black, 0x30)
  rect(a, M.x0, M.y0, M.cw, M.ch, COL.panel, 0x10)

  local px, py = M.x0 + M.pad, M.y0 + M.head_h
  local has_poster = poster_ready()
  local tx = has_poster and (px + POSTER_W + M.pad) or px
  local tw = M.x1 - M.pad - tx

  -- A film title is the one string here worth shrinking to keep whole.
  local heading = meta.title or disc_label
  local hsize   = M.fs_head
  local hroom   = M.cw - M.pad * 2
  if #heading * hsize * 0.50 > hroom then hsize = M.fs_row end
  text(a, M.x0 + M.pad, M.y0 + round(M.pad * 0.6), 7, hsize, COL.ink,
       fit(heading, hsize, hroom))

  if has_poster then
    -- A flat plate behind the cover: the bitmap overlay has no border of its
    -- own, and a 4px-plus frame is what keeps its edge from shimmering.
    rect(a, px - M.stroke, py - M.stroke,
         POSTER_W + M.stroke * 2, POSTER_H + M.stroke * 2, COL.row, 0x00)
  end

  local y = py
  if meta_state == "looking" and not meta.title then
    text(a, tx, y, 7, M.fs_row, COL.dim, "Looking it up...")
    return
  end
  if not meta.title then
    for _, ln in ipairs(wrap("Nothing found for this disc. Drop a line with the "
        .. "real name into " .. meta_file("name") .. " and it will be looked up "
        .. "again.", M.fs_small, tw, 6)) do
      text(a, tx, y, 7, M.fs_small, COL.dim, ln); y = y + round(M.fs_small * 1.3)
    end
    return
  end

  local facts = {}
  if meta.year    then facts[#facts + 1] = meta.year end
  if meta.runtime then facts[#facts + 1] = math.floor(meta.runtime) .. " min" end
  if meta.imdb    then facts[#facts + 1] = meta.imdb end
  if #facts > 0 then
    text(a, tx, y, 7, M.fs_row, COL.accent, table.concat(facts, "   "))
    y = y + round(M.fs_row * 1.4)
  end

  local bottom = M.y1 - M.foot_h - M.pad
  if meta.overview then
    local room = math.max(1, math.floor((bottom - y) / (M.fs_small * 1.3)))
    for _, ln in ipairs(wrap(meta.overview, M.fs_small, tw, room)) do
      text(a, tx, y, 7, M.fs_small, COL.ink, ln)
      y = y + round(M.fs_small * 1.3)
    end
  end

  local hint = "Esc back"
  if #candidates > 0 then hint = "Enter  not this disc?      Esc back" end
  text(a, M.x0 + M.pad, M.y1 - M.foot_h, 7, M.fs_small, COL.dim, hint)
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
  local head = (disc_label ~= "" and disc_label or "DVD")
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
  local hint
  if id == "nodisc" then hint = "Insert a disc -- it loads by itself"
  elseif #ui.stack > 1 then hint = "Enter select    Esc back"
  else hint = "Enter select    Esc close" end
  text(a, M.x0 + M.pad, M.y1 - M.foot_h, 7, M.fs_small, COL.dim, hint)
end

render = function()
  measure()
  -- Publish what is on screen. mpv exposes user-data over the IPC socket, so
  -- `{"command":["get_property","user-data/omadvd"]}` answers "what is the
  -- player showing right now" without a screenshot -- which is the only way to
  -- check the no-disc screen, since mpv cannot screenshot with no file loaded.
  mp.set_property_native("user-data/omadvd", {
    mode  = ui.mode,
    menu  = ui.stack[#ui.stack] or "",
    disc  = disc_label,
    rows  = #ui.rows,
    sel   = (function()
      local id = ui.stack[#ui.stack]
      local r  = id and ui.rows[ui.sel[id] or 1]
      return r and r.label or ""
    end)(),
  })
  -- The cover belongs to the info screen alone. Anywhere else it would sit on
  -- top of the film, because a bitmap overlay is not part of the ASS layer we
  -- rebuild each frame.
  local on_info = (ui.mode == "menu" and ui.stack[#ui.stack] == "info")
  if on_info then
    if not poster_shown then poster_show(M.x0 + M.pad, M.y0 + M.head_h) end
  else
    poster_hide()
  end

  local a = {}
  if ui.mode == "blank" then
    draw_blank(a)
  elseif ui.mode == "loading" then
    draw_loading(a)
  elseif ui.mode == "menu" then
    if ui.stack[#ui.stack] == "info" then draw_info(a) else draw_menu(a) end
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
  ui.last_input = mp.get_time()
  if ui.mode == "blank" then
    ui.mode = ui.blank_from or "hidden"
    ui.blank_from = nil
    if ui.mode == "hidden" then wipe() else render() end
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
  -- The info screen draws itself rather than a row list, so Enter there means
  -- the one action it offers.
  if id == "info" then
    if #candidates > 0 then open_menu("pick") end
    return
  end
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

back = function()
  -- There is nothing behind the no-disc screen; closing it would leave a black
  -- screen and no way back.
  if ui.stack[1] == "nodisc" then return end
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
    ui.last_input = mp.get_time()
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
  local idle   = mp.get_property("idle-active") == "yes"

  -- Blank whenever nothing on screen is moving and nobody has touched a key:
  -- paused, sitting on a menu, or waiting for a disc. The original version only
  -- covered a paused frame, but a menu left up overnight burns in exactly the
  -- same way -- and with the no-disc screen there is now a state that can sit
  -- there for days.
  if (paused or idle) and ui.mode ~= "loading"
     and (mp.get_time() - ui.last_input) >= o.blank_after then
    if ui.mode ~= "blank" then
      ui.blank_from = ui.mode
      ui.mode = "blank"
      ui.drift = 0
    end
    ui.drift = ui.drift + 1
    render()
    return
  end

  if ui.mode == "blank" then
    ui.mode = ui.blank_from or "hidden"
    ui.blank_from = nil
    if ui.mode == "hidden" then wipe() end
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

-- ── Waiting for a disc ──────────────────────────────────────────────────────
-- Polling rather than udev: two seconds of latency is imperceptible next to the
-- time a tray takes to close and a drive takes to spin up, and `lsblk` reads
-- the udev database anyway, so this costs nothing and needs no daemon.
disc_timer = mp.add_periodic_timer(2, function()
  if ui.stack[1] ~= "nodisc" then return end
  if ejecting or loading_disc then return end
  probe_disc(function(info)
    if not info then return end
    if not info.present then
      -- Tray open or empty: forget any past failure, so the next disc starts
      -- with a clean slate.
      if load_fail.n > 0 and load_fail.id ~= "" then load_fail = { id = "", n = 0 } end
      return
    end
    if info.uuid == load_fail.id and load_fail.n >= LOAD_TRIES then return end
    load_disc()
  end)
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

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
  loading_disc = false
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
    meta_begin()
    show_menu()
  end
end)

mp.observe_property("pause", "bool", function(_, v)
  if v == false then ui.paused_since = nil end
end)

mp.observe_property("osd-dimensions", "native", function()
  if ui.mode ~= "hidden" then render() end
end)

mp.register_event("end-file", function(ev)
  loading_disc = false
  -- Our own stop(), on the way to opening the tray. show_nodisc() already ran.
  if ejecting then return end

  local reason = ev and ev.reason
  if reason == "error" then
    -- A disc that will not read. Count it, so the waiting screen does not sit
    -- in a two-second retry loop forever.
    load_fail.n = load_fail.n + 1
    show_nodisc()
    return
  end

  -- A finished title returns to the menu; the player is the place you sit.
  if ui_started then
    mp.add_timeout(0.2, function()
      if mp.get_property("idle-active") == "yes" then show_nodisc() else show_menu() end
    end)
  end
end)

mp.register_event("shutdown", function() save_resume() end)

ui.last_input = mp.get_time()

-- Started with an empty drive or an open tray: there is no file-loaded event
-- coming, so open the waiting screen directly. The watcher takes it from there.
mp.add_timeout(0.3, function()
  if not ui_started and mp.get_property("idle-active") == "yes" then show_nodisc() end
end)

msg.info("OmaDVD-Player UI ready; disc=" .. (disc_label ~= "" and disc_label or "?"))
