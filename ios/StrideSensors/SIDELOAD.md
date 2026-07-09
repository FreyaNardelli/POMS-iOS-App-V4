# Get Stride onto your iPhone (Windows, no Xcode)

You can't compile iOS apps on Windows, but you can build in the cloud and
install from your PC. Two build options, then Sideloadly to install.

## Step 1 — Push this folder to GitHub

Create a repo and push. This folder can be the repo root, or live under
`ios/StrideSensors` — the CI files default to `ios/StrideSensors`, so if you put
it at the repo root, edit `working_directory` in `.github/workflows/ios.yml`
(and `codemagic.yaml`) to `.`.

## Step 2 — Build an unsigned .ipa in the cloud

**Option A — GitHub Actions (free, already wired):**
1. In your repo, open the **Actions** tab and enable workflows.
2. The **Build unsigned IPA** workflow runs on every push (or run it manually via
   *Run workflow*).
3. When it finishes, open the run and download the **StrideSensors-unsigned-ipa**
   artifact. Unzip it to get `StrideSensors-unsigned.ipa`.

**Option B — Codemagic (free tier):** connect the repo, pick the
`stride-unsigned` workflow, run it, download the `.ipa` artifact.

Both use [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`project.yml`) to
generate the Xcode project, so there is no `.xcodeproj` to maintain by hand.

## Step 3 — Install with Sideloadly (on Windows)

1. Install **Sideloadly** (sideloadly.io) and iTunes (for the Apple driver).
2. Plug in your iPhone, open Sideloadly, and drag in `StrideSensors-unsigned.ipa`.
3. Enter your **Apple ID** (a free one works). Sideloadly re-signs and installs.
4. On the iPhone: **Settings → General → VPN & Device Management** → trust your
   developer profile.
5. Launch **Stride**. On first run, **allow the Local Network permission** — the
   UDP receiver gets no packets until you do.

> Free Apple ID caveats: the app expires after **7 days** (re-install to refresh)
> and you can have at most 3 sideloaded apps. A paid Apple Developer account
> ($99/yr) lifts this and enables TestFlight instead.

## Step 4 — Point the watch at your phone

The watch app streams UDP to `<iPhone-IP>:12345`. Put the phone's Wi-Fi IP
(Settings → Wi-Fi → ⓘ) into the watch app. To test without the watch, run
`test_sender.py` from any computer on the same network (see README.md).

## Notes

- The 3D model `Resources/watch3Dmodel.usdz` is included and bundled
  automatically by XcodeGen.
- The Local Network usage string is injected via `project.yml`
  (`INFOPLIST_KEY_NSLocalNetworkUsageDescription`).
- Deployment target is iOS 16.0.
