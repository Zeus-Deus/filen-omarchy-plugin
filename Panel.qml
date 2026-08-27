import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar widget + popup for the Filen end-to-end encrypted drive. The bar shows
// the Filen mark with a transfer count; the panel is a keyboard-driven file
// browser modelled on the first-party tailscale/network panels.
Panel {
  id: root
  moduleName: "io.github.zeus-deus.filen"
  ipcTarget: "filen"
  manageIpc: false

  // ── cursor model: one highlight at a time, keyboard and mouse share it ──
  property string focusSection: "header"     // header | entries | transfers
  property int entryIndex: 0
  property int transferIndex: 0
  property bool cursorActive: false

  // ── view state ─────────────────────────────────────────────────────────
  property string view: "browse"             // browse | transfers
  property string filterQuery: ""
  property bool filterActive: false
  property var pendingDelete: null
  property bool newFolderOpen: false

  readonly property bool overlayOpen: pendingDelete !== null
  readonly property bool editorOpen: filterActive || newFolderOpen

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)

  readonly property bool ready: filen.cliInstalled && filen.signedIn
  readonly property bool attention: filen.needsSetup || filen.needsLogin
    || filen.listError !== "" || filen.transferStats.failed > 0
  readonly property bool headerHasCursor: cursorActive && focusSection === "header"

  readonly property var visibleEntries: Model.filterEntries(filen.entries, filterQuery)
  readonly property int runningTransfers: filen.transferStats.running
  readonly property string countText: runningTransfers > 0 ? String(runningTransfers) : ""

  readonly property string heroMeta: {
    if (filen.needsSetup) return "Filen CLI not installed"
    if (!filen.cliChecked) return "Looking for the Filen CLI\u2026"
    if (filen.needsLogin) return "Not signed in"
    if (filen.listError !== "") return filen.listError
    if (view === "transfers") {
      var s = filen.transferStats
      return s.running > 0 ? s.running + " active \u00b7 " + s.total + " recent"
                           : (s.total > 0 ? s.total + " recent transfers" : "No transfers yet")
    }
    if (!filen.quotaLoaded) return "Loading drive\u2026"
    return Model.formatSize(filen.usedBytes) + " of " + Model.formatSize(filen.totalBytes) + " used"
  }

  // ── cursor helpers ─────────────────────────────────────────────────────

  function currentList() {
    return view === "transfers" ? filen.transfers : visibleEntries
  }

  function selectedEntry() {
    if (view !== "browse" || focusSection !== "entries") return null
    var list = visibleEntries
    if (list.length === 0) return null
    return list[Math.max(0, Math.min(entryIndex, list.length - 1))] || null
  }

  function selectedTransfer() {
    if (view !== "transfers" || focusSection !== "transfers") return null
    var list = filen.transfers
    if (list.length === 0) return null
    return list[Math.max(0, Math.min(transferIndex, list.length - 1))] || null
  }

  function ensureCursor() {
    var list = currentList()
    if (view === "browse") {
      if (entryIndex >= list.length) entryIndex = Math.max(0, list.length - 1)
      if (focusSection === "entries" && list.length === 0) focusSection = "header"
      if (focusSection === "transfers") focusSection = "header"
    } else {
      if (transferIndex >= list.length) transferIndex = Math.max(0, list.length - 1)
      if (focusSection === "transfers" && list.length === 0) focusSection = "header"
      if (focusSection === "entries") focusSection = "header"
    }
  }

  function bodySection() { return view === "transfers" ? "transfers" : "entries" }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()

    // Horizontal: left goes up a directory, right enters one.
    if (dy === 0 && dx !== 0 && view === "browse") {
      if (dx < 0) { goUp(); return }
      var e = selectedEntry()
      if (e && e.dir) enterSelected()
      return
    }
    if (dy === 0) return

    var list = currentList()
    var body = bodySection()
    if (focusSection === "header") {
      if (dy > 0 && list.length > 0) {
        focusSection = body
        if (body === "entries") entryIndex = 0; else transferIndex = 0
      }
    } else {
      var idx = body === "entries" ? entryIndex : transferIndex
      if (dy < 0) {
        if (idx <= 0) focusSection = "header"
        else idx--
      } else if (idx < list.length - 1) {
        idx++
      }
      if (body === "entries") entryIndex = idx; else transferIndex = idx
    }
    ensureCursor()
    syncDetail()
    scrollCursorIntoView()
  }

  // Enter: directories open, files download-and-open when previewable,
  // otherwise plain download.
  function activateCursor() {
    ensureCursor()
    if (focusSection === "header") { filen.refresh(); return }
    if (view === "transfers") {
      var t = selectedTransfer()
      if (t && t.state === "done" && t.kind === "download") filen.openLocal(t.localPath)
      return
    }
    var e = selectedEntry()
    if (!e) return
    if (e.dir) enterSelected()
    else filen.download(e, Model.isPreviewable(e))
  }

  function enterSelected() {
    var e = selectedEntry()
    if (!e || !e.dir) return
    filen.enterDirectory(e)
    entryIndex = 0
    focusSection = "entries"
    clearFilter()
  }

  function goUp() {
    if (filen.atRoot) return
    filen.goUp()
    entryIndex = 0
    focusSection = "entries"
    clearFilter()
  }

  function downloadSelected(andOpen) {
    var e = selectedEntry()
    if (e && !e.dir) filen.download(e, andOpen === true)
  }

  function requestDeleteSelected() {
    var e = selectedEntry()
    if (!e) return
    if (!filen.confirmDelete) { filen.removeEntry(e); return }
    newFolderOpen = false
    pendingDelete = e
    confirm.selectedIndex = 0     // default to Cancel — x then Enter must not delete
    Qt.callLater(function() { confirmKeys.forceActiveFocus() })
  }

  function closeConfirm() {
    pendingDelete = null
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function syncDetail() {
    if (view !== "browse") return
    var e = selectedEntry()
    if (e && !e.dir) filen.loadDetail(e)
    else { filen.detailPath = ""; filen.detailData = null }
  }

  function setRowCursor(section, index) {
    if (overlayOpen) return
    cursorActive = true
    focusSection = section
    if (section === "entries") entryIndex = index
    else if (section === "transfers") transferIndex = index
    syncDetail()
  }

  function setHeaderCursor() {
    if (overlayOpen) return
    cursorActive = true
    focusSection = "header"
  }

  function startFilter() {
    if (view !== "browse") return
    filterActive = true
    Qt.callLater(function() { filterField.forceActiveFocus() })
  }

  function clearFilter() {
    filterQuery = ""
    filterActive = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function startNewFolder() {
    if (!ready || view !== "browse") return
    newFolderOpen = true
    Qt.callLater(function() { newFolderField.forceActiveFocus() })
  }

  function cancelNewFolder() {
    newFolderOpen = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function toggleView() {
    view = view === "browse" ? "transfers" : "browse"
    focusSection = "header"
    cursorActive = false
    clearFilter()
    if (panelFlick) panelFlick.contentY = 0
  }

  function dismiss() {
    if (overlayOpen) { closeConfirm(); return }
    if (newFolderOpen) { cancelNewFolder(); return }
    if (filterActive || filterQuery !== "") { clearFilter(); return }
    if (view === "transfers") { toggleView(); return }
    close()
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (focusSection === "header") { if (panelFlick) panelFlick.contentY = 0; return }
    var column = view === "transfers" ? transferColumn : entryColumn
    var index = view === "transfers" ? transferIndex : entryIndex
    if (column && index >= 0 && index < column.children.length) scrollItemIntoView(column.children[index])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      focusSection = "header"
      if (panelFlick) panelFlick.contentY = 0
      filen.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      pendingDelete = null
      newFolderOpen = false
      filterActive = false
    }
  }

  Service {
    id: filen
    settings: root.settings
    onEntriesUpdated: {
      root.ensureCursor()
      // A row can vanish under an open dialog (refresh, deletion elsewhere);
      // an orphaned overlay would swallow every keystroke.
      if (root.pendingDelete) {
        var still = false
        for (var i = 0; i < filen.entries.length; i++)
          if (filen.entries[i].name === root.pendingDelete.name) { still = true; break }
        if (!still) root.closeConfirm()
      }
      root.syncDetail()
    }
    onNavigated: function(path) { root.entryIndex = 0 }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { filen.refresh(); return "ok" }
    function status(): string {
      return JSON.stringify({
        cliInstalled: filen.cliInstalled,
        cliVersion: filen.cliVersion,
        signedIn: filen.signedIn,
        path: filen.currentPath,
        entries: filen.entries.length,
        quotaLoaded: filen.quotaLoaded,
        usedBytes: filen.usedBytes,
        totalBytes: filen.totalBytes,
        transfers: filen.transferStats,
        listError: filen.listError,
        view: root.view
      })
    }
  }

  TextMetrics {
    id: countMetrics
    text: root.countText
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
  }

  // ── bar button ─────────────────────────────────────────────────────────

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.heroMeta
    slotSize: Style.bar.iconSlot + (root.countText !== "" ? countMetrics.width + Style.space(3) : 0)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) filen.refresh()
      else root.toggle()
    }
    iconComponent: Component {
      Item {
        Row {
          anchors.centerIn: parent
          spacing: Style.space(3)

          FilenIcon {
            anchors.verticalCenter: parent.verticalCenter
            iconSize: Style.bar.iconCanvas
            color: root.ready || root.attention
              ? root.barForeground
              : Qt.darker(root.barForeground, 1.55)
            badgeColor: root.urgent
            warning: root.attention
          }

          Text {
            visible: root.countText !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: root.countText
            color: root.barForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            renderType: Text.NativeRendering
          }
        }
      }
    }
  }

  // ── panel ──────────────────────────────────────────────────────────────

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editorOpen || root.overlayOpen
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; if (dy >= 0 && dx === 0) return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.dismiss()
      onDeleteRequested: if (root.cursorActive && root.ready) root.requestDeleteSelected()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = t.toLowerCase()
        if (k === "r") filen.refresh()
        else if (k === "/") root.startFilter()
        else if (k === "u") root.goUp()
        else if (k === "d") root.downloadSelected(false)
        else if (k === "o") root.downloadSelected(true)
        else if (k === "n") root.startNewFolder()
        else if (k === "t") root.toggleView()
        else if (k === "w") filen.openWebDrive()
        else if (k === "c" && root.view === "transfers") filen.clearFinishedTransfers()
        else if (k === "y") {
          var e = root.selectedEntry()
          if (e) filen.copyText(Model.joinPath(filen.currentPath, e.name) || "")
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ── hero ───────────────────────────────────────────────────────
          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() { root.setHeaderCursor() }

            PanelHero {
              id: hero
              width: parent.width
              title: root.view === "transfers" ? "Filen transfers" : "Filen"
              meta: root.heroMeta
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: root.ready || root.attention ? 1.0 : 0.5
              iconComponent: Component {
                FilenIcon {
                  iconSize: Style.font.display
                  color: root.foreground
                  badgeColor: root.urgent
                  warning: root.attention
                }
              }
              trailingControl: Component {
                Row {
                  spacing: Style.space(2)

                  PanelActionButton {
                    iconText: root.view === "transfers" ? "\udb80\udcaf" : "\udb81\udf6c"
                    tooltipText: root.view === "transfers" ? "Back to files (t)" : "Transfers (t)"
                    foreground: hero.foreground
                    fontFamily: hero.fontFamily
                    hasCursor: header.ringVisible
                    onHovered: function(on) { if (on) header.focusHero() }
                    onClicked: root.toggleView()
                  }

                  PanelActionButton {
                    id: refreshButton
                    iconText: "\udb81\udc50"
                    tooltipText: "Refresh (r)"
                    foreground: hero.foreground
                    fontFamily: hero.fontFamily
                    hasCursor: false
                    enabled: !filen.busy && filen.cliInstalled
                    onClicked: filen.refresh()

                    NumberAnimation on rotation {
                      running: filen.busy
                      from: 0; to: 360; duration: 900
                      loops: Animation.Infinite
                    }
                    onRotationChanged: if (!filen.busy && rotation !== 0) rotation = 0
                  }
                }
              }
            }
          }

          // ── transient status line ──────────────────────────────────────
          Text {
            visible: filen.actionStatus !== "" || filen.actionError !== ""
            width: parent.width
            text: filen.actionError !== "" ? filen.actionError : filen.actionStatus
            textFormat: Text.PlainText
            color: filen.actionError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          // ── setup: CLI missing ─────────────────────────────────────────
          CursorSurface {
            visible: filen.needsSetup
            width: parent.width
            implicitHeight: setupInner.implicitHeight + Style.spacing.rowPaddingX * 2
            foreground: root.foreground

            Column {
              id: setupInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              spacing: Style.space(6)

              Text {
                width: parent.width
                text: "The Filen CLI is not installed"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
              Text {
                width: parent.width
                text: "This plugin drives the official Filen CLI. Nothing is bundled and nothing is installed for you \u2014 review the instructions and install it yourself, then press Refresh."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              Row {
                spacing: Style.space(6)
                Button {
                  text: "Installation docs"
                  iconText: "\udb80\udf9f"
                  foreground: root.foreground
                  onClicked: filen.openInstallDocs()
                }
                Button {
                  text: "Recheck"
                  iconText: "\udb81\udc50"
                  foreground: root.foreground
                  onClicked: { filen.cliChecked = false; filen.start() }
                }
              }
            }
          }

          // ── setup: signed out ──────────────────────────────────────────
          CursorSurface {
            visible: filen.needsLogin
            width: parent.width
            implicitHeight: loginInner.implicitHeight + Style.spacing.rowPaddingX * 2
            foreground: root.foreground

            Column {
              id: loginInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              spacing: Style.space(6)

              Text {
                width: parent.width
                text: "Not signed in to Filen"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
              Text {
                width: parent.width
                text: "Filen is end-to-end encrypted, so this panel never handles your password. Sign in through the CLI's own prompt in a terminal \u2014 it stores the session in your system keyring."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              Button {
                text: "Sign in with the Filen CLI"
                iconText: "\udb80\udd0d"
                foreground: root.foreground
                onClicked: filen.openLoginTerminal()
              }
            }
          }

          // ── quota meter ────────────────────────────────────────────────
          Column {
            visible: root.ready && filen.quotaLoaded && root.view === "browse"
            width: parent.width
            spacing: Style.space(5)

            Item {
              width: parent.width
              implicitHeight: quotaLabel.implicitHeight

              Text {
                id: quotaLabel
                anchors.left: parent.left
                text: "Drive"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                anchors.right: parent.right
                text: Model.formatSize(filen.usedBytes) + " / " + Model.formatSize(filen.totalBytes)
                color: filen.quotaHigh ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Rectangle {
              width: parent.width
              height: Math.max(2, Style.space(3))
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

              Rectangle {
                width: parent.width * filen.quotaFraction
                height: parent.height
                color: filen.quotaHigh ? root.urgent : Color.accent
                Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
              }
            }
          }

          PanelSeparator {
            visible: root.ready
            foreground: root.foreground
          }

          // ── breadcrumb ─────────────────────────────────────────────────
          Flow {
            visible: root.ready && root.view === "browse"
            width: parent.width
            spacing: Style.space(3)

            Repeater {
              model: Model.crumbs(filen.currentPath)
              delegate: Row {
                required property var modelData
                required property int index
                spacing: Style.space(3)

                Text {
                  visible: index > 0
                  anchors.verticalCenter: parent.verticalCenter
                  text: "\u203a"
                  color: Qt.darker(root.foreground, 2.2)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.label
                  textFormat: Text.PlainText
                  color: modelData.path === filen.currentPath ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideMiddle

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: filen.goTo(modelData.path)
                  }
                }
              }
            }
          }

          // ── filter field ───────────────────────────────────────────────
          TextField {
            id: filterField
            visible: root.filterActive && root.view === "browse"
            width: parent.width
            placeholderText: "Filter this folder\u2026"
            foreground: root.foreground
            text: root.filterQuery
            onTextChanged: { root.filterQuery = text; root.entryIndex = 0 }
            Keys.onEscapePressed: root.clearFilter()
            Keys.onReturnPressed: {
              root.filterActive = false
              root.focusSection = "entries"
              root.cursorActive = true
              Qt.callLater(function() { keyCatcher.forceActiveFocus() })
            }
          }

          // ── new folder field ───────────────────────────────────────────
          Row {
            visible: root.newFolderOpen
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: newFolderField
              width: parent.width - createButton.width - Style.space(6)
              placeholderText: "New folder name"
              foreground: root.foreground
              Keys.onEscapePressed: root.cancelNewFolder()
              Keys.onReturnPressed: {
                filen.makeDirectory(text)
                text = ""
                root.cancelNewFolder()
              }
            }
            Button {
              id: createButton
              text: "Create"
              foreground: root.foreground
              onClicked: {
                filen.makeDirectory(newFolderField.text)
                newFolderField.text = ""
                root.cancelNewFolder()
              }
            }
          }

          // ── file list ──────────────────────────────────────────────────
          Column {
            visible: root.ready && root.view === "browse"
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: root.filterQuery !== ""
                ? "MATCHES (" + root.visibleEntries.length + ")"
                : (filen.atRoot ? "DRIVE" : Model.basename(filen.currentPath).toUpperCase())
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: filen.listLoaded && root.visibleEntries.length === 0 && filen.listError === ""
              width: parent.width
              text: root.filterQuery !== "" ? "Nothing matches that filter." : "This folder is empty."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              visible: filen.listError !== ""
              width: parent.width
              text: filen.listError
              textFormat: Text.PlainText
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: entryColumn
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                model: root.visibleEntries
                delegate: CursorSurface {
                  id: entryRow
                  required property var modelData
                  required property int index

                  width: entryColumn.width
                  implicitHeight: Style.spacing.popupRowHeight
                  foreground: root.foreground
                  hasCursor: root.cursorActive && root.focusSection === "entries" && root.entryIndex === index

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.setRowCursor("entries", index)
                    onClicked: function(mouse) {
                      root.setRowCursor("entries", index)
                      if (mouse.button === Qt.RightButton) { root.requestDeleteSelected(); return }
                      if (modelData.dir) root.enterSelected()
                      else filen.download(modelData, Model.isPreviewable(modelData))
                    }
                  }

                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(6)
                    spacing: Style.space(8)

                    Text {
                      text: Model.iconFor(modelData)
                      color: modelData.dir ? Color.accent : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.icon
                      Layout.preferredWidth: Style.space(16)
                    }

                    Text {
                      text: modelData.display
                      textFormat: Text.PlainText
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideMiddle
                      Layout.fillWidth: true
                    }

                    // Size for the focused file only — a per-row stat would
                    // be one CLI process per entry.
                    Text {
                      visible: entryRow.hasCursor && filen.detailData && filen.detailData.type === "file"
                      text: filen.detailData ? Model.formatSize(filen.detailData.size) : ""
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      visible: modelData.dir
                      text: "\u203a"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    Row {
                      visible: entryRow.hasCursor && !modelData.dir
                      spacing: Style.space(1)

                      PanelActionButton {
                        iconText: "\udb81\udc1a"
                        tooltipText: "Download (d)"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        size: Style.space(20)
                        fontSize: Style.font.bodySmall
                        onClicked: filen.download(modelData, false)
                      }
                      PanelActionButton {
                        visible: Model.isPreviewable(modelData)
                        iconText: "\udb80\udd0f"
                        tooltipText: "Open (o)"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        size: Style.space(20)
                        fontSize: Style.font.bodySmall
                        onClicked: filen.download(modelData, true)
                      }
                    }
                  }
                }
              }
            }
          }

          // ── transfers view ─────────────────────────────────────────────
          Column {
            visible: root.ready && root.view === "transfers"
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "TRANSFERS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: filen.transfers.length === 0
              width: parent.width
              text: "No transfers yet. Press Enter on a file to download it."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: transferColumn
              width: parent.width
              spacing: Style.space(2)

              Repeater {
                model: filen.transfers
                delegate: CursorSurface {
                  id: transferRow
                  required property var modelData
                  required property int index

                  width: transferColumn.width
                  implicitHeight: Style.spacing.popupRowHeight
                  foreground: root.foreground
                  hasCursor: root.cursorActive && root.focusSection === "transfers" && root.transferIndex === index

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.setRowCursor("transfers", index)
                    onClicked: {
                      root.setRowCursor("transfers", index)
                      if (modelData.state === "done" && modelData.kind === "download")
                        filen.openLocal(modelData.localPath)
                    }
                  }

                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(6)
                    spacing: Style.space(8)

                    Text {
                      text: modelData.state === "running"
                              ? (modelData.kind === "download" ? "\udb81\udc1a" : "\udb81\udd52")
                              : modelData.state === "done" ? "\udb80\udd0c"
                              : modelData.state === "canceled" ? "\udb80\udd59" : "\udb80\udd5a"
                      color: modelData.state === "done" ? Color.accent
                           : modelData.state === "failed" ? root.urgent : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.icon
                      Layout.preferredWidth: Style.space(16)

                      NumberAnimation on opacity {
                        running: modelData.state === "running"
                        from: 1.0; to: 0.35; duration: 700
                        loops: Animation.Infinite
                        easing.type: Easing.InOutQuad
                      }
                      onRunningChanged: if (!running) opacity = 1.0
                    }

                    Column {
                      Layout.fillWidth: true
                      spacing: 0

                      Text {
                        width: parent.width
                        text: modelData.label
                        textFormat: Text.PlainText
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        elide: Text.ElideMiddle
                      }
                      Text {
                        width: parent.width
                        text: modelData.state === "failed" ? modelData.error
                            : modelData.state === "running" ? (modelData.kind === "download" ? "Downloading\u2026" : "Uploading\u2026")
                            : modelData.state === "canceled" ? "Canceled"
                            : Model.relativeTime(modelData.startedMs, Date.now())
                        textFormat: Text.PlainText
                        color: modelData.state === "failed" ? root.urgent : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    PanelActionButton {
                      visible: transferRow.hasCursor && modelData.state === "running"
                      iconText: "\udb80\udd56"
                      tooltipText: "Cancel"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      size: Style.space(20)
                      fontSize: Style.font.bodySmall
                      onClicked: filen.cancelTransfer(modelData.id)
                    }
                  }
                }
              }
            }

            Button {
              visible: filen.transfers.length > 0
              text: "Clear finished"
              iconText: "\udb81\udf79"
              foreground: root.foreground
              onClicked: filen.clearFinishedTransfers()
            }
          }

          // ── keyboard hints ─────────────────────────────────────────────
          Text {
            visible: root.ready
            width: parent.width
            text: root.view === "transfers"
              ? "\u21c5 move  \u00b7  enter open  \u00b7  x cancel  \u00b7  c clear  \u00b7  t files"
              : "\u21c5 move  \u00b7  \u2192 enter  \u00b7  \u2190 up  \u00b7  d download  \u00b7  o open  \u00b7  / filter  \u00b7  n new  \u00b7  y copy path  \u00b7  x delete  \u00b7  t transfers"
            color: Qt.darker(root.foreground, 2.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }

    // ── delete confirmation ──────────────────────────────────────────────
    Item {
      anchors.fill: parent
      visible: root.overlayOpen

      FocusScope {
        id: confirmKeys
        anchors.fill: parent
        focus: root.overlayOpen
        Keys.onPressed: function(event) { confirm.handleKey(event) }

        ConfirmDialog {
          id: confirm
          anchors.fill: parent
          opened: root.overlayOpen
          message: root.pendingDelete
            ? "Move \u201c" + root.pendingDelete.display + "\u201d to the Filen trash?"
            : ""
          cancelText: "Cancel"
          confirmText: "Move to trash"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onCanceled: root.closeConfirm()
          onConfirmed: {
            var target = root.pendingDelete
            root.closeConfirm()
            if (target) filen.removeEntry(target)
          }
        }
      }
    }
  }
}
