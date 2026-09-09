import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons

PopupWindow {
  id: root

  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property bool open: false
  property bool dockerReady: false
  property bool imageReady: false
  property string release: ""
  property var containers: []
  property string busyKey: ""
  property string armedKey: ""
  property string errorKey: ""
  property string errorText: ""
  property string errorHint: ""
  property bool pinNew: false

  signal shellRequested(var c)
  signal actionRequested(string action, var c)
  signal removeRequested(var c)
  signal rebuildRequested()
  signal refreshRequested()
  signal pinToggled()

  readonly property var coordinatorKey: owner || root
  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property color bg: Color.popups.background
  readonly property color borderColor: Color.popups.border
  readonly property color accent: Color.accent
  readonly property color muted: Color.muted
  readonly property color urgent: Color.urgent

  function luminance(c) { return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }
  readonly property color fg: luminance(bg) > 0.6 ? "#1a1a1a" : Color.popups.text
  readonly property color safeMuted: luminance(bg) > 0.6 ? "#5a5a5a" : Color.muted
  readonly property color brand: "#EE0000"
  readonly property string fontFamily: bar ? bar.fontFamily : "monospace"

  readonly property int margin: 10
  readonly property int cardPadding: 12

  implicitWidth: 400
  implicitHeight: Math.min(480, Math.max(140, content.implicitHeight + cardPadding * 2))

  visible: open || card.opacity > 0
  color: "transparent"

  function close() { root.open = false }

  onOpenChanged: {
    if (!bar) return
    if (open) bar.requestPopout(coordinatorKey)
    else if (bar.activePopout === coordinatorKey) bar.releasePopout(coordinatorKey)
  }

  HyprlandFocusGrab {
    active: root.open
    windows: root.anchorWindow ? [root, root.anchorWindow] : [root]
    onCleared: root.close()
  }

  anchor {
    id: popupAnchor
    window: root.anchorWindow
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: Edges.Bottom | Edges.Right
    rect.width: 1
    rect.height: 1

    onAnchoring: {
      if (!root.anchorItem || !root.bar || !root.anchorWindow) return

      var target = root.anchorItem
      var w = root.implicitWidth
      var h = root.implicitHeight
      var localX = target.width / 2 - w / 2
      var localY = target.height + root.margin

      if (root.bar.position === "bottom") {
        localY = -h - root.margin
      } else if (root.bar.position === "left") {
        localX = target.width + root.margin
        localY = target.height / 2 - h / 2
      } else if (root.bar.position === "right") {
        localX = -w - root.margin
        localY = target.height / 2 - h / 2
      }

      var point = root.anchorWindow.contentItem.mapFromItem(target, localX, localY)

      if (root.bar.position === "top" || root.bar.position === "bottom") {
        point.x = Math.max(root.margin, Math.min(point.x, root.anchorWindow.width - w - root.margin))
      } else {
        point.y = Math.max(root.margin, Math.min(point.y, root.anchorWindow.height - h - root.margin))
      }

      popupAnchor.rect.x = Math.round(point.x)
      popupAnchor.rect.y = Math.round(point.y)
    }
  }

  component ActionButton: Rectangle {
    id: btn
    required property string label
    property color tone: root.accent
    property bool busy: false
    signal clicked()

    width: Math.max(40, btnLabel.implicitWidth + 16)
    height: 24
    radius: 6
    color: Qt.rgba(tone.r, tone.g, tone.b, area.containsMouse ? 0.28 : 0.12)
    opacity: enabled ? 1.0 : 0.5

    Text {
      id: btnLabel
      anchors.centerIn: parent
      text: btn.busy ? "…" : btn.label
      color: btn.tone
      font.family: root.fontFamily
      font.pixelSize: 11
      font.bold: true
    }

    MouseArea {
      id: area
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      enabled: !btn.busy
      onClicked: btn.clicked()
    }
  }

  Rectangle {
    id: card
    anchors.fill: parent
    radius: 0
    color: root.bg
    border.color: root.borderColor
    border.width: 2
    opacity: root.open ? 1 : 0

    Behavior on opacity {
      NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
    }

    Column {
      id: content
      anchors.fill: parent
      anchors.margins: root.cardPadding
      spacing: 8

      Row {
        width: parent.width
        height: Math.max(titleCol.implicitHeight, refreshBtn.height)

        Column {
          id: titleCol
          width: parent.width - refreshBtn.width
          anchors.verticalCenter: parent.verticalCenter

          Text {
            text: "RHEL 10"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: 14
            font.bold: true
          }

          Text {
            visible: root.release.length > 0
            text: root.release
            textFormat: Text.PlainText
            color: root.brand
            font.family: root.fontFamily
            font.pixelSize: 10
          }
        }

        Item {
          id: refreshBtn
          width: 22
          height: 22
          anchors.verticalCenter: parent.verticalCenter

          Text {
            anchors.centerIn: parent
            text: "󰹉"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: 13
            opacity: refreshArea.containsMouse ? 1 : 0.6
          }

          MouseArea {
            id: refreshArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.refreshRequested()
          }
        }
      }

      Text {
        visible: !root.dockerReady
        text: "Docker is not reachable. Install it and run:\n"
              + "sudo systemctl enable --now docker"
        textFormat: Text.PlainText
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: 11
        wrapMode: Text.Wrap
        width: parent.width
      }

      Column {
        visible: root.errorKey.length > 0
        width: parent.width
        spacing: 2
        Text {
          width: parent.width
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: "⚠ " + root.errorText
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: 11
          font.bold: true
        }
        Text {
          visible: root.errorHint.length > 0
          width: parent.width
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: "↳ " + root.errorHint
          color: root.safeMuted
          font.family: root.fontFamily
          font.pixelSize: 10
        }
      }

      ActionButton {
        visible: root.dockerReady && !root.imageReady
        label: "Build RHEL image"
        tone: root.brand
        onClicked: root.rebuildRequested()
      }

      Flickable {
        visible: root.dockerReady && root.imageReady
        id: flick
        width: parent.width
        height: Math.min(280, listCol.implicitHeight)
        contentWidth: width
        contentHeight: listCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: listCol
          width: flick.width
          spacing: 6

          Repeater {
            model: root.containers
            delegate: ContainerRow { width: listCol.width }
          }

          Text {
            visible: root.containers.length === 0
            text: "No RHEL containers yet — start one below"
            color: root.safeMuted
            font.family: root.fontFamily
            font.pixelSize: 11
          }
        }
      }

      Row {
        visible: root.dockerReady
        spacing: 8

        ActionButton {
          label: root.pinNew ? "󰐃 Pinned" : "󰐃 Throwaway"
          tone: root.pinNew ? root.brand : root.accent
          onClicked: root.pinToggled()
        }

        ActionButton {
          label: "+ New Shell"
          tone: root.brand
          onClicked: root.shellRequested(null)
        }

        ActionButton {
          label: "Rebuild Image"
          tone: root.accent
          onClicked: root.rebuildRequested()
        }
      }

      Text {
        visible: root.dockerReady
        width: parent.width
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        text: root.pinNew
          ? "Pinned: new containers stay running after you close the terminal (closing just detaches)."
          : "Throwaway: closing the terminal deletes the container."
        color: root.safeMuted
        font.family: root.fontFamily
        font.pixelSize: 9
      }
    }
  }

  component ContainerRow: Rectangle {
    id: rowDelegate
    required property var modelData
    height: 48
    radius: 8
    color: rowHover.hovered ? Style.hoverFillFor(root.fg, root.accent, root.urgent) : "transparent"

    readonly property string rowKey: modelData.name
    readonly property bool running: modelData.state === "running"
    readonly property bool busy: root.busyKey === rowKey
    readonly property bool armed: root.armedKey === rowKey
    readonly property bool errored: root.errorKey === rowKey

    HoverHandler { id: rowHover }

    Row {
      anchors.left: parent.left
      anchors.leftMargin: 8
      anchors.right: btnCol.left
      anchors.rightMargin: 8
      anchors.top: parent.top
      anchors.topMargin: 7
      spacing: 8

      Rectangle {
        width: 6
        height: 6
        radius: 3
        anchors.top: parent.top
        anchors.topMargin: 4
        color: rowDelegate.running ? root.brand : root.safeMuted
      }

      Column {
        spacing: 1
        width: 190

        // Container names and status lines are foreign text; keep PlainText so
        // a crafted name can never render as rich text.
        Text {
          text: modelData.name
          textFormat: Text.PlainText
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: 13
          font.bold: true
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          text: rowDelegate.errored ? root.errorText : modelData.status
          textFormat: Text.PlainText
          color: rowDelegate.errored ? root.urgent : root.safeMuted
          font.family: root.fontFamily
          font.pixelSize: 10
          elide: Text.ElideRight
          width: parent.width
        }
      }
    }

    Row {
      id: btnCol
      anchors.right: parent.right
      anchors.rightMargin: 6
      anchors.verticalCenter: parent.verticalCenter
      spacing: 6

      ActionButton {
        label: "Shell"
        tone: root.brand
        onClicked: root.shellRequested(rowDelegate.modelData)
      }

      ActionButton {
        label: rowDelegate.running ? "Stop" : "Start"
        tone: root.accent
        busy: rowDelegate.busy
        onClicked: root.actionRequested(rowDelegate.running ? "stop" : "start",
                                        rowDelegate.modelData)
      }

      ActionButton {
        label: rowDelegate.armed ? "Confirm" : "Remove"
        tone: root.urgent
        busy: rowDelegate.busy
        onClicked: root.removeRequested(rowDelegate.modelData)
      }
    }
  }
}
