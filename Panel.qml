import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "rdorrell.weather-hud"
  ipcTarget: "rdorrell.weather-hud"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    configFile.reload()
    root.refresh()
  }

  function openFromHotkey() {
    root.controller.show()
    configFile.reload()
    root.refresh()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Config, read from rdorrell.weather-hud.json (owned by
  //      bin/rdorrell.weather-hud-config). The watch makes hand edits and
  //      our own helper-script writes take effect live.
  property var config: Model.parseConfigFile("")
  readonly property bool configured: Model.isConfigured(config)

  property FileView configFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/rdorrell.weather-hud.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.configHandled(Model.parseConfigFile(text()))
    onLoadFailed: root.configHandled(Model.parseConfigFile(""))
  }

  function configHandled(parsed) {
    var wasConfigured = root.configured
    root.config = parsed
    if (root.savingConfig) root.finishSavingConfig()
    // First load with nothing set yet (fresh install) opens straight into
    // the setup form instead of a silent "Fetching…" that never resolves.
    if (!wasConfigured && !Model.isConfigured(parsed) && !root.editingConfig && !root.hasEverLoaded)
      root.startEditing()
    root.hasEverLoaded = true
    if (Model.isConfigured(parsed)) Qt.callLater(root.refresh)
  }

  property bool hasEverLoaded: false
  readonly property string helperScript: Model.localPathFromUrl(Qt.resolvedUrl("bin/rdorrell.weather-hud-config"))

  // ---- Setup / device-picker state.
  property bool editingConfig: false
  property bool savingConfig: false
  property bool deviceListLoading: false
  property string deviceListError: ""
  property var devices: []

  function startEditing() {
    editingConfig = true
    deviceListError = ""
    devices = []
    Qt.callLater(function() {
      apiKeyField.text = ""
      appKeyField.text = ""
      apiKeyField.forceActiveFocus()
    })
  }

  function cancelEditing() {
    if (!root.configured) return  // nothing to fall back to — stay in setup
    editingConfig = false
    deviceListError = ""
    devices = []
  }

  // Blank field = keep the currently-saved key (lets "change device" work
  // without forcing the user to re-paste both keys every time).
  function effectiveApiKey() {
    var typed = apiKeyField.text.trim()
    return typed !== "" ? typed : root.config.apiKey
  }

  function effectiveApplicationKey() {
    var typed = appKeyField.text.trim()
    return typed !== "" ? typed : root.config.applicationKey
  }

  function fetchDevices() {
    var apiKey = effectiveApiKey()
    var appKey = effectiveApplicationKey()
    if (!apiKey || !appKey) {
      deviceListError = "Enter both your API key and application key."
      return
    }
    deviceListError = ""
    devices = []
    deviceListLoading = true
    deviceListProc.collected = ""
    deviceListProc.command = ["curl", "-fsS", "--max-time", "8",
      "https://api.ambientweather.net/v1/devices?applicationKey=" + encodeURIComponent(appKey)
      + "&apiKey=" + encodeURIComponent(apiKey)]
    deviceListProc.running = true
  }

  function pickDevice(device) {
    if (!device) return
    savingConfig = true
    configSaveProc.command = [root.helperScript, "--set-credentials", root.effectiveApiKey(), root.effectiveApplicationKey()]
    configSaveProc.nextCommand = [root.helperScript, "--set-device", device.macAddress, device.name]
    configSaveProc.running = true
  }

  function finishSavingConfig() {
    savingConfig = false
    editingConfig = false
    deviceListError = ""
    devices = []
  }

  function changeConfig() {
    startEditing()
  }

  Process {
    id: deviceListProc
    property string collected: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: deviceListProc.collected = text
    }
    onExited: function(exitCode) {
      root.deviceListLoading = false
      if (exitCode !== 0 || !deviceListProc.collected) {
        root.deviceListError = "Couldn't reach Ambient Weather — check your keys and connection."
        root.devices = []
        return
      }
      var parsed = Model.parseDeviceList(deviceListProc.collected)
      root.devices = parsed
      root.deviceListError = parsed.length === 0 ? "No devices found on this account." : ""
    }
  }

  // Two-step save (credentials, then device) run back to back so a single
  // "pick a device" click persists both without the panel needing to know
  // whether the keys actually changed.
  Process {
    id: configSaveProc
    property var nextCommand: null
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.savingConfig = false
        root.deviceListError = "Couldn't save settings."
        return
      }
      if (configSaveProc.nextCommand) {
        var next = configSaveProc.nextCommand
        configSaveProc.nextCommand = null
        configSaveProc.command = next
        configSaveProc.running = true
        return
      }
      configFile.reload()
    }
  }

  // ---- Live reading.
  property var reading: null
  property int refreshRetries: 0
  property bool refreshing: false

  // Reading nearest 24h before the current one — "yesterday, same time" —
  // used only for the trend arrow, so a failed/slow fetch just leaves the
  // comparison blank rather than blocking the live view.
  property var yesterdayReading: null
  property int yesterdayRetries: 0

  readonly property int refreshMinutes: Math.max(1, parseInt(setting("refreshMinutes", 5), 10) || 5)

  readonly property var currentTempF: Model.currentTempF(reading)
  readonly property var currentFeelsLikeF: Model.currentFeelsLikeF(reading)
  readonly property var currentHumidity: Model.currentHumidity(reading)
  readonly property var currentWindMph: Model.currentWindMph(reading)
  readonly property var currentWindGustMph: Model.currentWindGustMph(reading)
  readonly property var currentDailyRainIn: Model.currentDailyRainIn(reading)
  readonly property var currentMaxDailyGustMph: Model.currentMaxDailyGustMph(reading)
  readonly property var yesterdayTempF: Model.currentTempF(yesterdayReading)

  readonly property string label: !configured
    ? "🌡 setup"
    : Model.conditionIcon(currentTempF, currentDailyRainIn, currentWindGustMph) + " " + Model.formatTemp(currentTempF)

  // Freezing, extreme heat, or a high gust — drives the bar pill's urgent
  // flash and the hero temp's color in the popup.
  readonly property bool alertCondition: configured && Model.isAlertCondition(currentTempF, currentWindGustMph)

  readonly property string tooltipText: !configured
    ? "Ambient Weather HUD — click to set up"
    : (config.deviceName || "Ambient Weather")
      + (reading ? " · feels like " + Model.formatTemp(currentFeelsLikeF) : "")

  function refresh() {
    if (!root.configured) return
    refreshRetries = 0
    yesterdayRetries = 0
    if (!readingProc.running) startReadingFetch()
    if (!yesterdayProc.running) startYesterdayFetch()
  }

  function startReadingFetch() {
    refreshing = true
    readingProc.collected = ""
    readingProc.command = ["curl", "-fsS", "--max-time", "8",
      "https://api.ambientweather.net/v1/devices/" + encodeURIComponent(config.macAddress)
      + "?applicationKey=" + encodeURIComponent(config.applicationKey)
      + "&apiKey=" + encodeURIComponent(config.apiKey)
      + "&limit=1"]
    readingProc.running = true
  }

  function scheduleRefreshRetry() {
    if (refreshRetries >= 3) return
    refreshRetries++
    refreshRetryTimer.restart()
  }

  Timer {
    id: refreshRetryTimer
    interval: 3000
    onTriggered: if (!readingProc.running) root.startReadingFetch()
  }

  Process {
    id: readingProc
    property string collected: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: readingProc.collected = text
    }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode !== 0 || !readingProc.collected) {
        root.scheduleRefreshRetry()
        return
      }
      var parsed = Model.parseReading(readingProc.collected)
      if (!parsed) {
        root.scheduleRefreshRetry()
        return
      }
      root.reading = parsed
      root.refreshRetries = 0
    }
  }

  // "Yesterday" is the closest reading at or before (now - 24h) —
  // approximates same-time-yesterday without needing a date-range fetch.
  function startYesterdayFetch() {
    yesterdayProc.collected = ""
    yesterdayProc.command = ["curl", "-fsS", "--max-time", "8",
      "https://api.ambientweather.net/v1/devices/" + encodeURIComponent(config.macAddress)
      + "?applicationKey=" + encodeURIComponent(config.applicationKey)
      + "&apiKey=" + encodeURIComponent(config.apiKey)
      + "&endDate=" + (Date.now() - 24 * 60 * 60 * 1000)
      + "&limit=1"]
    yesterdayProc.running = true
  }

  function scheduleYesterdayRetry() {
    if (yesterdayRetries >= 2) return
    yesterdayRetries++
    yesterdayRetryTimer.restart()
  }

  Timer {
    id: yesterdayRetryTimer
    interval: 3000
    onTriggered: if (!yesterdayProc.running) root.startYesterdayFetch()
  }

  Process {
    id: yesterdayProc
    property string collected: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: yesterdayProc.collected = text
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 || !yesterdayProc.collected) {
        root.scheduleYesterdayRetry()
        return
      }
      var parsed = Model.parseReading(yesterdayProc.collected)
      if (!parsed) {
        root.scheduleYesterdayRetry()
        return
      }
      root.yesterdayReading = parsed
      root.yesterdayRetries = 0
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000
    running: root.configured
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingConfig
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.space(14)

        // ---- Setup form: shown until credentials + a device are saved,
        //      or whenever the user reopens it via the gear affordance.
        Column {
          visible: root.editingConfig
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            text: "Ambient Weather setup"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Generate an API key and an application key at ambientweather.net → Account → API Keys."
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: apiKeyField
            width: parent.width
            password: true
            enabled: !root.deviceListLoading && !root.savingConfig
            placeholderText: root.config.apiKey ? "API key (leave blank to keep saved key)" : "API key"
            foreground: root.bar.foreground
            font.family: root.bar.fontFamily
            Keys.onReturnPressed: root.fetchDevices()
          }

          TextField {
            id: appKeyField
            width: parent.width
            password: true
            enabled: !root.deviceListLoading && !root.savingConfig
            placeholderText: root.config.applicationKey ? "Application key (leave blank to keep saved key)" : "Application key"
            foreground: root.bar.foreground
            font.family: root.bar.fontFamily
            Keys.onReturnPressed: root.fetchDevices()
          }

          Row {
            spacing: Style.space(8)

            Button {
              text: root.deviceListLoading ? "Finding devices…" : "Find devices"
              enabled: !root.deviceListLoading && !root.savingConfig
              bordered: true
              onClicked: root.fetchDevices()
            }

            Button {
              visible: root.configured
              text: "Cancel"
              bordered: true
              onClicked: root.cancelEditing()
            }
          }

          Text {
            visible: root.deviceListError !== ""
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.deviceListError
            color: Color.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Column {
            visible: root.devices.length > 0 && !root.savingConfig
            width: parent.width
            spacing: 0

            Repeater {
              model: root.devices

              Rectangle {
                required property var modelData
                width: parent.width
                height: deviceRow.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: deviceArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

                Column {
                  id: deviceRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.name
                    color: deviceArea.containsMouse ? Style.hoverStateColor(root.bar.foreground, Color.accent) : root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    visible: modelData.location !== ""
                    text: modelData.location
                    color: Qt.darker(root.bar.foreground, 1.5)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  id: deviceArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.pickDevice(modelData)
                }
              }
            }
          }

          Text {
            visible: root.savingConfig
            textFormat: Text.PlainText
            text: "Saving…"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }
        }

        // ---- Live view: hero temp + stat row, once a device is configured.
        Column {
          visible: !root.editingConfig && root.configured
          width: parent.width
          spacing: Style.space(14)

          Item {
            width: parent.width
            height: Math.max(heroLeft.height, heroRight.height)

            Row {
              id: heroLeft
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(16)

              Text {
                id: heroIcon
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: root.reading ? Model.conditionIcon(root.currentTempF, root.currentDailyRainIn, root.currentWindGustMph) : "—"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                // Decorative condition glyph; intentionally larger than the
                // Style.font.* scale's displayLarge (28).
                font.pixelSize: 64
              }

              Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Text {
                  id: tempBig
                  textFormat: Text.PlainText
                  text: root.reading ? Model.formatBareTemp(root.currentTempF) : "—"
                  // Same urgent tone as the bar pill's flash, so the two read
                  // as one signal rather than two independent color choices.
                  color: root.alertCondition ? root.bar.urgent : root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: 56
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.reading ? "°F" : ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.display
                  anchors.top: tempBig.top
                  anchors.topMargin: Style.space(10)
                }
              }
            }

            Column {
              id: heroRight
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Rectangle {
                id: stationPill
                anchors.right: parent.right
                width: stationRow.implicitWidth + Style.space(16)
                height: stationRow.implicitHeight + Style.space(8)
                radius: Style.cornerRadius
                color: stationHover.hovered ? Style.hoverFillFor(root.bar.foreground, Color.accent) : "transparent"

                TapHandler { onTapped: root.changeConfig() }
                HoverHandler { id: stationHover; cursorShape: Qt.PointingHandCursor }

                Row {
                  id: stationRow
                  anchors.centerIn: parent
                  spacing: Style.space(6)

                  Text {
                    textFormat: Text.PlainText
                    text: (root.config.deviceName || "Station").toUpperCase()
                    color: stationHover.hovered ? Style.hoverStateColor(root.bar.foreground, Color.accent) : Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    font.letterSpacing: 1
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: "⚙"
                    color: stationHover.hovered ? Style.hoverStateColor(root.bar.foreground, Color.accent) : Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }
              }

              Row {
                anchors.right: parent.right
                visible: root.refreshing
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰦖"
                  color: Qt.darker(root.bar.foreground, 1.6)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption

                  RotationAnimator on rotation {
                    running: root.refreshing
                    from: 0; to: 360
                    duration: 800
                    loops: Animation.Infinite
                  }
                }
                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Updating…"
                  color: Qt.darker(root.bar.foreground, 1.6)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.italic: true
                }
              }
            }
          }

          Text {
            visible: !root.reading
            textFormat: Text.PlainText
            text: "Fetching reading…"
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          PanelSeparator {
            visible: !!root.reading
            foreground: root.bar.foreground
          }

          Grid {
            visible: !!root.reading
            width: parent.width
            columns: 2
            columnSpacing: Style.space(28)
            rowSpacing: Style.space(16)

            Column {
              spacing: Style.space(5)
              Text {
                text: "FEELS LIKE"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                text: Model.formatTemp(root.currentFeelsLikeF)
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            Column {
              spacing: Style.space(5)
              Text {
                text: "HUMIDITY"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                text: Model.formatPercent(root.currentHumidity)
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            Column {
              spacing: Style.space(5)
              Text {
                text: "WIND"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                text: Model.formatWind(root.currentWindMph, root.currentWindGustMph)
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            Column {
              spacing: Style.space(5)
              Text {
                text: "DAILY RAIN"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                text: Model.formatRain(root.currentDailyRainIn)
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            Column {
              spacing: Style.space(5)
              Text {
                text: "MAX WIND TODAY"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                text: Model.formatWind(root.currentMaxDailyGustMph)
                // Same urgent tone as the hero temp and bar pill, so a
                // notable gust reads as the same signal everywhere.
                color: Model.isHighGust(root.currentMaxDailyGustMph) ? root.bar.urgent : root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            Column {
              spacing: Style.space(5)
              Text {
                text: "VS YESTERDAY"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              BorderSurface {
                id: trendPill
                readonly property string trendDirection: Model.yesterdayTrendDirection(root.currentTempF, root.yesterdayTempF)
                readonly property color trendColor: trendDirection === "up" ? Color.accent
                  : trendDirection === "down" ? Color.muted
                  : Qt.darker(root.bar.foreground, 1.5)

                color: "transparent"
                borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)
                radius: Style.cornerRadius
                implicitWidth: trendRow.implicitWidth + Style.space(12)
                implicitHeight: trendRow.implicitHeight + Style.space(6)

                Row {
                  id: trendRow
                  anchors.centerIn: parent
                  spacing: Style.space(5)

                  Text {
                    textFormat: Text.PlainText
                    text: Model.formatTemp(root.yesterdayTempF)
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.title
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: Model.yesterdayTrendArrow(trendPill.trendDirection)
                    color: trendPill.trendColor
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.title
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
