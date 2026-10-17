# Tuning for latency

## 1. Measure your real speed (shaping off)

Do this from a **wired** PC. Wifi adds its own noise.

```sh
/etc/init.d/qosmate stop
```

Run the [Waveform bufferbloat test](https://www.waveform.com/tools/bufferbloat) 2–3 times. Write down the **lowest** download and upload speeds, and the "+X ms" latency increase for each direction.

```sh
/etc/init.d/qosmate start
```

## 2. Set the shaper to ~90% of your lowest speed

Network → QoSmate → Settings, or `config.env` before install:

| Setting | Value |
|---|---|
| Download Rate (kbps) | lowest download × 0.9 × 1000 |
| Upload Rate (kbps) | lowest upload × 0.9 × 1000 |
| Root qdisc | HFSC (gaming lanes) or CAKE |
| Link preset (Advanced) | `ethernet` for fiber, `docsis` for cable |
| WASH DSCP up/down | both on |

Example: lowest result 411 / 538 Mbps → `370000` / `485000`.

The shaper has to be slightly below your real speed so queues form in the router, where qosmate controls them, and not in the modem or at the ISP.

## 3. Retest and adjust

Goal: **+0 to +3 ms** under load in both directions.

- Still seeing latency increase? Lower that direction's rate by 500–1000 kbps at a time and retest.
- At +0 ms and want speed back? Try 95% and keep it only if latency stays flat.
- Your speed test tops out *below* the shaper rate? The bottleneck is elsewhere (ISP, test server). Latency is what matters.

## 4. Gaming priority

The installer adds one rule per device in `GAMING_IPS`: UDP from that IP, except ports 80 and 443, goes to class CS5 (the realtime lane). Ports 80/443 are left out because browsers and YouTube use UDP (QUIC) on them.

You only need **outbound** rules. qosmate stores the mark in conntrack and restores it on the reply traffic, so "inbound" rules never match.

To check it's working: start a game, open Network → QoSmate → Connections, and filter by your device's IP. The game connection should show CS5.

## 5. Low-latency CPU / NIC tweaks (`ENABLE_LOWLATENCY`)

`/etc/lowlatency.sh` runs at boot and:

- sets the CPU governor to `performance`
- disables CPU idle states deeper than C1E (C3/C6/C7/C8), which take longer to wake from
- turns NIC interrupt coalescing off (`ethtool -C <if> rx-usecs 0`)

Be realistic about what this buys you: **fractions of a millisecond**. On the reference build, idle latency went from 6.3 to 5.8 ms median, and the 95th percentile tightened by about half a millisecond. The big win is the shaper. These tweaks just remove a little noise on top. The cost is a few watts and slightly warmer hardware. Check temps with:

```sh
cat /sys/class/thermal/thermal_zone*/temp   # 55000 = 55 °C
```

Notes:
- On Intel `e1000e` NICs, `rx-usecs` values 0–4 are **modes**, not microseconds: 0 = off, 1 = dynamic, 3 = conservative, 4 = simplified.
- On Realtek USB (`r8152`) the value is in nanoseconds despite the label. The default `15000` is 15 µs.
- If a USB adapter reconnects, it comes back with its default coalescing until the next boot. That's harmless.

To turn the tweaks off: remove the `sh /etc/lowlatency.sh` line from `/etc/rc.local` and reboot.

## What won't help

- Changing DNS servers to "lower ping". DNS only resolves the server address at match start, and game packets never touch it.
- Stacking more QoS. If loaded latency already matches idle, there's no bufferbloat left.
- Expecting the router to lower your base ping. That's set by distance and your ISP's routing. Use geomate to stay on nearby servers.

## Hardware notes

- USB Ethernet adds a bit of latency and occasional jitter compared to a PCIe NIC. A two-port mini PC, or an M.2/PCIe NIC, is the upgrade if you're chasing the last millisecond.
- Use a USB 3 port directly on the PC, not a hub. If you see random spikes, check `dmesg | grep -iE "r8152|disconnect|reset"` for adapter resets.
