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

## 8. Burn-in

A paused DVD is a bright still image held indefinitely — the worst thing you
can do to a phosphor. OmaCRT's own screensaver cannot cover this: it is
deliberately vetoed by a fullscreen window, and OmaDVD is always fullscreen.
So OmaDVD blanks itself after 4 minutes paused, with a label that drifts so
even the label cannot burn in.

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
