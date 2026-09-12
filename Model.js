// Pure helpers for the Open Voice Shield panel. No QML imports so the whole file
// stays unit-testable with plain node.

function parseSnapshot(raw) {
  try {
    var data = JSON.parse(String(raw || ""))
    if (!data || typeof data !== "object") return { ok: false, error: "bad-response" }
    return data
  } catch (e) {
    return { ok: false, error: "bad-response" }
  }
}

// A blank snapshot the panel can bind against before the first fetch lands.
function emptySnapshot() {
  return { ok: false, error: "loading", dashboard: null, live: null }
}

function errorLabel(code) {
  switch (String(code || "")) {
    case "loading": return "Connecting"
    case "no-config": return "Not configured"
    case "bad-config": return "Config unreadable"
    case "no-key": return "No API key"
    case "unreachable": return "Unreachable"
    case "curl-missing": return "curl missing"
    case "jq-missing": return "jq missing"
    case "api-error": return "API error"
    default: return String(code || "Unavailable")
  }
}

// The config file the widget reads its key from — surfaced in the empty state
// so an unconfigured user is told exactly where to put the key.
function configPath(home) {
  return String(home || "~") + "/.config/omarchy/ovs.json"
}

function dashboard(snap) {
  return snap && snap.dashboard ? snap.dashboard : null
}

function live(snap) {
  return snap && snap.live ? snap.live : null
}

function activeCalls(snap) {
  var l = live(snap)
  if (l && l.active_count !== undefined && l.active_count !== null) return parseInt(l.active_count, 10) || 0
  var d = dashboard(snap)
  return d && d.active_calls ? parseInt(d.active_calls, 10) || 0 : 0
}

function callsToday(snap) {
  var d = dashboard(snap)
  return d && d.calls_today !== undefined && d.calls_today !== null ? parseInt(d.calls_today, 10) || 0 : 0
}

function highRiskPct(snap) {
  var d = dashboard(snap)
  if (!d || d.high_risk_pct === undefined || d.high_risk_pct === null) return 0
  var n = parseFloat(d.high_risk_pct)
  return isNaN(n) ? 0 : n
}

// High-risk calls counted for *today* only — the last entry of calls_per_day.
// The pill badges this number, so it has to mean "since midnight", not
// "across the whole reporting window".
function highRiskToday(snap) {
  var d = dashboard(snap)
  var days = d && d.calls_per_day ? d.calls_per_day : []
  if (!days.length) return 0
  var last = days[days.length - 1]
  return last && last.high_risk ? parseInt(last.high_risk, 10) || 0 : 0
}

function ports(snap) {
  var l = live(snap)
  if (l && l.ports) return parseInt(l.ports, 10) || 0
  return 0
}

function portsInUse(snap) {
  var l = live(snap)
  if (l && l.ports_in_use !== undefined && l.ports_in_use !== null) return parseInt(l.ports_in_use, 10) || 0
  return activeCalls(snap)
}

function liveItems(snap, limit) {
  var l = live(snap)
  var items = l && l.items ? l.items : []
  return limit ? items.slice(0, limit) : items
}

function highRiskItems(snap, limit) {
  var d = dashboard(snap)
  var items = d && d.recent_high_risk ? d.recent_high_risk : []
  return limit ? items.slice(0, limit) : items
}

// ---------------------------------------------------------------- formatting

function fmtInt(value) {
  var n = parseFloat(String(value))
  if (isNaN(n)) return "—"
  return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

function fmtMoney(value) {
  var n = parseFloat(String(value))
  if (isNaN(n)) return "—"
  return "$" + n.toFixed(2)
}

function fmtMinutes(value) {
  var n = parseFloat(String(value))
  if (isNaN(n)) return "—"
  if (n >= 10000) return Math.round(n / 1000) + "k"
  if (n >= 1000) return (n / 1000).toFixed(1) + "k"
  return Math.round(n).toString()
}

function fmtPct(value) {
  var n = parseFloat(String(value))
  if (isNaN(n)) return "—"
  return (Math.round(n * 10) / 10) + "%"
}

function fmtMos(value) {
  var n = parseFloat(String(value))
  if (isNaN(n)) return "—"
  return n.toFixed(1)
}

function elapsedLabel(seconds) {
  var n = parseInt(String(seconds), 10)
  if (isNaN(n) || n < 0) return "—"
  var m = Math.floor(n / 60)
  var s = n % 60
  if (m >= 60) {
    var h = Math.floor(m / 60)
    return h + "h" + (m % 60 < 10 ? "0" : "") + (m % 60) + "m"
  }
  return m + ":" + (s < 10 ? "0" : "") + s
}

function relativeTime(iso, nowMs) {
  if (!iso) return ""
  var then = Date.parse(String(iso))
  if (isNaN(then)) return ""
  var deltaSec = Math.max(0, Math.round(((nowMs || Date.now()) - then) / 1000))
  if (deltaSec < 60) return "just now"
  var m = Math.floor(deltaSec / 60)
  if (m < 60) return m + "m ago"
  var h = Math.floor(m / 60)
  if (h < 24) return h + "h ago"
  return Math.floor(h / 24) + "d ago"
}

function dots(count) {
  var out = ""
  for (var i = 0; i < count; i++) out += "•"
  return out
}

// Mask the subscriber digits, keep the ends.
//
// This panel lives on a desktop that gets screen-shared, screenshotted and
// photographed over a shoulder, so full E.164 numbers are not a safe default.
// The leading digits carry the country code and route prefix — the part an
// operator actually reads a row for — and the last two make two rows from the
// same prefix distinguishable. Everything between is the subscriber, and it is
// hidden.
function maskNumber(bare) {
  var head = 5
  var tail = 2
  if (bare.length <= head + tail + 1) {
    // Too short to keep both ends and still hide anything meaningful:
    // keep the prefix, hide the rest.
    var keep = Math.max(1, bare.length - 3)
    return bare.slice(0, keep) + dots(bare.length - keep)
  }
  return bare.slice(0, head) + dots(bare.length - head - tail) + bare.slice(bare.length - tail)
}

// Phone numbers arrive as bare E.164 digits. Masking is the default; pass
// `mask === false` to render them in full.
function fmtNumber(value, mask) {
  var bare = String(value || "").replace(/[^\d+]/g, "").replace(/^\+/, "")
  if (!bare) return "unknown"
  var shown = mask === false ? bare : maskNumber(bare)
  return bare.length > 7 ? "+" + shown : shown
}

function callRoute(call, mask) {
  if (!call) return ""
  return fmtNumber(call.ani, mask) + "  →  " + fmtNumber(call.dialed, mask)
}

// ---------------------------------------------------------------- live calls

// `answered_at` is null until the far end picks up, so it separates a call
// that is still ringing from one with media flowing — worth showing, because
// a trunk full of ringing calls is a very different picture from a busy one.
function liveConnected(call) {
  return !!(call && call.answered_at)
}

// Route context for a call in progress: which prefix matched, how it is
// carried, and which media node is relaying it.
function liveMeta(call) {
  if (!call) return ""
  var parts = []
  if (call.route_prefix) parts.push("prefix " + String(call.route_prefix))
  if (call.dest_transport) parts.push(String(call.dest_transport).toUpperCase())
  if (call.media_node) parts.push(String(call.media_node))
  return parts.join("  \u00b7  ")
}

// Progress toward the per-call ceiling the platform enforces. 0 when no cap is
// set, which hides the bar rather than drawing a meaningless full one.
function liveProgress(call, elapsedSec) {
  var max = call && call.max_call_seconds ? parseInt(call.max_call_seconds, 10) || 0 : 0
  if (max <= 0) return 0
  var elapsed = parseInt(String(elapsedSec), 10) || 0
  return Math.max(0, Math.min(1, elapsed / max))
}

// ------------------------------------------------------------------ verdicts

function analysis(call) {
  return call && call.analysis ? call.analysis : null
}

function probability(call) {
  var a = analysis(call)
  if (!a || a.probability === undefined || a.probability === null) return 0
  return parseInt(a.probability, 10) || 0
}

function recommendation(call) {
  var a = analysis(call)
  return a && a.recommendation ? String(a.recommendation).toLowerCase() : ""
}

function category(call) {
  var a = analysis(call)
  var c = a && a.category ? String(a.category) : ""
  if (!c || c === "unknown") return "Unclassified"
  return c.charAt(0).toUpperCase() + c.slice(1).replace(/[_-]+/g, " ")
}

function verdictTitle(call) {
  var a = analysis(call)
  if (a && a.title) return String(a.title)
  return category(call)
}

// Red flags come back numbered ("1. The caller ..."). Strip the ordinal so the
// panel can render its own list without doubled numbering.
function redFlags(call, limit) {
  var a = analysis(call)
  var flags = a && a.red_flags ? a.red_flags : []
  var out = []
  for (var i = 0; i < flags.length; i++) {
    var text = String(flags[i] || "").replace(/^\s*\d+[.)]\s*/, "").replace(/^\s+|\s+$/g, "")
    if (text) out.push(text)
  }
  return limit ? out.slice(0, limit) : out
}

// "block" | "review" | "allow" -> severity rank, used for colour selection.
function severity(call) {
  var rec = recommendation(call)
  if (rec === "block") return 2
  if (rec === "review") return 1
  var p = probability(call)
  if (p >= 70) return 2
  if (p >= 30) return 1
  return 0
}

// ------------------------------------------------------------------- visuals

// risk_distribution buckets -> drawable segments with a 0..1 share each.
function riskSegments(snap) {
  var d = dashboard(snap)
  var buckets = d && d.risk_distribution ? d.risk_distribution : []
  var total = 0
  for (var i = 0; i < buckets.length; i++) total += parseInt(buckets[i].count, 10) || 0
  if (total <= 0) return []

  var out = []
  for (var j = 0; j < buckets.length; j++) {
    var count = parseInt(buckets[j].count, 10) || 0
    var bucket = String(buckets[j].bucket || "")
    out.push({
      bucket: bucket,
      label: bucketLabel(bucket),
      severity: bucketSeverity(bucket),
      count: count,
      fraction: count / total
    })
  }
  return out
}

function bucketSeverity(bucket) {
  var start = parseInt(String(bucket || "0").split("-")[0], 10) || 0
  if (start >= 70) return 2
  if (start >= 30) return 1
  return 0
}

function bucketLabel(bucket) {
  switch (bucketSeverity(bucket)) {
    case 2: return "High"
    case 1: return "Medium"
    default: return "Low"
  }
}

// calls_per_day -> two independently normalised series.
//
// High-risk calls run at 0.5-2.5% of a day's volume, so stacking them inside
// the volume bar clamps every day to the same one-pixel sliver and reads as an
// axis rather than as data. The counts get their own scale (`riskFraction`,
// against the worst day of the window) and the panel draws them as a separate
// strip, which keeps both series readable without implying a shared axis.
function sparkBars(snap) {
  var d = dashboard(snap)
  var days = d && d.calls_per_day ? d.calls_per_day : []

  var maxCalls = 0
  var maxRisk = 0
  for (var i = 0; i < days.length; i++) {
    maxCalls = Math.max(maxCalls, parseInt(days[i].calls, 10) || 0)
    maxRisk = Math.max(maxRisk, parseInt(days[i].high_risk, 10) || 0)
  }

  var out = []
  for (var j = 0; j < days.length; j++) {
    var calls = parseInt(days[j].calls, 10) || 0
    var risky = parseInt(days[j].high_risk, 10) || 0
    out.push({
      date: String(days[j].date || ""),
      calls: calls,
      highRisk: risky,
      fraction: maxCalls > 0 ? calls / maxCalls : 0,
      riskFraction: maxRisk > 0 ? risky / maxRisk : 0,
      riskRate: calls > 0 ? risky / calls : 0
    })
  }
  return out
}

function dayInitial(dateString) {
  if (!dateString) return ""
  var d = new Date(String(dateString) + "T12:00:00")
  if (isNaN(d.getTime())) return ""
  return ["S", "M", "T", "W", "T", "F", "S"][d.getDay()]
}

// ------------------------------------------------------------- notifications

// High-risk calls that crossed the threshold and have not been announced yet.
// Returns [] on the first successful fetch: announcing a backlog the moment
// the shell starts would be noise, not news.
function unannouncedHighRisk(snap, seenIds, threshold, primed) {
  if (!snap || snap.ok !== true) return []
  var limit = parseInt(String(threshold), 10)
  if (isNaN(limit)) limit = 70

  var out = []
  var items = highRiskItems(snap)
  for (var i = 0; i < items.length; i++) {
    var call = items[i]
    var id = call && call.id ? String(call.id) : ""
    if (!id || seenIds.indexOf(id) !== -1) continue
    if (probability(call) < limit) continue
    if (primed) out.push(call)
  }
  return out
}

function rememberIds(snap, seenIds, cap) {
  var items = highRiskItems(snap)
  var next = seenIds.slice()
  for (var i = 0; i < items.length; i++) {
    var id = items[i] && items[i].id ? String(items[i].id) : ""
    if (id && next.indexOf(id) === -1) next.push(id)
  }
  var max = cap || 200
  return next.length > max ? next.slice(next.length - max) : next
}

function notificationBody(call, mask) {
  var parts = [callRoute(call, mask), probability(call) + "% fraud"]
  var rec = recommendation(call)
  if (rec) parts.push(rec.toUpperCase())
  return parts.join("  ·  ")
}

// ---------------------------------------------------------------------- pill

function pillText(snap, glyph, alertGlyph) {
  if (!snap || snap.ok !== true) return String(glyph || "")
  var risky = highRiskToday(snap)
  if (risky > 0) return String(alertGlyph || glyph || "") + " " + risky
  var active = activeCalls(snap)
  if (active > 0) return String(glyph || "") + " " + active
  return String(glyph || "")
}

function tooltipText(snap) {
  if (!snap) return "Open Voice Shield"
  if (snap.ok !== true) return "Open Voice Shield — " + errorLabel(snap.error)
  return "Open Voice Shield  ·  " + fmtInt(callsToday(snap)) + " calls today  ·  "
    + highRiskToday(snap) + " high risk  ·  " + activeCalls(snap) + " active"
}

if (typeof module !== "undefined") {
  module.exports = {
    parseSnapshot: parseSnapshot,
    emptySnapshot: emptySnapshot,
    errorLabel: errorLabel,
    configPath: configPath,
    dashboard: dashboard,
    live: live,
    activeCalls: activeCalls,
    callsToday: callsToday,
    highRiskPct: highRiskPct,
    highRiskToday: highRiskToday,
    ports: ports,
    portsInUse: portsInUse,
    liveItems: liveItems,
    highRiskItems: highRiskItems,
    fmtInt: fmtInt,
    fmtMoney: fmtMoney,
    fmtMinutes: fmtMinutes,
    fmtPct: fmtPct,
    fmtMos: fmtMos,
    elapsedLabel: elapsedLabel,
    relativeTime: relativeTime,
    fmtNumber: fmtNumber,
    maskNumber: maskNumber,
    callRoute: callRoute,
    liveConnected: liveConnected,
    liveMeta: liveMeta,
    liveProgress: liveProgress,
    analysis: analysis,
    probability: probability,
    recommendation: recommendation,
    category: category,
    verdictTitle: verdictTitle,
    redFlags: redFlags,
    severity: severity,
    riskSegments: riskSegments,
    bucketSeverity: bucketSeverity,
    bucketLabel: bucketLabel,
    sparkBars: sparkBars,
    dayInitial: dayInitial,
    unannouncedHighRisk: unannouncedHighRisk,
    rememberIds: rememberIds,
    notificationBody: notificationBody,
    pillText: pillText,
    tooltipText: tooltipText
  }
}
