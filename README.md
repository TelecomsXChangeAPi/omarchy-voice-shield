# Open Voice Shield for Omarchy

[Open Voice Shield](https://ovs.telecomsxchange.com/) in the Omarchy bar — call-fraud
verdicts, the calls currently on your SIP trunk, and the week's traffic, without
leaving the desktop.

By TelecomsXChange.

## What it shows

**Bar pill.** A shield glyph that stays quiet while nothing is wrong. It badges
today's high-risk verdict count in the theme's urgent colour the moment one
lands, and otherwise shows the number of calls currently up. Hover for a summary.

**Panel** (click the pill):

| Section | Content |
|---|---|
| Hero | Calls today, active calls, ports, high-risk count |
| Risk distribution | Low / medium / high split across the reporting window |
| Volume · high risk | Seven days of call volume with high-risk counts on their own scale |
| Stats | Calls, minutes, high-risk rate, spend, balance, ports in use |
| On the wire | A card per live call: ringing vs connected, radar ping, media-flow dots, clock counting up between fetches, route prefix / transport / media node, and progress toward the per-call cap |
| Recent verdicts | Fraud probability, title, route, age, recommendation — click to open the call |

Phone numbers are **masked by default** (`+97144••••11`): the country code and
route prefix stay readable, the subscriber digits do not. A bar panel is on
screen during screen-shares, screenshots and shoulder-surfing, so full numbers
are opt-in — set `"maskNumbers": false` on the widget's entry in `shell.json`.

**Notifications.** A new verdict at or above the threshold raises a critical
desktop notification with the route, probability and recommendation. The first
fetch after a shell start only primes the seen-list, so a restart never replays
the backlog as a burst of alerts.

## Install

```bash
omarchy plugin add https://github.com/telecomsxchange/omarchy-voice-shield
omarchy plugin enable tcxc.voice-shield --section right
```

Requires `curl` and `jq` (`omarchy pkg add jq`).

## Configure

Mint an API key in the OVS dashboard under **API keys**, then:

```bash
mkdir -p ~/.config/omarchy
cat > ~/.config/omarchy/ovs.json <<'EOF'
{ "apiKey": "ovs_…" }
EOF
chmod 600 ~/.config/omarchy/ovs.json
```

The key is read from this file by `ovs-fetch`, never passed on a command line,
so it stays out of the process table.

| Key | Default | Meaning |
|---|---|---|
| `apiKey` | — | Required. An `ovs_…` key. |
| `baseUrl` | `https://ovs.telecomsxchange.com/api` | Point at a self-hosted deployment. |
| `days` | `7` | Reporting window for the stats and chart. |

Widget settings (refresh interval, window, notification threshold) live in the
plugin's entry in `~/.config/omarchy/shell.json`:

```json
{
  "id": "tcxc.voice-shield",
  "refreshIntervalSec": 60,
  "days": 7,
  "notifyHighRisk": true,
  "highRiskThreshold": 70,
  "maskNumbers": true
}
```

## Controls

| Input | Action |
|---|---|
| Left click | Open / close the panel |
| Right click | Refresh now |
| Middle click | Open the OVS console (`/app`) |
| ↑ / ↓ | Move through recent verdicts |
| Enter | Open the selected call in the browser |
| Esc | Close |
| Tab | Switch to the neighbouring bar panel |

IPC, for a keybinding:

```bash
omarchy-shell tcxc.voice-shield toggle
omarchy-shell tcxc.voice-shield refresh
```

## Layout

```
manifest.json   Plugin + bar-widget manifest and settings schema
Panel.qml       Bar button and panel
Model.js        Parsing, formatting and normalisation (no QML imports — testable with node)
ovs-fetch       Fetches one combined snapshot; always exits 0 with a JSON result
```

`ovs-fetch` returns `{"ok":false,"error":"…"}` rather than failing, so the panel
renders a diagnosable state (`no-key`, `unreachable`, `jq-missing`) instead of a
dead widget. A transient failure keeps the last good reading on screen.

## API

Two endpoints, once per refresh:

- `GET /customer/dashboard?days=N` — counts, risk distribution, per-day series, recent high-risk calls, balance
- `GET /customer/live-calls` — calls in progress, ports in use

Both authenticate with `X-API-Key`.

## Notes on the chart

High-risk calls run at roughly 0.5–2.5% of daily volume. Stacked inside the
volume bar they clamp to a one-pixel sliver on every day and read as an axis, so
the two series are drawn as separate strips on independent scales — volume
against the busiest day, high-risk against the worst day. Neither strip implies
a shared axis with the other.
