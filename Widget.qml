import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Ui
import qs.Commons

// Now-playing card that behaves like a normal app: opened from the Omarchy
// menu (or `omarchy-shell shell toggle isra.spotify-widget '{}'`), rendered
// as a real FloatingWindow so Hyprland manages it like any other window
// (SUPER+drag to move, floats above/below other windows by focus order,
// closable). The border/rounding intentionally match ~/.config/hypr/looknfeel.lua
// instead of the theme accent, since Hyprland itself draws this window's frame.
Item {
  id: root

  // Injected by the shell's panel loader when present on the root item.
  property var shell: null

  // True while the window is open. The shell reads this to answer
  // isPluginOpen(); close()/open() are called by shell.summon/hide/toggle.
  property bool opened: false
  property bool closingFromHost: false

  function open(payloadJson) {
    opened = true
    extractSpotifyFonts()
  }
  function close() {
    closingFromHost = true
    opened = false
    lyricsOpen = false
    closingFromHost = false
  }

  // Spotify brand green, used only for the "now playing" accent (play glyph,
  // active shuffle/repeat dot) -- never for the window border, which mirrors
  // Hyprland's own border color/width below.
  readonly property color accentColor: "#1DB954"

  // Pulls general:col.active_border / general:border_size from the live
  // Hyprland config so this window's inner frame reads as part of the same
  // border language as ~/.config/hypr/looknfeel.lua, not the shell theme.
  component HyprBorder: QtObject {
    id: hb
    property color color: "#222222"
    property int width: 1

    function applyColor(raw) {
      try {
        var json = JSON.parse(raw || "{}")
        var m = String(json.gradient || "").match(/^([0-9A-Fa-f]{8})/)
        if (!m) return
        var aa = parseInt(m[1].substr(0, 2), 16)
        var rr = parseInt(m[1].substr(2, 2), 16)
        var gg = parseInt(m[1].substr(4, 2), 16)
        var bb = parseInt(m[1].substr(6, 2), 16)
        hb.color = Qt.rgba(rr / 255, gg / 255, bb / 255, aa / 255)
      } catch (e) { /* hyprctl missing -- keep the previous value */ }
    }

    function applyWidth(raw) {
      try {
        var json = JSON.parse(raw || "{}")
        var n = Number(json.int)
        if (isFinite(n) && n >= 0) hb.width = n
      } catch (e) { /* hyprctl missing -- keep the previous value */ }
    }

    property Process colorProc: Process {
      command: ["hyprctl", "-j", "getoption", "general:col.active_border"]
      stdout: StdioCollector { waitForEnd: true; onStreamFinished: hb.applyColor(text) }
    }

    property Process widthProc: Process {
      command: ["hyprctl", "-j", "getoption", "general:border_size"]
      stdout: StdioCollector { waitForEnd: true; onStreamFinished: hb.applyWidth(text) }
    }

    Component.onCompleted: {
      colorProc.running = true
      widthProc.running = true
    }
  }

  HyprBorder { id: hyprBorder }

  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var player: pickSpotify(players)

  function isSpotify(p) {
    if (!p) return false
    if (String(p.dbusName || "").toLowerCase().indexOf("org.mpris.mediaplayer2.spotify") === 0) return true
    if (String(p.desktopEntry || "").toLowerCase() === "spotify") return true
    return String(p.identity || "").toLowerCase() === "spotify"
  }

  function pickSpotify(list) {
    var fallback = null
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      if (!isSpotify(p)) continue
      if (p.isPlaying) return p
      if (!fallback) fallback = p
    }
    return fallback
  }

  readonly property bool running: player !== null
  readonly property bool playing: running && player.isPlaying
  readonly property string title: running && player.trackTitle ? player.trackTitle : ""
  readonly property string artist: running && player.trackArtist ? player.trackArtist : ""
  readonly property string artUrl: running && player.trackArtUrl ? player.trackArtUrl : ""

  readonly property bool shuffleSupported: running && player.shuffleSupported
  readonly property bool shuffle: shuffleSupported && player.shuffle
  readonly property bool loopSupported: running && player.loopSupported
  readonly property int loopState: loopSupported ? player.loopState : MprisLoopState.None

  readonly property real trackLength: running && player.lengthSupported ? Math.max(0, player.length) : 0
  readonly property real trackPosition: running && player.positionSupported ? Math.max(0, player.position) : 0
  readonly property bool canSeek: running && player.canSeek && player.positionSupported && trackLength > 0

  function formatTime(seconds) {
    var total = Math.max(0, Math.floor(Number(seconds) || 0))
    var s = total % 60
    var m = Math.floor(total / 60) % 60
    var h = Math.floor(total / 3600)
    var pad = function (n) { return n < 10 ? "0" + n : String(n) }
    return h > 0 ? h + ":" + pad(m) + ":" + pad(s) : m + ":" + pad(s)
  }

  // MPRIS only pushes position on seek/track-change, so poll it while the
  // window is open and something is playing. Also runs whenever the lyrics
  // window is open (even if the player can't seek) so line highlighting
  // stays in sync.
  Timer {
    running: root.opened && root.playing && (root.canSeek || root.lyricsOpen)
    interval: 500
    repeat: true
    onTriggered: if (root.player) root.player.positionChanged()
  }

  function playPause() {
    if (!running) return
    if (player.canTogglePlaying) player.togglePlaying()
    else if (player.isPlaying && player.canPause) player.pause()
    else if (!player.isPlaying && player.canPlay) player.play()
  }

  function nextTrack() { if (running && player.canGoNext) player.next() }
  function previousTrack() { if (running && player.canGoPrevious) player.previous() }
  function toggleShuffle() { if (shuffleSupported) player.shuffle = !player.shuffle }

  // Off -> all -> one -> off, same cycle as Spotify's own repeat button.
  function cycleLoop() {
    if (!loopSupported) return
    if (player.loopState === MprisLoopState.None) player.loopState = MprisLoopState.Playlist
    else if (player.loopState === MprisLoopState.Playlist) player.loopState = MprisLoopState.Track
    else player.loopState = MprisLoopState.None
  }

  function raiseSpotify() { if (running && player.canRaise) player.raise() }

  // -------------------------------------------------- window position/size
  // Persists each window's last on-screen geometry to disk (outside the git
  // repo). SAVE-ONLY right now -- restoring on open is not currently
  // achievable on this machine, for two independent reasons hit and
  // confirmed while building this:
  //   - Position: this Hyprland build routes `dispatch` through a custom,
  //     undocumented Lua API (`hl.dsp.window.*`), not the standard
  //     dispatcher-string protocol `hyprctl dispatch`/Quickshell's
  //     Hyprland.dispatch() normally use -- confirmed by testing directly
  //     against the IPC socket; every standard movewindowpixel form was
  //     rejected.
  //   - Size: Quickshell's FloatingWindow only honors implicitWidth/Height
  //     once, at the exact moment of its own creation -- setting it (or
  //     width/height directly, which it explicitly logs as unsupported)
  //     afterward does nothing. Applying a saved size would need it to
  //     already be in hand by then, but there's no synchronous local file
  //     read available here (confirmed: Qt disables sync-XHR against
  //     file://, and even the shell's own theme loader is fully async via
  //     FileView.onLoaded).
  // The geometry is still recorded on the chance a working restore path
  // (an actual dispatcher name, or a sync read mechanism) turns up later.
  readonly property string windowStateDir: (Quickshell.env("HOME") || "") + "/.cache/isra-spotify-widget"
  readonly property string windowStatePath: windowStateDir + "/window-state.json"
  property var windowState: ({})

  function saveWindowGeometry(key, toplevelTitle) {
    windowGeometryQueryProc.pendingKey = key
    windowGeometryQueryProc.pendingTitle = toplevelTitle
    windowGeometryQueryProc.command = ["hyprctl", "-j", "clients"]
    windowGeometryQueryProc.running = true
  }

  Process {
    id: windowGeometryQueryProc
    property string pendingKey: ""
    property string pendingTitle: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var list = null
        try { list = JSON.parse(text) } catch (e) { list = null }
        if (!Array.isArray(list)) return
        var match = null
        for (var i = 0; i < list.length; i++) {
          if (list[i].title === windowGeometryQueryProc.pendingTitle) { match = list[i]; break }
        }
        if (!match || !Array.isArray(match.at) || !Array.isArray(match.size)) return
        var state = root.windowState || {}
        state[windowGeometryQueryProc.pendingKey] = { x: match.at[0], y: match.at[1], w: match.size[0], h: match.size[1] }
        root.windowState = state
        var json = JSON.stringify(state)
        windowStateSaveProc.command = ["bash", "-c",
          "mkdir -p \"$(dirname \"$0\")\" && printf '%s' \"$1\" > \"$0\"",
          root.windowStatePath, json]
        windowStateSaveProc.running = true
      }
    }
  }

  Process { id: windowStateSaveProc }

  // By the time onVisibleChanged fires (visible already false), the window
  // may already be unmapped and gone from `hyprctl clients` -- querying
  // fresh right at close time races the compositor and often loses. Poll
  // periodically instead while each window is open, so there's always a
  // recent (at most a couple seconds stale) geometry to fall back on
  // whichever way it closes; the close-time save further below is just a
  // best-effort top-up on top of that.
  Timer {
    running: root.opened
    interval: 2000
    repeat: true
    triggeredOnStart: true
    onTriggered: root.saveWindowGeometry("main", "Spotify Widget")
  }

  Timer {
    running: root.lyricsOpen
    interval: 2000
    repeat: true
    triggeredOnStart: true
    onTriggered: root.saveWindowGeometry("lyrics", "Spotify Lyrics")
  }

  // ---------------------------------------------------------------- lyrics
  // Fetched from lrclib.net (free, no-auth). Session-only cache keyed by
  // "artist::title" so flipping back to a track already shown doesn't
  // refetch. The lyrics window is a second FloatingWindow entirely separate
  // from the now-playing card below, toggled by lyricsOpen.
  //
  // Spotify's own (private, unofficial) lyrics endpoint was tried here too,
  // but its edge WAF blocks curl at the TLS-fingerprint level regardless of
  // cookie validity -- not fixable without heavier tooling (curl-impersonate
  // or a real browser engine), so it was dropped in favor of staying on the
  // simple, public lrclib.net path.
  property bool lyricsOpen: false
  property bool lyricsLoading: false
  property bool lyricsError: false
  property bool lyricsSynced: false
  property var lyricsLines: []      // [{time: seconds, text: string}], sorted
  property string lyricsPlainText: ""
  property var lyricsCache: ({})

  function lyricsCacheKey(forArtist, forTitle) { return forArtist + "::" + forTitle }

  // LRC lines look like "[01:02.34]some text", occasionally with more than
  // one timestamp tag sharing one line of text.
  function parseLrc(text) {
    var lines = []
    var stampPattern = /\[(\d{2}):(\d{2}(?:\.\d+)?)\]/g
    String(text || "").split("\n").forEach(function (rawLine) {
      stampPattern.lastIndex = 0
      var stamps = []
      var m
      while ((m = stampPattern.exec(rawLine)) !== null)
        stamps.push(parseInt(m[1], 10) * 60 + parseFloat(m[2]))
      if (stamps.length === 0) return
      var content = rawLine.replace(/\[\d{2}:\d{2}(?:\.\d+)?\]/g, "").trim()
      stamps.forEach(function (t) { lines.push({ time: t, text: content }) })
    })
    lines.sort(function (a, b) { return a.time - b.time })
    return lines
  }

  function pickLyricsFromEntry(entry) {
    if (!entry) return null
    var synced = String(entry.syncedLyrics || "")
    var plain = String(entry.plainLyrics || "")
    if (synced.trim() !== "") return { synced: true, lines: parseLrc(synced), plain: plain }
    if (plain.trim() !== "") return { synced: false, lines: [], plain: plain }
    return null
  }

  // Applies a well-formed fetch result (possibly "no match", result === null
  // for a track lrclib genuinely has nothing for) only if the track it was
  // fetched for is still the one showing -- guards against a fast track
  // change racing a slow network response.
  function applyLyricsResult(forArtist, forTitle, result) {
    if (forArtist !== root.artist || forTitle !== root.title) return
    lyricsLoading = false
    lyricsError = false
    lyricsSynced = result ? result.synced : false
    lyricsLines = result ? result.lines : []
    lyricsPlainText = result ? result.plain : ""
    if (result) lyricsCache[lyricsCacheKey(forArtist, forTitle)] = result
  }

  // Both the exact-match and search calls failed to return parseable JSON
  // (no network, curl missing, lrclib unreachable) -- distinct from a
  // successful response that simply has no lyrics for the track.
  function applyLyricsFetchError(forArtist, forTitle) {
    if (forArtist !== root.artist || forTitle !== root.title) return
    lyricsLoading = false
    lyricsError = true
    lyricsLines = []
    lyricsPlainText = ""
  }

  function requestLyricsSearch(forArtist, forTitle) {
    lyricsSearchProc.artistAtRequest = forArtist
    lyricsSearchProc.titleAtRequest = forTitle
    lyricsSearchProc.command = ["curl", "-s", "-G", "https://lrclib.net/api/search",
      "--data-urlencode", "artist_name=" + forArtist,
      "--data-urlencode", "track_name=" + forTitle]
    lyricsSearchProc.running = true
  }

  function requestLyrics(forArtist, forTitle, forAlbum, forDurationSeconds) {
    var cached = lyricsCache[lyricsCacheKey(forArtist, forTitle)]
    if (cached) { applyLyricsResult(forArtist, forTitle, cached); return }
    // The get/search Process objects are reused across requests; mutating
    // their tracking properties while one is still in flight would corrupt
    // the stale-response guard. Retry shortly instead of racing it.
    if (lyricsGetProc.running || lyricsSearchProc.running) { lyricsRetryTimer.restart(); return }
    lyricsLoading = true
    lyricsError = false
    lyricsLines = []
    lyricsPlainText = ""
    var args = ["curl", "-s", "-G", "https://lrclib.net/api/get",
      "--data-urlencode", "artist_name=" + forArtist,
      "--data-urlencode", "track_name=" + forTitle]
    if (forAlbum) args.push("--data-urlencode", "album_name=" + forAlbum)
    if (forDurationSeconds > 0) args.push("--data-urlencode", "duration=" + Math.round(forDurationSeconds))
    lyricsGetProc.artistAtRequest = forArtist
    lyricsGetProc.titleAtRequest = forTitle
    lyricsGetProc.command = args
    lyricsGetProc.running = true
  }

  function maybeFetchLyricsForCurrentTrack() {
    if (!lyricsOpen || !running) return
    if (title === "" && artist === "") return
    requestLyrics(artist, title, "", trackLength)
  }

  function toggleLyrics() {
    lyricsOpen = !lyricsOpen
    if (lyricsOpen) {
      maybeFetchLyricsForCurrentTrack()
      requestLyricsBgColor(artUrl)
      extractSpotifyFonts()
    }
  }

  // title/artist can update on separate ticks for the same track change
  // (MPRIS emits per-property signals); debounce so we fetch once with the
  // final pair instead of once per property.
  Timer {
    id: lyricsTrackChangeDebounce
    interval: 60
    onTriggered: root.maybeFetchLyricsForCurrentTrack()
  }
  onTitleChanged: if (lyricsOpen) lyricsTrackChangeDebounce.restart()
  onArtistChanged: if (lyricsOpen) lyricsTrackChangeDebounce.restart()
  onArtUrlChanged: if (lyricsOpen) requestLyricsBgColor(artUrl)

  Timer {
    id: lyricsRetryTimer
    interval: 250
    onTriggered: root.maybeFetchLyricsForCurrentTrack()
  }

  Process {
    id: lyricsGetProc
    property string artistAtRequest: ""
    property string titleAtRequest: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var forArtist = lyricsGetProc.artistAtRequest
        var forTitle = lyricsGetProc.titleAtRequest
        // Empty stdout means curl itself failed (no network, DNS, no
        // binary) rather than a well-formed "no match" response.
        if (String(text || "").trim() === "") { root.requestLyricsSearch(forArtist, forTitle); return }
        var entry = null
        try { entry = JSON.parse(text) } catch (e) { entry = null }
        var result = root.pickLyricsFromEntry(entry)
        if (result) root.applyLyricsResult(forArtist, forTitle, result)
        else root.requestLyricsSearch(forArtist, forTitle)
      }
    }
  }

  Process {
    id: lyricsSearchProc
    property string artistAtRequest: ""
    property string titleAtRequest: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var forArtist = lyricsSearchProc.artistAtRequest
        var forTitle = lyricsSearchProc.titleAtRequest
        if (String(text || "").trim() === "") { root.applyLyricsFetchError(forArtist, forTitle); return }
        var list = null
        var parseFailed = false
        try { list = JSON.parse(text) } catch (e) { parseFailed = true }
        if (parseFailed) { root.applyLyricsFetchError(forArtist, forTitle); return }
        var entry = Array.isArray(list) && list.length > 0 ? list[0] : null
        root.applyLyricsResult(forArtist, forTitle, root.pickLyricsFromEntry(entry))
      }
    }
  }

  // Index of the lyric line that should be highlighted/scrolled to for the
  // live playback position (last line whose timestamp has passed).
  function currentLyricsLineIndex() {
    if (!lyricsSynced || lyricsLines.length === 0) return -1
    var pos = trackPosition
    var idx = -1
    for (var i = 0; i < lyricsLines.length; i++) {
      if (lyricsLines[i].time > pos) break
      idx = i
    }
    return idx
  }

  // ------------------------------------------------------ lyrics window look
  // Everything below is presentation for the lyrics FloatingWindow only --
  // the now-playing card's own fonts/colors are untouched. Mirrors Spotify's
  // real lyrics view: a solid tint sampled from the album art (their
  // "vibrant" color) behind a blurred, darkened/saturated copy of the same
  // art, plus their actual "Spotify Mix" display font extracted from the
  // locally-installed Spotify app.
  property string lyricsBgColor: "#161616"
  property var lyricsBgColorCache: ({})

  // Perceived (ITU-R BT.601) luminance of a "#rrggbb" string, 0 (black) to 1
  // (white).
  function luminanceOfHexColor(hex) {
    var s = String(hex || "#161616").replace("#", "")
    var r = parseInt(s.substr(0, 2), 16) / 255
    var g = parseInt(s.substr(2, 2), 16) / 255
    var b = parseInt(s.substr(4, 2), 16) / 255
    return 0.299 * r + 0.587 * g + 0.114 * b
  }

  // Brighter album art needs a stronger dim for the white lyric text to
  // still pop; already-dark art barely needs any. Scales the flat dimming
  // overlay's opacity with the sampled background color's own luminance
  // instead of a single fixed value.
  readonly property real lyricsDimOpacity: Math.max(0.15, Math.min(0.6, 0.15 + luminanceOfHexColor(lyricsBgColor) * 0.5))

  // No lyrics text to lay over the art (still loading is excluded -- that's
  // a transient state, not "unavailable") -- show the cover plainly instead
  // of blurred/dimmed, since there's nothing that dimming is helping read.
  readonly property bool lyricsUnavailable: !lyricsLoading
    && (lyricsError || (!lyricsSynced && lyricsPlainText === "" && lyricsLines.length === 0))

  function requestLyricsBgColor(forArtUrl) {
    if (forArtUrl === "") { lyricsBgColor = "#161616"; return }
    var cached = lyricsBgColorCache[forArtUrl]
    if (cached) { lyricsBgColor = cached; return }
    if (lyricsBgColorProc.running) return
    lyricsBgColorProc.artUrlAtRequest = forArtUrl
    lyricsBgColorProc.command = ["bash", "-c",
      "tmp=$(mktemp --suffix=.img) && curl -s \"$0\" -o \"$tmp\" "
      + "&& magick \"$tmp\" -resize 1x1 txt:-; rm -f \"$tmp\"",
      forArtUrl]
    lyricsBgColorProc.running = true
  }

  Process {
    id: lyricsBgColorProc
    property string artUrlAtRequest: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var forArtUrl = lyricsBgColorProc.artUrlAtRequest
        var m = String(text || "").match(/#([0-9A-Fa-f]{6})/)
        if (!m || forArtUrl !== root.artUrl) return
        var color = "#" + m[1]
        root.lyricsBgColorCache[forArtUrl] = color
        root.lyricsBgColor = color
      }
    }
  }

  // Extracted once (cached on disk, outside the plugin's git repo) from the
  // locally-installed Spotify desktop app's own UI bundle -- never committed
  // anywhere. Falls back to a locally-installed geometric sans if Spotify
  // isn't installed at the expected path or extraction otherwise fails.
  readonly property string spotifyFontCacheDir: (Quickshell.env("HOME") || "") + "/.cache/isra-spotify-widget/fonts"
  // Qt's font loader can't read these woff2 files directly (no Brotli/WOFF2
  // support in this build's FreeType) -- decompress to a plain .ttf with
  // `woff2_decompress` right after extracting, and load that instead.
  readonly property string spotifyTitleFontPath: spotifyFontCacheDir + "/SpotifyMixUITitleVariable.ttf"
  readonly property string spotifyBodyFontPath: spotifyFontCacheDir + "/SpotifyMixUI-Regular.ttf"
  readonly property string spotifyDisplayFontFamily: titleFontLoader.status === FontLoader.Ready ? titleFontLoader.name : "Adwaita Sans"
  readonly property string spotifyBodyFontFamily: bodyFontLoader.status === FontLoader.Ready ? bodyFontLoader.name : "Adwaita Sans"

  function extractSpotifyFonts() {
    var script = "mkdir -p \"$0\"; "
      + "if [ ! -f \"$0/SpotifyMixUITitleVariable.ttf\" ]; then "
      + "unzip -p /opt/spotify/Apps/xpui.spa fonts/SpotifyMixUITitleVariable.woff2 > \"$0/SpotifyMixUITitleVariable.woff2.tmp\" 2>/dev/null "
      + "&& mv \"$0/SpotifyMixUITitleVariable.woff2.tmp\" \"$0/SpotifyMixUITitleVariable.woff2\" "
      + "&& woff2_decompress \"$0/SpotifyMixUITitleVariable.woff2\" 2>/dev/null; "
      + "rm -f \"$0/SpotifyMixUITitleVariable.woff2.tmp\"; fi; "
      + "if [ ! -f \"$0/SpotifyMixUI-Regular.ttf\" ]; then "
      + "unzip -p /opt/spotify/Apps/xpui.spa fonts/SpotifyMixUI-Regular.woff2 > \"$0/SpotifyMixUI-Regular.woff2.tmp\" 2>/dev/null "
      + "&& mv \"$0/SpotifyMixUI-Regular.woff2.tmp\" \"$0/SpotifyMixUI-Regular.woff2\" "
      + "&& woff2_decompress \"$0/SpotifyMixUI-Regular.woff2\" 2>/dev/null; "
      + "rm -f \"$0/SpotifyMixUI-Regular.woff2.tmp\"; fi"
    spotifyFontExtractProc.command = ["bash", "-c", script, spotifyFontCacheDir]
    spotifyFontExtractProc.running = true
  }

  // Loaders start with no source and are pointed at the cached files only
  // once extraction has actually finished -- assigning `source` is what
  // kicks off loading, so this is a single clean assignment per loader
  // rather than a load attempt against a file that may not exist yet
  // followed by a forced reload once it does.
  Process {
    id: spotifyFontExtractProc
    onExited: {
      titleFontLoader.source = "file://" + root.spotifyTitleFontPath
      bodyFontLoader.source = "file://" + root.spotifyBodyFontPath
    }
  }

  FontLoader { id: titleFontLoader }
  FontLoader { id: bodyFontLoader }

  // Font size and side margins scale with the lyrics window's own live width
  // (it's user-resizable) instead of a fixed value, the same way growScale
  // below scales the now-playing card's art/title against that window.
  readonly property real lyricsFontPx: Math.max(20, Math.min(44, lyricsWindow.width * 0.09))
  readonly property real lyricsMarginPx: Math.max(16, Math.min(48, lyricsWindow.width * 0.08))

  // Baseline (unscaled) window size, captured once the window settles at its
  // initial preferred size. Growing the window past this makes the art and
  // track title scale up too, instead of leaving dead space below the
  // controls -- growth stays clamped to 1x on the low end so shrinking back
  // to (or below) the baseline never shrinks the art below normal.
  property real baseContentWidth: Style.space(266)
  property real baseContentHeight: Style.space(190)
  // headerArea's own natural height, captured alongside the two above.
  // bottomArea (seek bar + controls) has a roughly fixed height regardless
  // of the window's height, so headerArea's *available* space isn't a fixed
  // fraction of window.height -- at an extreme wide-but-short window, using
  // window.height/baseContentHeight let growScale (and so the art frame)
  // outgrow the header's real remaining room and spill past it. Comparing
  // against headerArea's own live height instead ties growth to space that
  // actually exists, which also happens to weight height over width the way
  // the header visually needs (a wider window alone no longer inflates it).
  property real baseHeaderHeight: 1
  readonly property real growScale: Math.max(1, Math.min(
    window.width / baseContentWidth,
    headerArea.height / baseHeaderHeight
  ))

  component ModeButton: Button {
    id: mode
    property bool on: false
    foreground: on ? root.accentColor : Qt.darker(Color.popups.text, 1.35)
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY
    opacity: enabled ? 1.0 : 0.4

    Behavior on foreground { ColorAnimation { duration: 120 } }

    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(2)
      width: Style.space(3)
      height: width
      radius: width / 2
      color: root.accentColor
      visible: mode.on
    }
  }

  FloatingWindow {
    id: window
    title: "Spotify Widget"
    visible: root.opened
    color: Color.popups.background
    // Set once at creation as the initial/preferred size. Left unbound after
    // that (rather than kept live against content.implicitHeight) so it does
    // not fight the Wayland resize protocol while the user is dragging an
    // edge -- content below re-flows against the window's live width/height
    // via anchors, independent of this initial value.
    Component.onCompleted: {
      // Wide enough for all six bottom-row controls (shuffle, prev, play,
      // next, repeat, lyrics) plus their spacing -- a fixed width narrower
      // than the row's natural width would silently push the last control
      // off the edge of the window instead of wrapping or clipping visibly.
      var w = Style.space(310)
      var h = content.implicitHeight + Style.space(28)
      implicitWidth = w
      implicitHeight = h
      // Tall enough that headerArea always keeps room for the unscaled art
      // frame above bottomArea's fixed-height seek+controls block, even at
      // the smallest allowed size -- otherwise the two would overlap.
      minimumSize = Qt.size(Style.space(260), Style.space(180))
      root.baseContentWidth = w
      root.baseContentHeight = h
      root.baseHeaderHeight = Math.max(1, headerArea.height)
    }

    onVisibleChanged: {
      if (!visible) {
        root.saveWindowGeometry("main", "Spotify Widget")
        if (!root.closingFromHost && root.shell && typeof root.shell.hide === "function")
          root.shell.hide("isra.spotify-widget")
      }
    }

    Item {
      id: card
      anchors.fill: parent

      Item {
        id: content
        anchors.fill: parent
        anchors.margins: Style.space(14)

        // Seek bar + controls (bottomArea) claim only the fixed height they
        // need, bottom-anchored close to the window edge. Art/title/artist
        // (headerArea) fill everything ABOVE that -- anchored to bottomArea's
        // top rather than a fixed fraction, so the two can never overlap
        // regardless of window size, and header naturally grows to dominate
        // (well past 65%) as the window gets taller.
        Item {
          id: headerArea
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: bottomArea.top
          anchors.bottomMargin: Style.space(8)
          clip: true

          Row {
            id: header
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            spacing: Style.space(12)

          BorderSurface {
            id: artFrame
            width: Style.space(56) * root.growScale
            height: width
            radius: Style.cornerRadius
            color: Style.normalFillFor(Color.popups.text, Color.popups.text)
            borderSpec: Border.flat(hyprBorder.color, hyprBorder.width)

            Rectangle {
              id: artMask
              anchors.fill: parent
              anchors.margins: artFrame.borderTop
              visible: false
              layer.enabled: true
              radius: Math.max(0, artFrame.radius - artFrame.borderTop)
              color: "white"
            }

            Item {
              anchors.fill: parent
              anchors.margins: artFrame.borderTop
              visible: root.artUrl !== ""
              layer.enabled: true
              layer.smooth: true
              layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: artMask
                maskThresholdMin: 0.5
                maskSpreadAtMin: 0.3
              }

              Image {
                id: art
                anchors.fill: parent
                source: root.artUrl
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                smooth: true
                sourceSize.width: artFrame.width * 2
                sourceSize.height: artFrame.height * 2
              }
            }

            Text {
              anchors.centerIn: parent
              visible: root.artUrl === "" || art.status === Image.Error
              text: ""
              color: Qt.darker(Color.popups.text, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.displayLarge
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.raiseSpotify()
            }
          }

          Column {
            width: header.width - artFrame.width - header.spacing
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(3)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.title || "Nothing playing"
              color: Color.popups.text
              font.family: root.spotifyDisplayFontFamily
              font.pixelSize: Style.font.subtitle * root.growScale
              font.bold: true
              // Spotify Mix (and the Adwaita Sans fallback) are variable
              // fonts -- font.bold/weight alone doesn't reliably select a
              // named instance on a dynamically-loaded variable font in
              // this Qt build, so drive the weight axis directly too.
              font.variableAxes: { "wght": 700 }
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.artist
              color: Qt.darker(Color.popups.text, 1.3)
              font.family: root.spotifyBodyFontFamily
              font.pixelSize: Style.font.bodySmall * root.growScale
              elide: Text.ElideRight
              visible: text !== ""
            }
          }
        }
        }

        Column {
          id: bottomArea
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(4)
          spacing: Style.space(4)

        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.trackLength > 0

          PanelSlider {
            id: seek
            width: parent.width
            minimum: 0
            maximum: Math.max(1, root.trackLength)
            value: Math.min(root.trackPosition, root.trackLength)
            step: 5
            fillColor: root.accentColor
            knobColor: root.accentColor
            enabled: root.canSeek
            opacity: root.canSeek ? 1 : 0.45
            onReleased: function (target) { if (root.canSeek) root.player.position = target }
          }

          Item {
            width: parent.width
            height: elapsedLabel.implicitHeight

            Text {
              id: elapsedLabel
              anchors.left: parent.left
              textFormat: Text.PlainText
              text: root.formatTime(seek.dragging ? seek.liveValue : root.trackPosition)
              color: Qt.darker(Color.popups.text, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.right: parent.right
              textFormat: Text.PlainText
              text: root.formatTime(root.trackLength)
              color: Qt.darker(Color.popups.text, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(8)

          ModeButton {
            iconText: "󰒝"
            on: root.shuffle
            enabled: root.shuffleSupported
            tooltipText: root.shuffle ? "Shuffle on" : "Shuffle off"
            onClicked: root.toggleShuffle()
          }

          Button {
            iconText: "󰒮"
            foreground: Color.popups.text
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            enabled: root.running && root.player.canGoPrevious
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.previousTrack()
          }

          Button {
            iconText: root.playing ? "󰏤" : "󰐊"
            foreground: root.playing ? root.accentColor : Color.popups.text
            horizontalPadding: Style.spacing.panelGap
            verticalPadding: Style.spacing.controlPaddingY
            iconSize: Style.font.iconLarge
            enabled: root.running && (root.player.canTogglePlaying || root.player.canPlay || root.player.canPause)
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.playPause()
          }

          Button {
            iconText: "󰒭"
            foreground: Color.popups.text
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            enabled: root.running && root.player.canGoNext
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.nextTrack()
          }

          ModeButton {
            iconText: root.loopState === MprisLoopState.Track ? "󰑘" : "󰑖"
            on: root.loopState !== MprisLoopState.None
            enabled: root.loopSupported
            tooltipText: "Repeat " + (root.loopState === MprisLoopState.Track ? "one" : root.loopState === MprisLoopState.Playlist ? "all" : "off")
            onClicked: root.cycleLoop()
          }

          ModeButton {
            // Font Awesome "quote-left", from the font's BMP PUA range
            // (U+E000-F8FF). The higher Material Design Icons codepoints
            // used by the other buttons live in Plane 15 and rendered as a
            // "TM" fallback glyph in this Qt build -- stick to the BMP range
            // for any future icon here.
            iconText: ""
            on: root.lyricsOpen
            enabled: root.running
            tooltipText: root.lyricsOpen ? "Hide lyrics" : "Show lyrics"
            onClicked: root.toggleLyrics()
          }
        }
        }
      }
    }
  }

  // Independent draggable window for the current track's lyrics, opened via
  // the lyrics ModeButton above. Kept as a real, separate FloatingWindow
  // (not nested inside the card) so it behaves like any other Hyprland
  // window -- closing it does not touch the now-playing card, only the
  // reverse (see root.close()).
  FloatingWindow {
    id: lyricsWindow
    title: "Spotify Lyrics"
    visible: root.lyricsOpen
    color: "black"

    Component.onCompleted: {
      implicitWidth = Style.space(300)
      implicitHeight = Style.space(420)
      minimumSize = Qt.size(Style.space(220), Style.space(220))
    }

    onVisibleChanged: {
      if (!visible) {
        root.saveWindowGeometry("lyrics", "Spotify Lyrics")
        root.lyricsOpen = false
      }
    }

    // Spotify-style backdrop: a solid tint sampled from the album art behind
    // a heavily blurred, darkened/saturated, oversized copy of the same art
    // (150% of the window, centered) so it keeps fully covering the window
    // through a live resize with no edge gaps once clipped to bounds.
    Item {
      id: lyricsBackground
      anchors.fill: parent
      clip: true

      Rectangle {
        anchors.fill: parent
        color: root.lyricsBgColor
        Behavior on color { ColorAnimation { duration: 300 } }
      }

      Item {
        id: lyricsArtWrap
        width: lyricsBackground.width * 1.5
        height: lyricsBackground.height * 1.5
        anchors.centerIn: parent
        visible: root.artUrl !== ""
        // No blur/saturation adjustment when there's no lyrics text sitting
        // over the art -- just the plain cover.
        layer.enabled: !root.lyricsUnavailable
        layer.smooth: true
        layer.effect: MultiEffect {
          // MultiEffect's brightness is an additive shift, not CSS's
          // multiplicative brightness(0.5) -- a similarly "50%" value here
          // crushes shadows to near-black instead of just dimming, so this
          // stays mild. Actual dimming for text contrast is the flat
          // translucent Rectangle below instead, which is predictable to
          // tune (just its opacity) regardless of shader semantics.
          saturation: 0.25
          blurEnabled: true
          blur: 1.0
          blurMax: Math.max(40, Math.min(110, lyricsWindow.width * 0.32))
        }

        Image {
          anchors.fill: parent
          source: root.artUrl
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
          smooth: true
          sourceSize.width: width
          sourceSize.height: height
        }
      }

      // Dimming for text contrast, independent of the blur shader's own
      // brightness handling -- scales with the art's own brightness (see
      // lyricsDimOpacity) instead of one fixed value for every cover.
      Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: root.lyricsUnavailable ? 0 : root.lyricsDimOpacity
        Behavior on opacity { NumberAnimation { duration: 300 } }
      }
    }

    Item {
      anchors.fill: parent
      anchors.margins: root.lyricsMarginPx

      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        wrapMode: Text.WordWrap
        visible: root.lyricsLoading
        text: "Loading lyrics…"
        color: Qt.rgba(1, 1, 1, 0.75)
        font.family: root.spotifyBodyFontFamily
        font.pixelSize: root.lyricsFontPx * 0.55
      }

      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        wrapMode: Text.WordWrap
        visible: root.lyricsUnavailable
        text: root.lyricsError ? "Couldn't fetch lyrics." : "No lyrics found for this track."
        color: Qt.rgba(1, 1, 1, 0.75)
        font.family: root.spotifyBodyFontFamily
        font.pixelSize: root.lyricsFontPx * 0.55
      }

      // Synced lyrics: scrolling list with the current line highlighted,
      // matching Spotify's own treatment -- current + already-played lines
      // full white, upcoming lines dimmed, current line bolder and slightly
      // larger, left-aligned with tightened tracking.
      ListView {
        id: syncedList
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        // Scales with the (responsive) lyric font size instead of a fixed
        // 6px -- that read as cramped/overlapping once lines got much
        // bigger, especially since the active line's scale transform below
        // grows it past the height ListView allocated for it; this margin
        // comfortably absorbs that too.
        spacing: root.lyricsFontPx * 0.45
        visible: !root.lyricsLoading && !root.lyricsError && root.lyricsSynced && root.lyricsLines.length > 0
        model: visible ? root.lyricsLines : null

        readonly property int currentIndex_: root.currentLyricsLineIndex()
        onCurrentIndex_Changed: if (currentIndex_ >= 0) positionViewAtIndex(currentIndex_, ListView.Center)

        // Default Flickable wheel scrolling reads sluggish once lines got
        // this big -- take wheel/trackpad input over ourselves at a bigger
        // step instead of the built-in handling.
        WheelHandler {
          acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
          onWheel: function (event) {
            var maxY = Math.max(0, syncedList.contentHeight - syncedList.height)
            syncedList.contentY = Math.max(0, Math.min(maxY, syncedList.contentY - event.angleDelta.y * 2.2))
            event.accepted = true
          }
        }

        // How much bigger the current line renders. A scale transform (not
        // a real font.pixelSize change) so growing/shrinking it never
        // re-runs word-wrap -- changing pixelSize mid-line reflows text at
        // the new size, which visibly jumps/reshuffles words as the active
        // line changes. Every delegate wraps at this much *less* than the
        // full width up front, so the active line's scaled-up rendered
        // width still lands within the container instead of overflowing.
        readonly property real activeScale: 1.08

        delegate: Text {
          width: syncedList.width / syncedList.activeScale
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: modelData.text
          horizontalAlignment: Text.AlignLeft
          color: index <= syncedList.currentIndex_ ? "white" : Qt.rgba(1, 1, 1, 0.55)
          font.family: root.spotifyDisplayFontFamily
          font.pixelSize: root.lyricsFontPx
          font.weight: Font.Bold
          font.variableAxes: { "wght": 700 }
          // Spotify's own CSS uses -0.04em here, but that magnitude made
          // adjacent glyphs visibly overlap/collide in this font/renderer --
          // no negative tracking at all reads cleanly instead.
          font.letterSpacing: 0
          lineHeight: 1.15
          scale: index === syncedList.currentIndex_ ? syncedList.activeScale : 1.0
          transformOrigin: Item.TopLeft

          Behavior on color { ColorAnimation { duration: 200 } }
          Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        }
      }

      // Plain lyrics fallback: static, freely scrollable text.
      Flickable {
        id: plainLyricsFlick
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true
        contentHeight: plainText.implicitHeight
        visible: !root.lyricsLoading && !root.lyricsError && !root.lyricsSynced && root.lyricsPlainText !== ""

        WheelHandler {
          acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
          onWheel: function (event) {
            var maxY = Math.max(0, plainLyricsFlick.contentHeight - plainLyricsFlick.height)
            plainLyricsFlick.contentY = Math.max(0, Math.min(maxY, plainLyricsFlick.contentY - event.angleDelta.y * 2.2))
            event.accepted = true
          }
        }

        Text {
          id: plainText
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignLeft
          text: root.lyricsPlainText
          color: "white"
          font.family: root.spotifyDisplayFontFamily
          font.pixelSize: root.lyricsFontPx * 0.85
          font.weight: Font.Bold
          font.variableAxes: { "wght": 700 }
          font.letterSpacing: 0
          lineHeight: 1.3
        }
      }
    }
  }
}
