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

  function open(payloadJson) { opened = true }
  function close() {
    closingFromHost = true
    opened = false
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
  // window is open and something is playing.
  Timer {
    running: root.opened && root.playing && root.canSeek
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

  // Baseline (unscaled) window size, captured once the window settles at its
  // initial preferred size. Growing the window past this makes the art and
  // track title scale up too, instead of leaving dead space below the
  // controls -- growth stays clamped to 1x on the low end so shrinking back
  // to (or below) the baseline never shrinks the art below normal.
  property real baseContentWidth: Style.space(266)
  property real baseContentHeight: Style.space(190)
  readonly property real growScale: Math.max(1, Math.min(
    window.width / baseContentWidth,
    window.height / baseContentHeight
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
      var w = Style.space(266)
      var h = content.implicitHeight + Style.space(28)
      implicitWidth = w
      implicitHeight = h
      // Tall enough that headerArea always keeps room for the unscaled art
      // frame above bottomArea's fixed-height seek+controls block, even at
      // the smallest allowed size -- otherwise the two would overlap.
      minimumSize = Qt.size(Style.space(220), Style.space(180))
      root.baseContentWidth = w
      root.baseContentHeight = h
    }

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide("isra.spotify-widget")
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
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle * root.growScale
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.artist
              color: Qt.darker(Color.popups.text, 1.3)
              font.family: Style.font.family
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
        }
        }
      }
    }
  }
}
