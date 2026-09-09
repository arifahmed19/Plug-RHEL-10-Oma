import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var bar
  property string moduleName
  property var settings

  // Bar.qml forces a vertical widget's slot width to bar.barSize regardless
  // of implicitWidth, so the cross-axis must follow bar.vertical like the
  // built-in widgets do, or content gets clipped.
  readonly property bool vertical: bar ? bar.vertical : false
  implicitWidth: vertical ? (bar ? bar.barSize : 26) : row.implicitWidth + 14
  implicitHeight: vertical ? row.implicitHeight + 10 : (bar ? bar.barSize : 26)

  function luminance(c) { return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }
  readonly property color iconColor: bar
    ? (luminance(bar.background) > 0.6 ? "#1a1a1a" : bar.foreground)
    : "white"
  readonly property color runningColor: "#EE0000"

  readonly property string pluginDir: {
    var p = Qt.resolvedUrl("BarWidget.qml").toString()
    if (p.startsWith("file://")) p = p.slice(7)
    return p.substring(0, p.lastIndexOf("/"))
  }
  readonly property string script: pluginDir + "/rhel.sh"

  function setting(key, fallback) {
    var v = root.settings ? root.settings[key] : undefined
    return (v === undefined || v === null || String(v).length === 0)
      ? fallback : String(v)
  }

  property bool dockerReady: false
  property bool imageReady: false
  property string release: ""
  property var containers: []
  property string busyKey: ""
  property string armedKey: ""
  property string errorKey: ""
  property string errorText: ""
  property string errorHint: ""
  property string backendErr: ""
  property string backendHint: ""
  property bool pinNew: true

  readonly property int runningCount: containers.filter(function(c) { return c.state === "running" }).length

  function close() { popup.open = false }

  function open() {
    popup.open = true
    refresh()
  }

  function toggle() {
    if (popup.open) close()
    else open()
  }

  // The bar's click/drag dispatcher only routes clicks to widgets exposing
  // this function (see WidgetButton).
  function triggerPress(button) { root.toggle() }

  IpcHandler {
    target: "arifahmed19.rhel"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  function clamp(str, n) {
    var v = String(str || "")
    return v.length > n ? v.slice(0, n) + "…" : v
  }

  function parseState(text) {
    var ready = false, image = false, rel = ""
    var rows = []
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length && rows.length < 100; i++) {
      var parts = lines[i].split("<|>")
      if (parts.length < 2) continue
      if (parts[0] === "dockerReady") ready = parts[1] === "1"
      else if (parts[0] === "imageReady") image = parts[1] === "1"
      else if (parts[0] === "release") rel = parts.slice(1).join("<|>")
      else if (parts[0] === "C" && parts.length >= 4) {
        rows.push({
          name: clamp(parts[1], 64),
          state: clamp(parts[2], 24),
          status: clamp(parts.slice(3).join("<|>"), 80)
        })
      }
    }
    root.dockerReady = ready
    root.imageReady = image
    root.release = rel
    root.containers = rows
  }

  function requestAction(action, c) {
    if (actionProc.running) return
    busyKey = c ? c.name : ""
    var args = ["/usr/bin/bash", root.script, action]
    if (c) args.push(c.name)
    actionProc.command = args
    actionProc.running = true
  }

  // Removes are armed first: the first click only marks the row.
  function requestRemove(c) {
    if (armedKey !== c.name) {
      armedKey = c.name
      armTimer.restart()
      return
    }
    armTimer.stop()
    armedKey = ""
    requestAction("rm", c)
  }

  function runInTerminal(sub) {
    if (termProc.running) return
    termProc.command = ["/usr/bin/xdg-terminal-exec", "--app-id=TUI.tile",
                        "-e", root.script, sub]
    termProc.running = true
  }

  // New shell: pass the current Pin preference to rhel.sh via the environment.
  // Pinned (default) => detached container that survives closing the terminal.
  function runNewShell() {
    if (termProc.running) return
    var term = ["/usr/bin/xdg-terminal-exec", "--app-id=TUI.tile",
                "-e", root.script, "run"]
    termProc.command = root.pinNew
      ? ["/usr/bin/env", "RHEL_PIN=1"].concat(term)
      : ["/usr/bin/env", "RHEL_PIN=0"].concat(term)
    termProc.running = true
  }

  function runContainerInTerminal(name) {
    if (termProc.running) return
    var args = ["/usr/bin/xdg-terminal-exec", "--app-id=TUI.tile",
                "-e", root.script, "open"]
    if (name) args.push(name)
    termProc.command = args
    termProc.running = true
  }

  Timer {
    id: stateWatchdog
    interval: 10000
    onTriggered: if (stateProc.running) stateProc.running = false
  }

  Process {
    id: stateProc
    command: ["/usr/bin/env",
              "RHEL_IMAGE=" + setting("imageName", "rhel10-cli"),
              "RHEL_BASE=" + setting("baseImage", "registry.access.redhat.com/ubi10/ubi:latest"),
              "/usr/bin/bash", root.script, "state"]
    onRunningChanged: {
      if (running) stateWatchdog.restart()
      else stateWatchdog.stop()
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseState(text)
    }
  }

  Timer {
    id: actionWatchdog
    interval: 20000
    onTriggered: if (actionProc.running) actionProc.running = false
  }

  Process {
    id: actionProc
    onRunningChanged: {
      if (running) actionWatchdog.restart()
      else actionWatchdog.stop()
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text).split("\n")
          .map(function (l) { return l.trim() })
          .filter(function (l) { return l.length > 0 && l.indexOf("Press any key") < 0 })
        var problem = "", hint = ""
        for (var i = 0; i < lines.length; i++) {
          var l = lines[i]
          if (!problem && l.charAt(0) === "✗") problem = l.slice(1).trim()
          else if (!hint && l.charAt(0) === "↳") hint = l.slice(1).trim()
        }
        root.backendErr = clamp(problem || (lines[lines.length - 1] || ""), 64)
        root.backendHint = clamp(hint, 100)
      }
    }
    onExited: function(exitCode) {
      var key = busyKey
      busyKey = ""
      if (exitCode !== 0) {
        errorKey = key
        errorText = dockerReady
          ? (backendErr.length > 0 ? backendErr : "Action failed")
          : "Docker unreachable"
        errorHint = dockerReady ? backendHint : "Run: sudo systemctl enable --now docker"
        errorTimer.restart()
      }
      backendErr = ""
      backendHint = ""
      refresh()
    }
  }

  // Fire-and-forget terminal launches; xdg-terminal-exec returns instantly.
  Process {
    id: termProc
  }

  Timer {
    id: armTimer
    interval: 3000
    onTriggered: root.armedKey = ""
  }

  Timer {
    id: errorTimer
    interval: 3500
    onTriggered: { root.errorKey = ""; root.errorText = ""; root.errorHint = "" }
  }

  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 4000
    repeat: true
    running: popup.open
    onTriggered: root.refresh()
  }

  Grid {
    id: row
    anchors.centerIn: parent
    columns: root.vertical ? 1 : 2
    rowSpacing: 2
    columnSpacing: 4

    Text {
      text: "󰣠"
      color: root.runningCount > 0 ? root.runningColor : root.iconColor
      font.family: bar ? bar.fontFamily : "monospace"
      font.pixelSize: 15
      horizontalAlignment: Text.AlignHCenter
    }

    Text {
      visible: root.runningCount > 0
      text: String(root.runningCount)
      color: root.runningCount > 0 ? root.runningColor : root.iconColor
      font.family: bar ? bar.fontFamily : "monospace"
      font.pixelSize: 11
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
    }
  }

  RhelPopup {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    dockerReady: root.dockerReady
    imageReady: root.imageReady
    release: root.release
    containers: root.containers
    busyKey: root.busyKey
    armedKey: root.armedKey
    errorKey: root.errorKey
    errorText: root.errorText
    errorHint: root.errorHint
    pinNew: root.pinNew
    onShellRequested: function(c) {
      if (c) root.runContainerInTerminal(c.name)
      else root.runNewShell()
    }
    onPinToggled: root.pinNew = !root.pinNew
    onActionRequested: function(action, c) { root.requestAction(action, c) }
    onRemoveRequested: function(c) { root.requestRemove(c) }
    onRebuildRequested: function() { root.runInTerminal("rebuild") }
    onRefreshRequested: root.refresh()
  }

  Component.onCompleted: refresh()
}
