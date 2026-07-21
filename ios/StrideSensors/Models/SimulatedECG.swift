import Foundation

/// A synthetic PQRST electrocardiogram waveform, paced to a given heart rate.
///
/// The watch this app pairs with has no ECG sensor — only heart rate (BPM)
/// from its optical PPG sensor. There is no real electrical waveform to plot.
/// This generates a **simulated** ECG-shaped waveform whose beat-to-beat
/// spacing (the R-R interval) matches the live BPM reading, purely so the
/// Live Sensors screen has a recognisable, at-a-glance "is the heart beating,
/// and at roughly what rate" visual instead of an empty line — or, as it
/// showed before this change, a plot of wrist motion mislabeled as heart rate.
///
/// **This is not real cardiac electrical activity, and must never be
/// presented as if it were.** The waveform shape is a fixed, idealised PQRST
/// morphology (a sum of Gaussian "bumps" at physiologically plausible
/// relative positions within the cardiac cycle). Its *rate* tracks the real
/// BPM reading; its *morphology* does not vary with anything — it carries no
/// information about rhythm, conduction, or any actual electrical event, and
/// cannot reveal arrhythmia or any other cardiac finding. Any UI that shows
/// it must label it as simulated (see `LiveSensorsView.heartRateCard`).
enum SimulatedECG {

    /// One PQRST complex as five Gaussian components, expressed as a
    /// fraction `u` of the cardiac cycle (`u ∈ [0, 1)`, where `u = 0.25`
    /// lands on the R-peak and the cycle wraps at 1). Center/width are
    /// fractions of the R-R interval; amplitude is unitless — `SignalChart`
    /// auto-scales whatever range comes back.
    private struct Wave { let center: Double; let width: Double; let amplitude: Double }

    private static let waves: [Wave] = [
        Wave(center: 0.130, width: 0.028, amplitude: 0.12),   // P wave
        Wave(center: 0.225, width: 0.006, amplitude: -0.10),  // Q dip
        Wave(center: 0.250, width: 0.010, amplitude: 1.00),   // R spike
        Wave(center: 0.275, width: 0.010, amplitude: -0.28),  // S dip
        Wave(center: 0.460, width: 0.070, amplitude: 0.28),   // T wave
    ]

    /// Height of the idealised waveform at cycle-fraction `u ∈ [0, 1)`. Flat
    /// (≈0) outside the P/QRS/T bumps, matching a real isoelectric baseline.
    private static func amplitude(at u: Double) -> Double {
        var y = 0.0
        for w in waves {
            let d = (u - w.center) / w.width
            y += w.amplitude * exp(-(d * d))
        }
        return y
    }

    /// `count` samples spanning the last `windowSeconds` of wall-clock time,
    /// paced so one full PQRST complex repeats every `60 / bpm` seconds.
    ///
    /// The default `count` is deliberately high relative to what a ~40pt-tall
    /// sparkline would seem to need. The R-spike is narrow — only ~3–9ms wide
    /// depending on heart rate — and `SignalChart` rescales its Y-axis to
    /// fit `min...max` on every frame. At a coarser sample grid, whether a
    /// sample happens to land near the peak shifts from frame to frame as the
    /// window scrolls, so the *measured* peak height wobbles by up to ~20%
    /// frame-to-frame even though the underlying waveform is perfectly
    /// smooth — and because the chart rescales to that measured peak, the
    /// whole waveform visibly jumps in sync. 2000 samples over a 3s window
    /// (1.5ms spacing) keeps that wobble under ~0.1% at any heart rate up to
    /// the 220 bpm clamp below, which is what actually fixes the "choppy"
    /// look — not frame rate. (Cost is trivial either way: even 2000 points
    /// is a few hundred thousand `exp()` calls/sec, far below what an iPhone
    /// spends on this kind of view without noticing.)
    ///
    /// Returns a flat baseline (all zeros) if `bpm` is `nil` or non-positive
    /// — no HR reading means nothing to pace a beat to, and a flat line reads
    /// more honestly than fabricating a beat.
    ///
    /// `now` defaults to the current time and is evaluated fresh on every
    /// call (Swift re-evaluates default-argument expressions per call, not
    /// once), so calling this from `SignalChart`'s per-frame `sample`
    /// closure with `bpm` as the only argument gives a continuously
    /// scrolling waveform for free — no timer or state needed here.
    static func window(bpm: Double?, count: Int = 2000, windowSeconds: Double = 3.0,
                       now: Double = Date().timeIntervalSinceReferenceDate) -> [Double] {
        guard count > 1 else { return [] }
        guard let bpm, bpm > 0 else { return [Double](repeating: 0, count: count) }

        // Clamp to a physiologically sane range so a garbled/out-of-range HR
        // reading can't collapse the cycle length toward zero and divide by
        // a near-zero number.
        let clampedBPM = min(max(bpm, 20), 220)
        let cycle = 60.0 / clampedBPM
        var out = [Double](repeating: 0, count: count)
        let dt = windowSeconds / Double(count - 1)
        for i in 0..<count {
            let t = now - windowSeconds + Double(i) * dt
            var u = (t / cycle).truncatingRemainder(dividingBy: 1.0)
            if u < 0 { u += 1 }
            out[i] = amplitude(at: u)
        }
        return out
    }
}
