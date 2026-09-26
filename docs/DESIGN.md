# Design notes

Findings from building OmaDVD, all verified on the real machine, disc and tube
rather than reasoned about. Written down so they are not re-derived later.

Target: Mac Mini (Haswell i5, 4 GB, Intel HD 5000, no VAAPI driver installed),
Omarchy, HDMI → composite adapter → 4:3 CRT, single output at 720×480@60.
Drive: MediaTek slim USB DVD writer. Test disc: a Region 4 NTSC pressing.

---

## 1. mpv cannot drive a DVD's own menu, and that is fine

`mpv --input-cmdlist` has no `dvdnav`/`discnav` command — menu navigation was
removed upstream years ago. `dvdnav://` still opens, decrypts and reads a disc,
but the animated menu a studio authored is unreachable.

So OmaDVD does not try. It reads the disc's structure and draws **its own**
menu. mpv exposes DVD titles as **editions** (`edition-list`), and chapters,
audio and subtitle tracks normally.

This is not a consolation prize. Every disc now gets the same large, legible,
predictable interface, instead of whatever a 2001 authoring house designed for
a remote control nobody still owns.

**⚠️ On a DVD, the `edition` property reads back as the string `"auto"`**, so
`get_property_number("edition")` returns nil and every comparison against it
looks like a change. Use **`current-edition`** for the resolved index; set
`edition` to change it.

## 2. Aspect ratio: the 9/8 correction

The single most important setting, and the one a naive setup gets wrong in a
way that looks *almost* right.

A 720×480 framebuffer displayed on a 4:3 screen has non-square pixels — PAR
8:9. That is exactly the BT.601 geometry a DVD is already stored in. mpv,
however, assumes square pixels: left alone it "corrects" a 4:3 disc to 640×480
and pillarboxes it, and the tube then stretches that back out 12.5% too wide.

Cancel it by overriding the display aspect with the disc's true ratio × 9/8 —
the ratio between the framebuffer's shape (3:2) and the screen's (4:3):

| Disc | True DAR | × 9/8 | Result on a 720×480 raster |
|------|----------|-------|----------------------------|
| 4:3        | 1.3333 | **1.5** | 720×480, fills the screen, 1:1 |
| 16:9 anam. | 1.7778 | **2.0** | 720×360, letterboxed, correct |

`omadvd.lua` computes this per title and sets `video-aspect-override`. The
Picture menu also offers explicit 4:3 / 16:9 / fill / native, because plenty of
discs are mis-flagged.

**⚠️ Do not read the source aspect back from `video-params/aspect`.** It
reflects `video-aspect-override` once we have set it, so on a title change the
correction compounds: 1.33 → 1.5 → 1.69 → … Read the demuxer's own numbers
instead, which are immune:

```
DAR = (track-list/N/demux-w / track-list/N/demux-h) * track-list/N/demux-par
```

## 3. Never switch title before the UI exists

Switching `edition` **reloads the stream**. On a slim USB drive with an
encrypted disc that means re-fetching the CSS keys — several seconds, during
which nothing is on screen.

The first version jumped to the longest title on `file-loaded`, before showing
anything. It produced a black screen whose length depended on which title
dvdnav happened to open, and — because `edition` reads as `"auto"` (§1) — the
"is it already the right title?" test was always true, so it reloaded *every*
time. The menu appeared only after the reload, if at all.

Now the menu opens immediately on whatever loaded, and the **Play** row targets
the main feature. The reload happens when the viewer asked for it, behind a
`Loading…` panel.

Related: a reload re-enters `file-loaded`, so any "have we started?" flag must
distinguish *the UI has started* from *the title has been chosen*. One shared
flag makes the menu never open on the second pass — which looks exactly like an
overlay that refuses to draw.

## 4. Picking the main feature

`edition-list/N/title` on a DVD reads `"title: 1 (01:26:37.667)"`. That embedded
runtime is the only per-title duration mpv exposes, and parsing it is what tells
an 86-minute film apart from seven three-minute extras. Longest title wins.

## 5. libdvdcss is invisible to `ldd`

Without it, every commercial disc fails like this:

```
libdvdread: Encrypted DVD support unavailable.
[dvdnav] Error getting next block from DVD 1 (Error reading NAV packet.)
```

which reads like a scratched disc or a dying drive, not a missing library. It
is in Arch's `extra` repo (`pacman -S libdvdcss`).

**⚠️ `libdvdread` loads it with `dlopen`, not by linking it.** `ldd
/usr/lib/libdvdread.so.8` mentions nothing; only `strings` shows
`libdvdcss.so.2`. An AppImage built by walking `ldd` output therefore packages
everything *except* the one library that makes the thing work, and fails only
at playback time. `packaging/build-appimage.sh` copies it explicitly and
refuses to build without it.

## 6. What the AppImage must not bundle

Bundling the graphics, display-server or C++ runtime stack is the classic way
to build an AppImage that works on the machine that made it and segfaults
elsewhere: the host's Mesa drivers get loaded into a process holding our older
`libstdc++`. Excluded, and taken from the host: glibc, `libstdc++`/`libgcc_s`,
GL/EGL/GBM/DRM/Vulkan/VA-API, Wayland and X client libs, `libxkbcommon`, ALSA /
PulseAudio / PipeWire / JACK clients, the fontconfig–freetype–harfbuzz stack,
and udev/dbus/systemd. Everything else — mpv, FFmpeg, libass, libplacebo,
libdvdnav/read/**css** — is bundled.

## 7. Per-disc resume

mpv's own watch-later cannot help: every disc presents the identical
"filename", `dvdnav://`. But `lsblk -dno UUID /dev/sr0` returns the disc's own
**serial number** (`2ace76ac00000000` ↔ libdvdnav's reported `2ACE76AC`),
without root, straight from the udev database. That is the resume key.

## 7a. Swapping discs without leaving the player

Eject originally quit the player. That was simply wrong: changing discs is the
one thing a DVD player exists to let you do without being restarted. Four
things had to be true to fix it, and three of them are not obvious.

**Stop before ejecting.** While a title is loaded libdvdnav holds the device
open and the tray does not move. The eject fails silently and looks like broken
hardware.

**`force-window=yes`.** With no file loaded mpv destroys its window, and the
window is where the waiting screen is drawn. Without this, ejecting blacks the
screen out entirely and there is nothing left to put a menu on.

**⚠️ Do not use SIZE to decide whether a disc is present.** With the tray open
this drive still reports the last disc's size:

```
LABEL="" UUID="" SIZE="7594151936"     # tray open, nothing in it
```

A size test therefore says "disc!" at an empty open tray, and the player sits
there failing to open it every two seconds. `UUID` and `LABEL` do both go
empty, so they are the honest signal. A disc still spinning up also reads
empty, which costs one extra poll and nothing else.

**Polling, not udev.** Two seconds of latency is imperceptible next to how long
a tray takes to close and a drive takes to spin up, and `lsblk` reads the udev
database anyway — so this needs no daemon and no privileges.

Consecutive read failures of the *same* disc are counted, and auto-loading
stops after three, because otherwise an unreadable disc turns the waiting
screen into a silent two-second retry loop. A different disc resets the count.

Starting with an empty drive follows the same path: the launcher no longer
refuses to run, it starts mpv idle with no file and lets the waiting screen
pick things up.

`eject -t` closes only a motorised tray. Most slim USB drives are push-to-close,
so the menu row is offered without being promised.

## 7b. Checking the UI without a screenshot

mpv cannot take a screenshot with no file loaded, which is exactly the state the
waiting screen lives in — and on a single-screen machine a compositor overlay
can cover the window anyway. So the script publishes what it is showing:

```sh
echo '{"command":["get_property","user-data/omadvd"]}' | socat - /path/to.sock
# {"rows":3,"menu":"nodisc","disc":"DVD","mode":"menu"}
```

Cheap, and it makes the player scriptable as a side effect.

## 7c. Cover art, from a disc that knows nothing about itself

A DVD carries a volume label, a serial number, and the runtime of each title.
No title, no year, no cover. So this is a **search**, not a lookup, and it has
to survive the labels discs actually carry: `CONQUEST_OF_PLANET_OF_THE_APES` is
not the film's name — the real one has another "the" in it.

Wikipedia's search absorbs exactly that, returning the right article for the
mangled label. The article gives a plain-text synopsis and a Wikidata id;
Wikidata gives year, runtime, director and the IMDb id — and, usefully, the
TMDB id, if a keyed source is ever wanted.

**⚠️ `prop=pageimages` returns nothing for a film.** It only serves
freely-licensed images, and a poster is non-free. `prop=images` lists every
image on the page *including* the poster — alongside Wikipedia's own furniture:

```
File:Conquest of the planet of the apes.jpg   <- the poster
File:OOjs UI icon edit-ltr-progressive.svg
File:Symbol category class.svg
File:Wikiquote-logo.svg
```

So the filename is scored against the article title by shared words rather than
taking the first hit, and obvious chrome is filtered by name. No API key is
needed anywhere in this chain.

**The serial number is identity, not a lookup key.** libdvdnav reports it and
`lsblk -dno UUID` exposes it without root. There is no public database mapping
DVD serials to titles — the ones that existed were commercial and are gone, and
MusicBrainz's DiscID is computed from an *audio CD's* TOC, so it does not apply.
What the serial is perfect for is caching: metadata, artwork and resume all key
on it, which is what makes "correct a bad label by hand, once" permanent.

**⚠️ ASS cannot draw an image.** The entire rest of the interface is ASS, but a
cover is a bitmap, so it goes through mpv's separate `overlay-add` with a raw
BGRA buffer. Two consequences: it is positioned in window pixels (fine — the
ASS overlay resolution is set to the window size, so they coincide), and it is
*not* part of the layer rebuilt each frame, so it must be explicitly removed
when leaving the screen or it sits on top of the film.

The conversion to BGRA is done by **mpv itself** — it is already in the bundle,
so the AppImage needs no extra binary:

```
mpv cover.jpg --vf=scale=W:H:force_original_aspect_ratio=decrease,\
    pad=W:H:(ow-iw)/2:(oh-ih)/2,format=bgra --of=rawvideo --ovc=rawvideo --frames=1
```

`force_original_aspect_ratio` plus `pad` is what keeps a poster's shape while
still producing the single fixed buffer size `overlay-add` requires.

**⚠️ `tonumber(s:gsub(...))` throws.** gsub returns *two* values, and
tonumber's second argument is a numeric base, so the replacement count arrives
as the base: "base out of range". Wrap it in another pair of parentheses. The
same shape caused a separate bug in this project when a rename produced
`local disc_id = disc_id` — Lua's multiple returns and its scoping rules both
fail quietly, and `luac -p` catches neither.

Worth knowing: `luac -p -l` does catch the scoping one. Any local referenced
before it is declared compiles to a `_ENV` global lookup, so dumping the
bytecode and listing `_ENV` accesses shows every accidental global:

```sh
luac -p -l src/lua/omadvd.lua | grep -oE '_ENV "[a-z_]+"' | sort -u
```

If anything but the standard library appears there, it is a typo or an ordering
mistake that would otherwise be nil at runtime.

## 8. Burn-in

A paused DVD is a bright still image held indefinitely — the worst thing you
can do to a phosphor. OmaCRT's own screensaver cannot cover this: it is
deliberately vetoed by a fullscreen window, and OmaDVD is always fullscreen.
So OmaDVD blanks itself after 4 minutes with no keypress, with a label that
drifts so even the label cannot burn in. Note *no keypress*, not *paused*: the
first version only covered a paused frame, but a menu left up overnight burns
in exactly the same way — and the waiting screen is a state that can sit there
for days.

The Wayland idle protocol would not have helped either: it counts seat input,
and a paused player with nobody touching a key looks the same as an empty room.

## 9. Drawing for 480i

- Safe area **10% top, 6% bottom, 5% sides** — measured, not the 5% broadcast
  standard, which this set overscans past at the top.
- Nothing thinner than **4px** (two scanlines): a one-scanline detail is re-lit
  30×/sec instead of 60 and shimmers. Flat fills, no hairline outlines.
- Warm off-white (`#EDEAE2`), not `#FFF`, which blooms. Amber for selection.
  **No saturated red for text** — composite chroma bleeds worst on red.
- Scale on `min(w/720, h/480)`, not on height alone: a compositor can tile the
  window, and height-only sizing then overflows the width.

**⚠️ `--osd-level=0` does *not* hide script overlays** — worth stating because
the opposite is the obvious worry, given it is documented as "OSD fully
disabled". Rendered the same overlay at level 0 and at the default and compared
window captures: byte-for-byte identical. Level 0 suppresses only mpv's own
status text and progress bar, which is what we want.

## 10. Audio

Composite carries stereo, so `audio-channels=stereo` is mandatory: without it a
5.1 AC-3 track loses its centre channel, which is where the dialogue is.

Region matters for language, not just playback — a Region 4 disc defaults to
Spanish audio. `--alang` settles it once. Bitmap DVD subtitles are authored at
720×480 and land pixel-exact; leave them alone.

## 11. Decoding

No VAAPI driver is installed on this machine (`/usr/lib/dri` has no
`i965_drv_video.so`), so `hwdec=no` is explicit — `auto` only buys a failed
probe and log noise. MPEG-2 at 720×480 is a few percent of one core in
software. With the aspect fix a 4:3 disc lands 1:1, so the scaler is a no-op
and cheap filters are the right choice.
