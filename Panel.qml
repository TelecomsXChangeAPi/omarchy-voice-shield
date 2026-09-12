import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Open Voice Shield in the Omarchy bar: a shield pill that badges today's
// high-risk verdicts, and a panel with the live SIP calls, the week's traffic,
// and the most recent fraud analyses.
Panel {
  id: root
  moduleName: "tcxc.voice-shield"
  ipcTarget: "tcxc.voice-shield"
  // manageIpc: false so this panel owns the single IpcHandler the target
  // permits — needed for the refresh method below.
  manageIpc: false

  readonly property string shieldGlyph: "󰒙"
  readonly property string alertGlyph: "󰻌"
  readonly property string phoneGlyph: "󰏲"

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string face: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.4)

  property var snap: Model.emptySnapshot()
  // Ids of high-risk calls already announced. The first successful fetch only
  // fills this list; `primed` is what unlocks notifications, so a shell
  // restart never replays the backlog as a burst of desktop alerts.
  property var seenIds: []
  property bool primed: false
  property double fetchedAt: 0
  property double nowMs: Date.now()

  property bool cursorActive: false
  property int cursorIndex: 0

  // Drives the media-flow dots on every live-call card from one source, so the
  // rows step in lockstep rather than drifting apart.
  property real flowPhase: 0
  NumberAnimation on flowPhase {
    running: root.opened
    loops: Animation.Infinite
    from: -0.6
    to: 3.2
    duration: 1400
  }

  readonly property int refreshIntervalSec: Math.max(15, parseInt(setting("refreshIntervalSec", 60), 10) || 60)
  readonly property bool notifyHighRisk: setting("notifyHighRisk", true) === true
  readonly property int highRiskThreshold: Math.max(1, parseInt(setting("highRiskThreshold", 70), 10) || 70)
  // Masked by default — a bar panel is on screen during screen-shares and
  // screenshots, so full subscriber numbers are opt-in, not the default.
  readonly property bool maskNumbers: setting("maskNumbers", true) !== false

  readonly property bool healthy: snap && snap.ok === true
  readonly property var liveCalls: healthy ? Model.liveItems(snap, 3) : []
  readonly property var verdicts: healthy ? Model.highRiskItems(snap, 4) : []
  readonly property var segments: healthy ? Model.riskSegments(snap) : []
  readonly property var bars: healthy ? Model.sparkBars(snap) : []

  // Absolute path to the fetch helper, derived from this file's own location
  // so the plugin works from any install path (git clone, XDG config, a
  // checkout under /tmp for testing).
  readonly property string scriptPath: {
    var url = Qt.resolvedUrl("ovs-fetch").toString()
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }

  function severityColor(level) {
    if (level >= 2) return Color.urgent
    if (level === 1) return Color.accent
    return Qt.rgba(fg.r, fg.g, fg.b, 0.45)
  }

  // Live calls keep counting up between fetches instead of freezing on the
  // server's snapshot value — a stalled timer is what makes a status panel
  // feel dead.
  function liveElapsed(call) {
    var base = call && call.elapsed_sec ? parseInt(call.elapsed_sec, 10) || 0 : 0
    if (fetchedAt <= 0) return base
    return base + Math.max(0, Math.floor((nowMs - fetchedAt) / 1000))
  }

  function refresh() {
    if (!fetchProc.running) fetchProc.running = true
  }

  function applySnapshot(raw) {
    var next = Model.parseSnapshot(raw)

    // A transient failure keeps the last good reading on screen rather than
    // blanking a panel that was correct a minute ago.
    if (next.ok !== true && root.healthy) {
      root.snap = Object.assign({}, root.snap, { stale: true, error: next.error })
      return
    }

    root.snap = next
    if (next.ok !== true) return

    var fresh = Model.unannouncedHighRisk(next, root.seenIds, root.highRiskThreshold, root.primed)
    root.seenIds = Model.rememberIds(next, root.seenIds)
    root.primed = true
    root.fetchedAt = Date.now()
    root.nowMs = root.fetchedAt

    if (root.notifyHighRisk) {
      for (var i = 0; i < fresh.length; i++) announce(fresh[i])
    }
  }

  function announce(call) {
    Quickshell.execDetached([
      "omarchy-notification-send",
      "--app-name", "voice-shield",
      "-u", "critical",
      "-g", root.alertGlyph,
      "Open Voice Shield — " + Model.category(call),
      Model.notificationBody(call, root.maskNumbers)
    ])
  }

  // The OVS console is a single-page app mounted at /app; every view is nested
  // under it (/app/calls/:callId, /app/live/:callId). Linking to a bare
  // /calls/... path misses the router and lands on the login redirect.
  readonly property string consoleUrl: "https://ovs.telecomsxchange.com/app"

  function openDashboard() {
    Quickshell.execDetached(["omarchy-launch-browser", root.consoleUrl])
    root.close()
  }

  function openCall(call) {
    if (!call || !call.id) return
    Quickshell.execDetached(["omarchy-launch-browser", root.consoleUrl + "/calls/" + call.id])
    root.close()
  }

  function moveCursor(delta) {
    if (verdicts.length === 0) return
    var next = cursorIndex + delta
    cursorIndex = next < 0 ? verdicts.length - 1 : (next >= verdicts.length ? 0 : next)
  }

  function activateCursor() {
    if (!cursorActive || cursorIndex < 0 || cursorIndex >= verdicts.length) return
    openCall(verdicts[cursorIndex])
  }

  IpcHandler {
    target: "tcxc.voice-shield"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  onOpenedChanged: {
    if (!opened) return
    cursorActive = false
    cursorIndex = 0
    refresh()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: fetchProc
    command: ["bash", root.scriptPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySnapshot(text)
    }
  }

  // Background poll: the pill and the high-risk notifications have to stay
  // current whether or not anyone opens the panel.
  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Faster cadence while the panel is on screen.
  Timer {
    interval: 10000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  // Drives the live-call clocks and the "3m ago" labels.
  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.pillText(root.snap, root.shieldGlyph, root.alertGlyph)
    active: root.healthy && Model.highRiskToday(root.snap) > 0
    slotSize: Style.bar.iconSlot * (Model.pillText(root.snap, "x", "x").length > 1 ? 1.7 : 1)
    tooltipText: Model.tooltipText(root.snap)

    onPressed: function(b) {
      if (b === Qt.RightButton) root.refresh()
      else if (b === Qt.MiddleButton) root.openDashboard()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy !== 0 ? dy : dx)
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: shield · title/status · calls today ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroCount.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.healthy && Model.highRiskToday(root.snap) > 0 ? root.alertGlyph : root.shieldGlyph
            color: root.healthy && Model.highRiskToday(root.snap) > 0 ? Color.urgent : root.fg
            font.family: root.face
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroCount.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Open Voice Shield"
              color: root.fg
              font.family: root.face
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: {
                if (!root.healthy) return Model.errorLabel(root.snap ? root.snap.error : "")
                var parts = [Model.activeCalls(root.snap) + " active"]
                if (Model.ports(root.snap) > 0) parts.push(Model.ports(root.snap) + " ports")
                parts.push(Model.highRiskToday(root.snap) + " high risk today")
                return parts.join(" · ")
              }
              color: root.snap && root.snap.stale ? Color.urgent : root.dim
              font.family: root.face
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroCount
            textFormat: Text.PlainText
            text: root.healthy ? Model.fmtInt(Model.callsToday(root.snap)) : "—"
            color: root.fg
            font.family: root.face
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- Unconfigured / unreachable empty state ----------
        Column {
          visible: !root.healthy
          width: parent.width
          spacing: Style.space(6)

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: {
              var code = String(root.snap ? root.snap.error : "")
              if (code === "no-config" || code === "no-key" || code === "bad-config")
                return "Add an Open Voice Shield API key to " + Model.configPath(Quickshell.env("HOME"))
                  + " as {\"apiKey\": \"ovs_…\"} — mint one from the OVS dashboard under API keys."
              if (code === "jq-missing") return "This widget needs jq. Install it with: omarchy pkg add jq"
              return "Could not reach the Open Voice Shield API. The panel keeps retrying every "
                + root.refreshIntervalSec + "s."
            }
            color: root.dim
            font.family: root.face
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---------- Risk distribution ----------
        Column {
          visible: root.segments.length > 0
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Style.space(8)

            Rectangle {
              anchors.fill: parent
              radius: height / 2
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10)
            }

            Row {
              anchors.fill: parent
              spacing: Style.space(2)

              Repeater {
                model: root.segments
                Rectangle {
                  required property var modelData
                  height: parent.height
                  width: Math.max(modelData.fraction > 0 ? Style.space(3) : 0,
                                  (parent.width - Style.space(2) * (root.segments.length - 1)) * modelData.fraction)
                  radius: height / 2
                  color: root.severityColor(modelData.severity)

                  Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                }
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(14)

            Repeater {
              model: root.segments
              Row {
                required property var modelData
                spacing: Style.space(5)

                Rectangle {
                  width: Style.space(7)
                  height: Style.space(7)
                  radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.severityColor(modelData.severity)
                }

                Text {
                  textFormat: Text.PlainText
                  text: modelData.label + " " + Model.fmtInt(modelData.count)
                  color: root.dim
                  font.family: root.face
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        // ---------- Week of traffic ----------
        // Two strips on separate scales: call volume against the busiest day,
        // high-risk count against the worst day. Stacking them would clamp
        // every high-risk sliver to one pixel (see Model.sparkBars).
        Column {
          visible: root.bars.length > 0
          width: parent.width
          spacing: Style.space(4)

          PanelSectionHeader {
            text: "VOLUME · HIGH RISK"
            foreground: root.fg
            fontFamily: root.face
          }

          Row {
            id: sparkRow
            width: parent.width
            height: Style.space(30)
            spacing: Style.space(4)

            readonly property real cellWidth: root.bars.length > 0
              ? (width - spacing * (root.bars.length - 1)) / root.bars.length
              : 0

            Repeater {
              model: root.bars
              Item {
                required property var modelData
                width: sparkRow.cellWidth
                height: sparkRow.height

                Rectangle {
                  anchors.bottom: parent.bottom
                  width: parent.width
                  height: Math.max(Style.space(2), parent.height * modelData.fraction)
                  radius: Style.space(2)
                  color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.26)

                  Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                }
              }
            }
          }

          Row {
            width: parent.width
            height: Style.space(10)
            spacing: Style.space(4)

            Repeater {
              model: root.bars
              Item {
                required property var modelData
                width: sparkRow.cellWidth
                height: parent.height

                Rectangle {
                  anchors.top: parent.top
                  width: parent.width
                  height: modelData.highRisk > 0
                    ? Math.max(Style.space(2), parent.height * modelData.riskFraction)
                    : 0
                  radius: Style.space(2)
                  color: Color.urgent

                  Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                }
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.bars
              Text {
                required property var modelData
                width: sparkRow.cellWidth
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                text: Model.dayInitial(modelData.date)
                color: root.dim
                font.family: root.face
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // ---------- Period stats ----------
        Row {
          visible: root.healthy
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: "Calls (" + (root.snap.dashboard ? root.snap.dashboard.days : "—") + "d)"
              value: Model.fmtInt(root.snap.dashboard ? root.snap.dashboard.calls_period : null)
            }
            InfoPair {
              label: "Minutes"
              value: Model.fmtMinutes(root.snap.dashboard ? root.snap.dashboard.minutes_period : null)
            }
            InfoPair {
              label: "High risk"
              value: Model.fmtPct(Model.highRiskPct(root.snap))
            }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: "Spend"
              value: Model.fmtMoney(root.snap.dashboard ? root.snap.dashboard.spend_period : null)
            }
            InfoPair {
              label: "Balance"
              value: Model.fmtMoney(root.snap.dashboard ? root.snap.dashboard.balance : null)
            }
            InfoPair {
              label: "Ports"
              value: Model.portsInUse(root.snap) + " / " + Model.ports(root.snap)
            }
          }
        }

        // ---------- Live calls ----------
        PanelSeparator {
          visible: root.liveCalls.length > 0
          foreground: root.fg
        }

        Column {
          visible: root.liveCalls.length > 0
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "ON THE WIRE"
            foreground: root.fg
            fontFamily: root.face
          }

          Repeater {
            model: root.liveCalls

            Rectangle {
              id: liveCard
              required property var modelData
              readonly property bool connected: Model.liveConnected(modelData)
              readonly property color tone: connected ? Color.accent : root.fg
              readonly property int elapsed: root.liveElapsed(modelData)
              readonly property real capProgress: Model.liveProgress(modelData, elapsed)

              width: parent.width
              implicitHeight: cardBody.implicitHeight + Style.space(16)
              radius: Style.cornerRadius
              color: Qt.rgba(tone.r, tone.g, tone.b, 0.06)

              // Edge stripe carries the call state without spending a word on it.
              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Style.space(2)
                radius: width
                color: liveCard.tone
                opacity: 0.85
              }

              Column {
                id: cardBody
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(7)

                // ---- route ----
                Item {
                  width: parent.width
                  implicitHeight: Math.max(ping.height, routeRow.implicitHeight, clock.implicitHeight)

                  // Radar ping: a dot with a ring expanding out of it.
                  Item {
                    id: ping
                    width: Style.space(10)
                    height: width
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter

                    Rectangle {
                      anchors.centerIn: parent
                      width: Style.space(6)
                      height: width
                      radius: width / 2
                      color: liveCard.tone
                    }

                    Rectangle {
                      anchors.centerIn: parent
                      width: Style.space(6)
                      height: width
                      radius: width / 2
                      color: "transparent"
                      border.width: 1
                      border.color: liveCard.tone

                      SequentialAnimation on scale {
                        running: root.opened
                        loops: Animation.Infinite
                        NumberAnimation { from: 1.0; to: 2.9; duration: 1600; easing.type: Easing.OutQuad }
                      }

                      SequentialAnimation on opacity {
                        running: root.opened
                        loops: Animation.Infinite
                        NumberAnimation { from: 0.6; to: 0.0; duration: 1600; easing.type: Easing.OutQuad }
                      }
                    }
                  }

                  Row {
                    id: routeRow
                    anchors.left: ping.right
                    anchors.leftMargin: Style.space(11)
                    anchors.right: clock.left
                    anchors.rightMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(9)

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: Model.fmtNumber(liveCard.modelData.ani, root.maskNumbers)
                      color: root.fg
                      font.family: root.face
                      font.pixelSize: Style.font.bodySmall
                    }

                    // Media stepping toward the callee.
                    Row {
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(3)

                      Repeater {
                        model: 3
                        Rectangle {
                          required property int index
                          width: Style.space(3)
                          height: width
                          radius: width / 2
                          color: liveCard.tone
                          opacity: Math.max(0.15, 1.0 - Math.abs(root.flowPhase - index))
                        }
                      }
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: Model.fmtNumber(liveCard.modelData.dialed, root.maskNumbers)
                      color: root.fg
                      font.family: root.face
                      font.pixelSize: Style.font.bodySmall
                    }
                  }

                  Text {
                    id: clock
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: Model.elapsedLabel(liveCard.elapsed)
                    color: root.fg
                    font.family: root.face
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                  }
                }

                // ---- state, route context, and progress toward the call cap ----
                Item {
                  width: parent.width
                  implicitHeight: Math.max(meta.implicitHeight, capTrack.height)

                  Text {
                    id: meta
                    anchors.left: parent.left
                    anchors.right: capTrack.left
                    anchors.rightMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: {
                      var state = liveCard.connected ? "CONNECTED" : "RINGING"
                      var context = Model.liveMeta(liveCard.modelData)
                      return context === "" ? state : state + "  ·  " + context
                    }
                    color: root.dim
                    font.family: root.face
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 0.9
                    elide: Text.ElideRight
                  }

                  Rectangle {
                    id: capTrack
                    visible: liveCard.capProgress > 0
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(58)
                    height: Style.space(3)
                    radius: height / 2
                    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.14)

                    Rectangle {
                      anchors.left: parent.left
                      height: parent.height
                      radius: parent.radius
                      width: parent.width * liveCard.capProgress
                      color: liveCard.tone

                      Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                    }
                  }
                }
              }
            }
          }
        }

        // ---------- Recent verdicts ----------
        PanelSeparator {
          visible: root.verdicts.length > 0
          foreground: root.fg
        }

        Column {
          visible: root.verdicts.length > 0
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "RECENT VERDICTS"
            foreground: root.fg
            fontFamily: root.face
          }

          Repeater {
            model: root.verdicts
            Rectangle {
              id: verdictRow
              required property var modelData
              required property int index

              readonly property bool hot: mouse.containsMouse || (root.cursorActive && root.cursorIndex === index)

              width: parent.width
              implicitHeight: verdictBody.implicitHeight + Style.space(10)
              radius: Style.cornerRadius
              color: hot ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08) : "transparent"

              MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: { root.cursorActive = true; root.cursorIndex = verdictRow.index }
                onClicked: root.openCall(verdictRow.modelData)
              }

              Item {
                id: verdictBody
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(5)
                anchors.rightMargin: Style.space(5)
                anchors.verticalCenter: parent.verticalCenter
                implicitHeight: Math.max(scoreBadge.implicitHeight, verdictLabels.implicitHeight)

                Rectangle {
                  id: scoreBadge
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  implicitWidth: scoreText.implicitWidth + Style.space(10)
                  implicitHeight: scoreText.implicitHeight + Style.space(4)
                  radius: Style.cornerRadius
                  color: Qt.rgba(root.severityColor(Model.severity(modelData)).r,
                                 root.severityColor(Model.severity(modelData)).g,
                                 root.severityColor(Model.severity(modelData)).b, 0.18)

                  Text {
                    id: scoreText
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: Model.probability(verdictRow.modelData) + "%"
                    color: root.severityColor(Model.severity(verdictRow.modelData))
                    font.family: root.face
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                Column {
                  id: verdictLabels
                  anchors.left: scoreBadge.right
                  anchors.leftMargin: Style.space(10)
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: Model.verdictTitle(verdictRow.modelData)
                    color: root.fg
                    font.family: root.face
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: Model.callRoute(verdictRow.modelData, root.maskNumbers)
                      + "  ·  " + Model.relativeTime(verdictRow.modelData.started_at, root.nowMs)
                      + (Model.recommendation(verdictRow.modelData)
                         ? "  ·  " + Model.recommendation(verdictRow.modelData).toUpperCase() : "")
                    color: root.dim
                    font.family: root.face
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }
            }
          }
        }

        // ---------- Actions ----------
        PanelSeparator { foreground: root.fg }

        Row {
          id: actionRow
          width: parent.width
          spacing: Style.space(6)

          readonly property real cellWidth: (width - spacing) / 2

          Button {
            width: actionRow.cellWidth
            iconText: "󰡦"
            iconSize: Style.font.title
            text: "Dashboard"
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.face
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            bordered: true
            onClicked: root.openDashboard()
          }

          Button {
            width: actionRow.cellWidth
            iconText: "󰑐"
            iconSize: Style.font.title
            iconSpinning: fetchProc.running
            text: "Refresh"
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.face
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            bordered: true
            onClicked: root.refresh()
          }
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item {
      width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2)
      height: 1
    }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.fg
    opacity: 0.6
    font.family: root.face
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.face
    font.pixelSize: Style.font.bodySmall
  }
}
