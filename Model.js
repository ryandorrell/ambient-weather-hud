// Pure helpers for the Ambient Weather HUD plugin. Kept dependency-free so
// they're easy to reason about and (in principle) unit-test outside QML.

// ambient-weather-hud.json shape (owned by bin/ambient-weather-hud-config):
// { apiKey, applicationKey, macAddress, deviceName }. Any missing/blank field
// means "not configured yet".
function parseConfigFile(raw) {
  var unset = { apiKey: "", applicationKey: "", macAddress: "", deviceName: "" }
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return unset
    return {
      apiKey: typeof data.apiKey === "string" ? data.apiKey : "",
      applicationKey: typeof data.applicationKey === "string" ? data.applicationKey : "",
      macAddress: typeof data.macAddress === "string" ? data.macAddress : "",
      deviceName: typeof data.deviceName === "string" ? data.deviceName : ""
    }
  } catch (e) {
    return unset
  }
}

function isConfigured(config) {
  return !!(config && config.apiKey && config.applicationKey && config.macAddress)
}

function hasCredentials(config) {
  return !!(config && config.apiKey && config.applicationKey)
}

// GET /v1/devices response -> picker rows. Each Ambient Weather device
// carries macAddress + info.name/info.location at minimum.
function parseDeviceList(raw) {
  try {
    var data = JSON.parse(String(raw || "[]"))
    if (!Array.isArray(data)) return []

    var out = []
    for (var i = 0; i < data.length; i++) {
      var d = data[i]
      if (!d || !d.macAddress) continue
      var info = d.info || {}
      out.push({
        macAddress: String(d.macAddress),
        name: String(info.name || d.macAddress),
        location: String(info.location || "")
      })
    }
    return out
  } catch (e) {
    return []
  }
}

// GET /v1/devices/{mac}?limit=1 response -> single reading, or null.
function parseReading(raw) {
  try {
    var data = JSON.parse(String(raw || "[]"))
    var reading = Array.isArray(data) ? data[0] : data
    return reading && typeof reading === "object" ? reading : null
  } catch (e) {
    return null
  }
}

// Qt.resolvedUrl("bin/foo") returns a file:// URL; Process needs a plain
// path. Same trick NotificationLogic.js uses for file-backed image values.
function localPathFromUrl(url) {
  var s = String(url || "")
  if (s.indexOf("file://") === 0) {
    s = s.slice(7)
    try { s = decodeURIComponent(s) } catch (e) {}
  }
  return s
}

function numberOrNull(value) {
  if (value === undefined || value === null || value === "") return null
  var n = Number(value)
  return isNaN(n) ? null : n
}

// Outdoor sensor fields, falling back to indoor-only stations.
function currentTempF(reading) {
  if (!reading) return null
  var outdoor = numberOrNull(reading.tempf)
  return outdoor !== null ? outdoor : numberOrNull(reading.tempinf)
}

function currentHumidity(reading) {
  if (!reading) return null
  var outdoor = numberOrNull(reading.humidity)
  return outdoor !== null ? outdoor : numberOrNull(reading.humidityin)
}

// AW computes feels-like server-side (heat index / wind chill already
// applied); fall back to the raw temp if a reading omits it.
function currentFeelsLikeF(reading) {
  if (!reading) return null
  var feelsLike = numberOrNull(reading.feelsLike)
  if (feelsLike !== null) return feelsLike
  var indoorFeelsLike = numberOrNull(reading.feelsLikein)
  if (indoorFeelsLike !== null) return indoorFeelsLike
  return currentTempF(reading)
}

function currentWindMph(reading) {
  if (!reading) return null
  return numberOrNull(reading.windspeedmph)
}

function currentWindGustMph(reading) {
  if (!reading) return null
  return numberOrNull(reading.windgustmph)
}

function currentDailyRainIn(reading) {
  if (!reading) return null
  return numberOrNull(reading.dailyrainin)
}

// Today's peak wind gust, as reported by the station (resets at local
// midnight on the AW side, not something we compute).
function currentMaxDailyGustMph(reading) {
  if (!reading) return null
  return numberOrNull(reading.maxdailygust)
}

function formatTemp(value) {
  if (value === null || value === undefined) return "—"
  return Math.round(value) + "°F"
}

function formatBareTemp(value) {
  if (value === null || value === undefined) return "—"
  return String(Math.round(value))
}

function formatPercent(value) {
  if (value === null || value === undefined) return "—"
  return Math.round(value) + "%"
}

function formatWind(speedMph, gustMph) {
  if (speedMph === null || speedMph === undefined) return "—"
  var base = Math.round(speedMph) + " mph"
  if (gustMph !== null && gustMph !== undefined && gustMph > speedMph + 0.5)
    base += " (" + Math.round(gustMph) + " gust)"
  return base
}

function formatRain(inches) {
  if (inches === null || inches === undefined) return "—"
  return inches.toFixed(2) + " in"
}

// "up"/"down"/"flat" for how today's current reading compares to yesterday
// (same time of day), or null when either side is missing. Flat within half
// a degree reads as unchanged rather than noise-flipping the arrow.
function yesterdayTrendDirection(currentF, yesterdayF) {
  if (currentF === null || currentF === undefined || yesterdayF === null || yesterdayF === undefined) return null
  var delta = currentF - yesterdayF
  if (Math.abs(delta) < 0.5) return "flat"
  return delta > 0 ? "up" : "down"
}

function yesterdayTrendArrow(direction) {
  if (direction === "up") return "▲"
  if (direction === "down") return "▼"
  if (direction === "flat") return "→"
  return "—"
}

// Thresholds for the sensor-grounded "mood" glyph and bar-pill alert state
// below — deliberately tied only to what the station actually measures
// (thermometer, anemometer, rain gauge), never an inferred sky condition
// the Ambient Weather API doesn't report.
var FREEZE_TEMP_F = 32
var HOT_TEMP_F = 95
var HIGH_GUST_MPH = 30
var RAIN_THRESHOLD_IN = 0.01

function conditionIcon(tempF, dailyRainIn, gustMph) {
  if (dailyRainIn !== null && dailyRainIn !== undefined && dailyRainIn >= RAIN_THRESHOLD_IN) return "🌧"
  if (isHighGust(gustMph)) return "💨"
  if (tempF === null || tempF === undefined) return "🌡"
  if (tempF <= FREEZE_TEMP_F) return "🥶"
  if (tempF >= HOT_TEMP_F) return "🥵"
  return "🌡"
}

function isHighGust(gustMph) {
  return gustMph !== null && gustMph !== undefined && gustMph >= HIGH_GUST_MPH
}

// Drives the bar pill's urgent-color flash — freezing, extreme heat, or a
// high gust, the same conditions the mood glyph reacts to.
function isAlertCondition(tempF, gustMph) {
  if (tempF !== null && tempF !== undefined && (tempF <= FREEZE_TEMP_F || tempF >= HOT_TEMP_F)) return true
  return isHighGust(gustMph)
}

// Reading age, for staleness display ("as of 3m ago").
function ageMinutes(reading, nowMs) {
  if (!reading || reading.dateutc === undefined) return null
  var ts = Number(reading.dateutc)
  if (isNaN(ts)) return null
  var diffMs = (nowMs || Date.now()) - ts
  if (diffMs < 0) return 0
  return Math.floor(diffMs / 60000)
}

if (typeof module !== "undefined") {
  module.exports = {
    parseConfigFile: parseConfigFile,
    isConfigured: isConfigured,
    hasCredentials: hasCredentials,
    parseDeviceList: parseDeviceList,
    parseReading: parseReading,
    localPathFromUrl: localPathFromUrl,
    numberOrNull: numberOrNull,
    currentTempF: currentTempF,
    currentHumidity: currentHumidity,
    currentFeelsLikeF: currentFeelsLikeF,
    currentWindMph: currentWindMph,
    currentWindGustMph: currentWindGustMph,
    currentDailyRainIn: currentDailyRainIn,
    currentMaxDailyGustMph: currentMaxDailyGustMph,
    formatTemp: formatTemp,
    formatBareTemp: formatBareTemp,
    formatPercent: formatPercent,
    formatWind: formatWind,
    formatRain: formatRain,
    yesterdayTrendDirection: yesterdayTrendDirection,
    yesterdayTrendArrow: yesterdayTrendArrow,
    conditionIcon: conditionIcon,
    isHighGust: isHighGust,
    isAlertCondition: isAlertCondition,
    ageMinutes: ageMinutes
  }
}
