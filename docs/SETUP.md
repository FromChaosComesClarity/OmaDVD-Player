# Setup

## The AppImage (recommended)

Everything needed to decode and decrypt a disc is inside it, including
`libdvdcss`. The host only supplies its own graphics drivers, display server
and fonts — see [DESIGN.md §6](DESIGN.md) for why that split is deliberate.

```sh
chmod +x OmaDVD-Player-x86_64.AppImage
mkdir -p ~/Applications
mv OmaDVD-Player-x86_64.AppImage ~/Applications/OmaDVD-Player.AppImage
```

`~/Applications` is where OmaCRT's launcher scans for AppImages, so it appears
in the couch menu with no further wiring.

Needs FUSE 2 to mount itself (`pacman -S fuse2` on Arch). Without it, run with
`--appimage-extract-and-run`.

## From source

```sh
sudo pacman -S mpv libdvdcss     # Arch / Omarchy
src/omadvd -a en
```

`mpv` must have `dvdnav://` support — check with `mpv --list-protocols | grep
dvdnav`. Arch's package does.

## Optical drive access

No root needed. A logged-in seat gets an ACL on `/dev/sr0` automatically, which
covers both the raw reads `libdvdcss` makes and the `lsblk` identity lookup.
Verify:

```sh
getfacl /dev/sr0 | grep $USER     # should show rw
```

If not, add yourself to the `optical` group and log out and back in.

The disc may be auto-mounted; that is fine and OmaDVD leaves it alone —
`libdvdcss` reads the raw device regardless. `-u` unmounts first if your
automounter is being difficult.

## Hyprland

OmaDVD sets its Wayland app-id to `omadvd`, so it can be targeted directly.
It already asks for fullscreen itself; this makes it reliable when something
else is on the workspace:

```lua
-- ~/.config/hypr/windows.lua (or wherever your rules live)
hl.windowrule({ "fullscreen",   class = "omadvd" })
hl.windowrule({ "idleinhibit focus", class = "omadvd" })
```

Without a rule the compositor may tile it next to an existing window; OmaDVD
still renders correctly (it scales on the smaller axis) but you lose the screen.

## Troubleshooting

**`Error reading NAV packet`, or `Encrypted DVD support unavailable`**
`libdvdcss` is missing. This is the one failure that looks like broken
hardware and is not. `sudo pacman -S libdvdcss`. The AppImage bundles it, so
this can only happen in a from-source run.

**`no disc found in any optical drive`**
The drive reports size 0 when empty. Give a slow USB drive time to spin up:
`omadvd -w 20`.

**Everything is in Spanish (or German, or French)**
The disc's default, not a bug — a Region 4 pressing defaults to Spanish.
`omadvd -a en`, or change it live in the Audio menu. Region 1/2/4 discs all
play regardless of the drive's region setting; `libdvdcss` does not care.

**The picture is too wide, too narrow, or letterboxed on all four sides**
The disc's aspect flag is wrong — common. Open **Picture ▸ Aspect** and cycle
to 4:3 or 16:9 explicitly. `native` disables OmaDVD's correction entirely,
which is the right answer only if you are not on a 720×480 → 4:3 chain.

**Combing / interlacing artefacts on movement**
The title is hard-interlaced rather than soft-telecined. **Picture ▸
Deinterlace** cycles `no → bwdif → yadif`, or press `d` during playback. Most
film discs need nothing.

**Dialogue is quiet but effects are loud**
The track is 5.1 downmixed to stereo. Turn on **Audio ▸ Night mode**.

**The screen goes black while paused**
Working as designed — burn-in protection after 4 minutes. Any key wakes it.
Change with `--script-opts=omadvd-blank_after=600`.

**The tray opens but "Close tray" does nothing**
Most slim USB drives eject under power and close by hand — the motor only goes
one way. Push it shut; the disc is picked up within a couple of seconds either
way. The row is there for the drives that do obey it.

**A disc is in but the player still says "No disc"**
It polls every two seconds and a drive can take longer than that to spin up and
publish its label. If it stays that way, check `lsblk -dn -P -o LABEL,UUID
/dev/sr0` reports something — an empty UUID *and* an empty label is how OmaDVD
decides the tray is empty.

**Playback is fine but nothing is on screen for several seconds after choosing
a title**
Expected: changing title reloads the encrypted stream and re-fetches CSS keys.
A `Loading…` panel covers it.

## Build

```sh
packaging/build-appimage.sh
```

Requires `mpv` and `libdvdcss` installed on the build host — both get copied
into the bundle, and the build aborts if `libdvdcss` is absent rather than
producing an AppImage that cannot play anything. `appimagetool` is fetched on
first run into `~/.cache/omadvd-build`.
