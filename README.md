# Spotify Floating Widget

A Spotify now-playing widget for [Omarchy](https://omarchy.org/) that opens as
a real, draggable app window instead of a bar popup — album art, track title
and artist, a draggable progress bar, and shuffle / previous / play-pause /
next / repeat controls, all driven live over MPRIS.

Unlike a bar-widget popup, this renders as a genuine floating window
(`Quickshell.FloatingWindow`), so Hyprland manages it like any other app:
`SUPER`+drag to move it, resize it freely (the art and title scale up once
you grow the window past its default size), and it participates in normal
window focus/stacking instead of always sitting on top of or behind
everything else.

## Features

- Album art, title, and artist, pulled from the Spotify MPRIS player
- Draggable seek bar with elapsed/total time
- Shuffle, previous, play/pause, next, repeat (off → all → one)
- Resizable: past its default size, the art and track title grow with the
  window instead of leaving empty space
- Window border color/width and corner rounding are read live from your
  Hyprland config (`general:col.active_border`, `general:border_size`,
  `decoration:rounding`) instead of the shell theme accent, so it always
  matches your `looknfeel.lua`
- Opens/closes on demand (from the Omarchy menu or an IPC call) rather than
  auto-showing — it behaves like an app you launch, not a persistent overlay
- Lyrics, in a second, independently draggable window (a lyrics-icon button
  on the card toggles it) — styled after Spotify's own lyrics view: a
  blurred, tinted backdrop sampled from the album art (darkened to suit the
  cover's own brightness), large bold text, and, when Spotify's desktop app
  is installed locally, its actual "Spotify Mix" font (extracted once from
  your own install, cached outside this repo, never bundled — falls back to
  a system font otherwise). Lyrics come from [lrclib.net](https://lrclib.net)
  (free, no API key); synced (LRC) lyrics highlight and auto-scroll with
  playback, unsynced ones render as plain scrollable text. Closing the main
  card closes the lyrics window with it; closing only the lyrics window
  leaves the card open.

## Install

```bash
omarchy plugin add https://github.com/f4lsewitness/omarchy-spotify-widget.git --enable --yes
```

Or by hand:

```bash
git clone https://github.com/f4lsewitness/omarchy-spotify-widget.git \
  ~/.config/omarchy/plugins/isra.spotify-widget
omarchy-shell shell rescanPlugins
omarchy plugin enable isra.spotify-widget
```

## Usage

Open it with an Omarchy menu entry (`~/.config/omarchy/extensions/omarchy-menu.jsonc`):

```jsonc
"personal.spotify-widget": {
  "icon": "",
  "label": "Spotify Widget",
  "action": "omarchy-shell shell toggle isra.spotify-widget '{}'"
}
```

Or drive it directly over IPC:

```bash
omarchy-shell shell toggle isra.spotify-widget '{}'   # open/close
omarchy-shell shell summon isra.spotify-widget '{}'   # open
omarchy-shell shell hide isra.spotify-widget          # close
```

### Lyrics

Click the lyrics-icon button on the now-playing card (next to repeat, at the
end of the control row) to open the lyrics window. It's a second, separate
floating window — drag it wherever you like, resize it, close it on its own
without touching the card. Click any line to seek playback to that line's
timestamp. There's no separate menu entry or IPC target for it; it only
opens from that button on an already-open card.

## Optional Hyprland tweaks

These aren't required — the widget works as a normal floating window without
them — but they're a nice combo if you want it (and/or the lyrics window) to
live on a dedicated, scratchpad-style workspace instead of your regular ones
(add to `~/.config/hypr/hyprland.lua`). Hyprland calls this a *special
workspace*; the example below names it `widgets`, but that's just a name —
call it whatever you like as long as the rules and the toggle bind agree:

```lua
-- Float these windows and park them on a hidden "widgets" special workspace.
o.window({ class = "^org.quickshell$", title = "^Spotify Widget$" }, { workspace = "special:widgets" })
o.window({ class = "^org.quickshell$", title = "^Spotify Lyrics$" }, { workspace = "special:widgets" })
o.window({ workspace = "special:widgets" }, { float = true, opacity = "1.0 1.0 override", no_dim = true })
```

```lua
-- ~/.config/hypr/bindings.lua
o.bind("SUPER + D", "Toggle widgets workspace", hl.dsp.workspace.toggle_special("widgets"))
```

```lua
-- ~/.config/hypr/looknfeel.lua, inside the decoration block
dim_special = 0.35,
```

## Requirements

- [Omarchy](https://omarchy.org/) / `omarchy-shell` (Quickshell)
- Spotify running with MPRIS (the desktop app, `spotifyd`, or `spotify-player`)
- For lyrics: `curl` and ImageMagick (`magick`) — used to fetch lyrics from
  lrclib.net and sample the album art's average color for the background
  tint. Optional, for the real Spotify font specifically: the Spotify
  desktop app installed locally, plus `unzip` and `woff2_decompress` (the
  `woff2` package) to extract and convert it. Without any of these, lyrics
  and the blurred background still work; only the font falls back to a
  system sans.

## License

MIT — see [LICENSE](LICENSE).
