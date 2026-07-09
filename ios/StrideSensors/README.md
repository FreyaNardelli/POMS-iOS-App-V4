# Stride Sensors — iOS (SwiftUI)

> **Want it on your iPhone from Windows?** See **[SIDELOAD.md](SIDELOAD.md)** —
> push to GitHub, let CI build an unsigned `.ipa`, install with Sideloadly.


An iOS app that receives watch sensor data over Wi-Fi (UDP) and makes it
available for any calculation, with a live visualization that mirrors the
Stride "Live sensors" design.

## What it does

- Opens a **UDP listener on port `12345`** using Apple's Network framework.
- Parses each datagram (accelerometer, gyroscope, heart rate, timestamp).
- Stores every sample in a thread-safe, app-wide store (`SensorStore.shared`)
  with the latest value, a rolling history buffer, and a per-packet hook — so
  any formula can be added later without touching the networking code.
- **Logs all sensor data to disk** (`SensorLogStore.shared`): one CSV file per
  day named `YYYY_MM_DD.csv` in the app's Documents/SensorLogs folder, each with
  two tables — **[FREE-LIVING]** (every sample) and **[6MWT]** (samples captured
  during each 6-minute walk test, one `# session N` block per test). Columns:
  `timestamp, accel.x, accel.y, accel.z (gravity removed), gyro.x, gyro.y, gyro.z, heartbeat`.
  Accel is gravity-removed (linear acceleration via a low-pass gravity estimate);
  timestamps are epoch ms; gyro is rad/s.
- Shows four tabs: **Home** (kid-facing greeting, MOVE score with live vitals,
  and daily quest cards that open Check-in, 6-minute walk and SDMT), **Live**
  (3D watch that turns with the data + accel/gyro bars + heart-rate stream),
  **History** (browse the stored daily logs — day dropdown, Free-living / 6MWT
  tables, and CSV export via the share sheet), and **Rewards** (XP wallet,
  badges, claimable rewards). The dev-only **Feed** (raw packet inspector) and
  **Analysis** screens are still in the project (`RawFeedView` / `AnalysisView`)
  but no longer in the tab bar; add them back to `RootTabView` if needed.

## File structure

```
StrideSensors/
├─ StrideSensorsApp.swift          App entry — starts the receiver, wires it to the store
├─ Networking/
│   └─ UDPReceiver.swift           NWListener on :12345, hands raw Data to a callback
├─ Models/
│   ├─ SensorSample.swift          One reading (timestamp, accel, gyro, hr, all raw fields)
│   ├─ SensorPacketParser.swift    Text-array [t,ax..hr] + JSON + CSV parsing
│   ├─ SensorStore.swift           Accessible data: latest, history, formula hook, metrics
│   └─ SensorLogStore.swift        Daily CSV logging (free-living + 6MWT tables), gravity removal
├─ Views/
│   ├─ RootTabView.swift             Tab bar: Home · Live · History · Rewards
│   ├─ HomeView.swift               Kid Home: greeting, MOVE score, quest cards
│   ├─ HistoryView.swift            Browse stored daily CSV logs (day dropdown + export)
│   ├─ CheckinView.swift            Daily check-in (energy / mood / symptom sliders)
│   ├─ WalkView.swift               6-minute walk countdown + ring
│   ├─ SDMTView.swift               Symbol-match thinking-speed test
│   ├─ RewardsView.swift            XP wallet, badges, claimable rewards
│   ├─ LiveSensorsView.swift        Matches the design
│   ├─ WatchModel3DView.swift       SceneKit view: loads watch3Dmodel.usdz, rotates it from live gyro/accel
│   ├─ AxisBar.swift               Center-zero signed bar
│   ├─ SignalChart.swift           Live line chart (TimelineView + Canvas)
│   ├─ RawFeedView.swift
│   └─ AnalysisView.swift
├─ Support/
│   ├─ Theme.swift                 Colors / fonts from the design
│   └─ Info-additions.plist        Required Info.plist keys
└─ test_sender.py                  Synthetic packet sender for testing
```

### 3D watch model
`Resources/watch3Dmodel.usdz` is rendered on the Live screen by `WatchModel3DView`
(SceneKit). Its rotation is integrated from the live gyroscope and nudged by the
accelerometer, so it turns as the physical watch turns. **In Xcode, add the
`.usdz` to the app target** (drag it in, check the target under "Target
Membership") or it won't be in the bundle and the view shows an empty scene.

## Packet format

Send **one reading per UDP datagram** to `:12345`.

**The Wear OS watch's format** — a text array of 8 numbers (this is what the app
now parses natively):
```
[1783483199425, 1.8148049, -2.2625206, 9.483433, 0.05864306, -0.0073303, -0.0268780, 71.0]
```
i.e. `[timestamp_ms, ax, ay, az, gx, gy, gz, hr]` — heart rate is the last value.

**Also accepted** (testing / other senders): a JSON object with named keys, or
plain CSV of the same numbers:
```json
{"t":1720380000.123,"ax":0.42,"ay":-0.18,"az":0.96,"gx":62,"gy":-41,"gz":18,"hr":88}
```
```
t,ax,ay,az,gx,gy,gz,hr
```

| field | meaning | unit (watch) |
|-------|---------|------|
| `t`  | timestamp (seconds or ms — auto-detected) | ms |
| `ax ay az` | accelerometer | m/s² |
| `gx gy gz` | gyroscope | rad/s |
| `hr` | heart rate (optional, last value) | bpm |

Key aliases are accepted (`accelX`, `acc_x`, `gyroX`, `heartRate`, `timestamp`,
…), so you can match your firmware's naming. Extra numeric fields are preserved
verbatim in `SensorSample.fields`.

## Accessing the data for calculations

Everything routes through `SensorStore.shared`:

```swift
// Latest reading
let s = SensorStore.shared.latest

// Windows for analysis
let last5s   = SensorStore.shared.recent(5)        // [SensorSample]
let last120  = SensorStore.shared.lastN(120)
let allData  = SensorStore.shared.snapshot()

// Run a formula on every packet as it arrives
SensorStore.shared.onSample = { sample in
    let jerk = sample.accelMagnitude
    // ... your math; store or publish the result
}
```

Each `SensorSample` exposes `timestamp`, `receivedAt`, `accel` (SIMD3),
`gyro` (SIMD3), `heartRate`, `accelMagnitude`, `gyroMagnitude`, and the raw
`fields` dictionary.

## Setup in Xcode

1. Create a new **iOS App** (SwiftUI, Swift) target — name it `StrideSensors`.
2. Delete the generated `ContentView.swift` and default `App` file, then drag
   the `StrideSensors/` folder here into the project (check "Copy items" and
   your app target).
3. Merge the keys from `Support/Info-additions.plist` into your target's
   Info.plist. **`NSLocalNetworkUsageDescription` is required** — without it iOS
   silently blocks incoming packets.
4. Build & run on a **real device** (recommended) or the simulator.
5. On first launch, accept the **local network** permission prompt.

## Testing without the watch

With the phone and your Mac on the same Wi-Fi network:

```bash
python3 test_sender.py <PHONE_IP> --rate 50 --format json
```

Find `<PHONE_IP>` in iOS Settings → Wi-Fi → ⓘ. You should immediately see the
watch tilt, bars move, packet rate climb, and rows fill in the Feed tab.

Quick one-liner without Python:
```bash
echo '{"t":0,"ax":0.1,"ay":0,"az":1,"gx":0,"gy":0,"gz":0,"hr":90}' | nc -u -w1 <PHONE_IP> 12345
```

## Notes

- UDP is connectionless and lossy by design — fine for high-rate sensor streams.
  If you need guaranteed delivery later, the same parser/store works over TCP.
- The receiver auto-restarts on failure and reuses the port after relaunch.
- The kid screens (Home, Check-in, 6MWT, SDMT, Rewards) are now native SwiftUI,
  matching the HTML prototype; the clinician/parent web dashboard stays separate.
