# Blip - Tunnel Speed Test

A single self-contained `index.html` that measures the network path between a
browser and **this** nginx server: download, upload, latency, jitter, an
estimated packet-loss figure, and a simple quality score. No backend, no
external libraries, no build step. Served by bare nginx.
---

### Quick start with Docker

Runs the official nginx image with this repo's config, page, and download files
mounted in. No build step.

```bash
# 1. Generate the incompressible download files once (host side).
./make-files.sh ./dl

# 2. Run it: serves on http:///, restarts on boot, dl/ persists on the host.
docker run -d --name blip --restart unless-stopped -p 80:80 \
  -v "$PWD/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$PWD/index.html:/var/www/blipspeedtest/index.html:ro" \
  -v "$PWD/dl:/var/www/blipspeedtest/dl:ro" \
  nginx:stable
```

## Files

- `index.html` - the entire app (HTML + CSS + JS inline).
- `nginx.conf` - the vhost: serves the page, the download files, the upload sink, and an IP echo.
- `make-files.sh`- generates the incompressible files the download test pulls.
- `README.md` - this file.

## Deploy

1. **Generate the download files:** `./make-files.sh /var/www/blipspeedtest/dl`
   (random bytes; see "Why incompressible" below).
2. **Place the page:** put `index.html` at `/var/www/blipspeedtest/index.html`, so the
   layout is `/var/www/blipspeedtest/{index.html, dl/*.bin}`.
3. **Add the vhost:** use `nginx.conf` as a server block (or fold its `location`
   blocks into an existing server). Adjust `root` if your webroot differs.
4. **Reload:** `nginx -t && nginx -s reload`. Open the host in a browser, the test
   **starts automatically** on load (use the Retest button to run it again).

Preview the UI without deploying anything by opening `index.html?demo=1` - it
synthesises plausible numbers client-side and badges itself **DEMO DATA**.

## The one knob

`CONFIG.testDurationSec` near the top of the script (default `30`) is the only
thing you need to touch to make the test longer or shorter. Everything derives
from it - the per-phase windows (`phaseWeights` splits the budget across
latency / download / upload), the sampling cadence, and the progress bar.

Each phase runs for its **full** allotted window; nothing stops early on "enough
samples." So a longer duration means proportionally more measurement across the
whole run, and the reported figures reflect the entire test length rather than a
quick burst at the start.

---

## Design decisions & rationale

The parts below are choices you can't infer by reading the code, or that look
wrong until you know why.

**Parallel streams, aggregate throughput.** Download and upload each run
`CONFIG.parallelStreams` (6) concurrent connections, and the reported speed is
the *aggregate* across them. A single TCP flow under-reports a fast or
high-latency link because one connection's congestion window can't fill the pipe;
multiple flows can. This is the standard approach for saturation tests.

**p90 headline, not the peak or the mean.** The headline number is the 90th
percentile of the per-interval aggregate samples. The p90 naturally discounts the
TCP slow-start ramp at the beginning of each transfer without throwing away the
steady-state, and it's more stable than a raw max. The expandable panels show the
full distribution (min / p25 / median / p75 / max) per file size if you want to
see the spread.

**Adaptive size ramp.** Within each direction the test starts at the smallest file
and climbs: it spends a short slice at a size, estimates how long one file of the
*next* size would take at the speed it just measured, and steps up only if that's
comfortably under `CONFIG.bandwidthFinishRequestDuration` (1 s). Once a size's files
would take longer than that (or the next size wouldn't fit in the time left) it
stops climbing and spends the rest of the window at that largest feasible size. A
fast link walks up to the 100 MB file and dwells there; a slow tunnel settles on,
say, 10 MB instead of grinding on a 100 MB transfer it can't finish. The full phase
window is always used either way, and the detail panels only show the sizes actually
exercised. (This mirrors the ramp-up in Cloudflare's engine, adapted to our
fixed-window model.)

**Upload is measured by send-rate, and relies on nginx draining the body.**
The browser can't see when bytes leave the NIC, so upload throughput comes from
`XHR.upload.onprogress` deltas over the steady window, the real bytes pushed onto the
wire. nginx returns `204` and discards the body; it drains (reads + throws away)
the request body *because keepalive is on*, which is what lets the browser finish
sending. The exact moment the 204 comes back doesn't affect the measurement.

**Reliability is a packet-loss proxy, not true loss (and it can't be otherwise here).**
nginx speaks HTTP over TCP, and TCP silently retransmits lost segments before any
JavaScript sees them. Real IP-layer loss is invisible to a browser talking to an
HTTP server; measuring it would need a UDP/WebRTC path (a TURN server), which this
deliberately doesn't have. So the "packet loss" figure is a **proxy**: sequential
pings, counting replies that don't arrive within an adaptive window of
`max(300 ms, 3 × baseline-median RTT)`. The window scales to the link so a slow or
high-latency tunnel doesn't get flagged with false positives. Only **timeouts**
count toward the percentage; **hard errors** (connection refused/reset -> server
actually unreachable) are surfaced separately as "couldn't reach server" and never
folded into the loss number. Below `CONFIG.ping.minSamplesForLoss` (20) samples
the figure is shown with a low-confidence caveat. The card surfaces this inverted as
a **Reliability** percentage (`100 − the timeout rate`, so higher is better); the
copied report uses the same figure. On a VPN this is still useful:
a misconfigured tunnel MTU or fragmentation tends to show up here as elevated
timeouts and jitter.

**Latency, loaded and unloaded.** Unloaded latency/jitter come from the ping phase
(the successful RTTs double as the latency samples). During the download and
upload phases a concurrent probe records latency *under load* - that's the
bufferbloat figure, and it's usually the more honest number for real-world feel.
Jitter is the average gap between consecutive RTTs. Latency comes from the browser's
Resource Timing API (`responseStart − requestStart`) rather than a wall-clock timer,
so XHR scheduling and event-loop jitter stay out of the number; the loaded probe is
throttled (~400 ms apart) and capped at the most recent 20 samples so it doesn't
congest the very transfer it's measuring.

**HTTP/1.1 vs HTTP/2.** The vhost ships on HTTP/1.1 on purpose. Under HTTP/2 the 6
"parallel" requests multiplex onto a single connection and a single congestion
window, which under-fills a fat tunnel. If you put TLS + HTTP/2 in front, either
keep this vhost on 1.1 or raise `parallelStreams` and expect different ramp
behaviour.

**Why incompressible download files.** `make-files.sh` pulls from `/dev/urandom`.
If the files were compressible, nginx (or any proxy) could gzip them on the wire
and the browser would inflate them, so you'd be measuring compression ratio, not
link speed. For the same reason the `/dl/` location forces `gzip off`.

**Clipboard copy works on plain HTTP.** The copy button falls back to a `execCommand("copy")`
path so it works regardless. The report it produces is plain text aimed at pasting
into a support ticket: all metrics, per-size medians, the client IP, server host,
duration, approximate data used, and the browser string.

**The IP shown.** `/ip` echoes `$remote_addr` - the source address nginx sees.

**Look & feel.** System font stacks (not a web font) because loading a font from a
CDN breaks the offline / no-dependency constraint. The deliberate
visual signature is monospace tabular numerics on every readout so digits don't
jump as they update. Orange = download, violet = upload throughout.

---

## What it deliberately does NOT do

- **Not true packet loss.** See above, it's an HTTP-timeout proxy. Don't quote it
  as a hard loss percentage.
- **Single endpoint.** No geo-distributed servers; it tests one path only.
- **Uses real bandwidth, and a lot of it.** The largest probe is 100 MB over 6
  parallel streams, so a fast link can move several hundred MB up to ~1 GB+ per run,
  and the test auto-starts on every page load. That's fine on your own infra (the
  point is to saturate the tunnel). A slow link no longer grinds on the 100 MB file,
  the adaptive ramp stops climbing and dwells on a smaller size, but to rein in a
  fast link, drop the 100 MB entry from `download[]`/`upload[]` or shorten
  `testDurationSec`.
- **TCP/HTTP throughput**, not raw UDP. Very high-bandwidth links can also bump
  into browser/JS overhead before they hit the real ceiling.
- **No history or storage** beyond the theme preference (saved in `localStorage`,
  wrapped so it silently no-ops if storage is unavailable).

## Tuning reference

All in the `CONFIG` object at the top of the script:

- `testDurationSec` - total wall-clock length. The main knob.
- `phaseWeights` - how that budget splits across `latency` / `download` / `upload`.
- `parallelStreams` - concurrent connections per transfer phase.
- `sampleIntervalMs` - throughput sampling + chart cadence.
- `ping.floorMs`, `ping.baselineMult` - the adaptive loss/latency timeout
  (`max(floorMs, baselineMult × baseline median)`).
- `ping.minSamplesForLoss` - below this, the reliability figure is caveated.
- `loadedLatencyThrottleMs` / `loadedLatencyMaxPoints` - spacing and cap for the
  under-load latency probes.
- `bandwidthFinishRequestDuration` / `rampSliceMs` - the adaptive size ramp: stop
  climbing once one file at a size would take this long, and how long to probe each
  size on the way up.
- `estimatedServerTime` - ms subtracted from latency when no `Server-Timing` header
  is present (0 for static nginx).
- `minSampleFracOfInterval` - discards throughput samples from anomalously short ticks.
- `download[]` / `upload[]` - file sizes, listed ascending (the ramp decides how far
  up to climb). The `download` entries' `file` names must match `make-files.sh`.

## Support

This is free and open source. If it saved you some time, you can buy me a coffee:

[Buy me a coffee ☕](https://buymeacoffee.com/abskulaity)

  
## License

MIT. Design inspired by the Cloudflare Speed Test; **not affiliated with or
endorsed by Cloudflare.**
