# OmaDVD-Player

A DVD player for a CRT television.

Part of the [OmaCRT](https://github.com/FromChaosComesClarity/OmaCRT) family:
an Omarchy machine on a composite-fed tube at **720×480, genuinely interlaced
(480i)**, driven from the couch. OmaDVD plays a real disc from a real USB
optical drive, with an interface designed for that screen rather than shrunk
down to fit it.

It ships as a **self-contained AppImage** that bundles its own mpv and — the
part that actually matters — its own `libdvdcss`. No distribution installs that
by default, so a player without it fails on every commercial disc, with an
error message that sounds like a broken drive. Bundling it is the difference
between "works here" and "works on any Omarchy PC".

## What it looks like from the sofa

The disc's own menu is not used. It cannot be: mpv removed DVD menu navigation
years ago, so `dvdnav://` can read and decrypt a disc but not drive its
animated menu. OmaDVD replaces it with its own — which turns out to be the
better answer anyway. Every disc gets the same big, legible, predictable menu
instead of whatever a studio authored in 2001 for a remote control you no
longer own.

```
  CONQUEST OF PLANET OF THE APES                            21:14
  ┌────────────────────────────────────────────────────────────┐
  │ Resume                                              1:03:22 │
  │ Start over                                          1:26:37 │
  │ Titles                                                    8 │
  │ Chapters                                                 24 │
  │ Audio                                               English │
  │ Subtitles                                                Off│
  └────────────────────────────────────────────────────────────┘
  Enter select    Esc close
```

Titles, chapters, audio and subtitle tracks, picture settings, eject, quit.
Everything is one list of large rows, navigable with four arrows and two
buttons — so the same interface works from a keyboard on the arm of the sofa
or from a gamepad through OmaCRT's input daemon, with no modifier keys.

## Cover art and metadata

If the machine is online, OmaDVD identifies the disc and shows a cover, year,
runtime and synopsis on an **About this disc** screen — and puts the real title
in the menu heading, so it reads *Conquest of the Planet of the Apes* rather
than `CONQUEST OF PLANET OF THE APES`.

No API key and no account. A DVD carries almost nothing to go on — a volume
label, a serial number, and the runtime of each title — so this is a *search*,
not a lookup, and it is built to survive the labels discs actually have:

| Disc label | Identified as |
|---|---|
| `CONQUEST_OF_PLANET_OF_THE_APES` | Conquest of the Planet of the Apes (1972) — *label is missing a "the"* |
| `RHCP_OFF_THE_MAP` | Off the Map (video) (2001) — *via the band, then matched back to the label* |
| `DREAMTHEATER` | asks: five Dream Theater releases, pick one |

The chain: Wikipedia's search on the label (skipping list, discography and
disambiguation pages, which are dead ends), then Wikidata for year, runtime and
the IMDb id, then the poster off the article. When the label only names an
**artist**, Wikidata is asked for that artist's video releases and their names
are matched back against the label — which is how `RHCP_OFF_THE_MAP` resolves
without anyone being asked anything.

When it genuinely cannot tell — `DREAMTHEATER` names a band and nothing else —
it says so, and **Enter on the About screen lists the candidates** so you can
pick yours with the d-pad. That choice is remembered against the **disc's own
serial number**, so it is asked once per disc, ever.

Everything is cached under `~/.local/state/omadvd/meta/`, keyed on that serial,
so it is fetched once and works offline afterwards. The whole chain is
asynchronous — nothing in the player ever waits on the network, and with no
connection it simply carries on. `--offline` disables it; cached results still
show. Drop your own `<serial>.jpg` in that folder to supply artwork yourself.

Only the volume label ever leaves the machine, and only to Wikipedia.

## The CRT parts that are not cosmetic

**Aspect.** The one thing almost every DVD setup gets wrong on a tube. A
720×480 framebuffer shown as 4:3 has non-square pixels — 8:9 — which is exactly
the BT.601 geometry a DVD is already stored in. mpv assumes square pixels, so
left alone it "corrects" a 4:3 disc to 640×480 and pillarboxes it, and the tube
then stretches that back out 12.5% too wide. OmaDVD cancels this by overriding
the display aspect with the disc's true ratio × 9/8, so a 4:3 disc lands 1:1 on
the raster and a 16:9 one letterboxes correctly. See
[docs/DESIGN.md](docs/DESIGN.md).

**Safe area.** 10% top, 6% bottom, 5% sides — measured on a real set, not the
5% broadcast standard, which this tube overscans straight past at the top.

**Stroke floor.** Nothing thinner than 4px (two scanlines). On an interlaced
display a single-scanline detail is re-lit 30 times a second instead of 60, and
reads as a shimmer. Flat fills everywhere, no hairline outlines.

**Colour.** Warm off-white rather than #FFF (which blooms), amber for
selection, and no saturated red for text — composite chroma bleeds worst on red.

**Audio.** 5.1 AC-3 is downmixed to stereo, because composite carries stereo.
Skip this and you lose the centre channel, which is where the dialogue is.

**Burn-in.** A paused DVD is a bright still image held indefinitely. OmaDVD
blanks itself after 4 minutes paused, with a drifting label. OmaCRT's own
screensaver cannot cover this: it is deliberately vetoed by a fullscreen
window, and OmaDVD is always fullscreen.

## Install

Drop the AppImage in `~/Applications` and OmaCRT's launcher will find it:

```sh
chmod +x OmaDVD-Player-x86_64.AppImage
mv OmaDVD-Player-x86_64.AppImage ~/Applications/OmaDVD-Player.AppImage
```

Run it from anywhere with a disc in the drive:

```sh
~/Applications/OmaDVD-Player.AppImage            # first drive with a disc
~/Applications/OmaDVD-Player.AppImage -a en      # prefer English audio
~/Applications/OmaDVD-Player.AppImage movie.iso  # an image or a VIDEO_TS dir
```

A Region 4 disc often defaults to Spanish and a Region 2 one to German; `-a en`
/ `-a pt` settles it once rather than every time.

## Keys

| Key | In the menu | While playing |
|-----|-------------|---------------|
| ↑ ↓ | move | previous / next chapter |
| ← → | back / select | seek ∓10s |
| Enter | select | open menu |
| Esc | back, then close | open menu |
| Space | select | play / pause |
| `m` | close | open menu |
| `a` / `j` | — | cycle audio / subtitles |
| `d` | — | cycle deinterlacer |
| `e` / `q` | eject / quit | eject / quit |

Ejecting does **not** close the player. The screen switches to *No disc*, and
whatever you put in next is detected and loaded on its own — so a double
feature is two discs, not two launches. Starting with an empty drive opens on
the same waiting screen rather than refusing to run.

Resume is per-disc, keyed on the disc's own serial number, so a half-watched
film picks up where it stopped even after other discs in between — including
discs swapped without leaving the player.

## Build

```sh
packaging/build-appimage.sh
```

Needs `mpv` and `libdvdcss` installed on the build machine — the script copies
them into the bundle, and refuses to build without the latter. It fetches
`appimagetool` on first run and caches it.

## Running from source

```sh
src/omadvd --help
src/omadvd -a en
```

Requires `mpv` (with `dvdnav://`, i.e. built against libdvdnav) and
`libdvdcss`. On Arch/Omarchy: `sudo pacman -S mpv libdvdcss`.

## Licence

GPL-3.0. See [LICENSE](LICENSE).
