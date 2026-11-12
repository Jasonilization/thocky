import Foundation
import simd

/// Turns the accelerometer stream into a keystroke force reading.
///
/// The chain is:
///   1. gravity removal - a slow EMA per axis tracks the resting vector, so a
///      laptop sitting flat still reads ~1 g without firing anything;
///   2. linear magnitude |a - g| with an adaptive noise floor that follows the
///      desk and rises when the machine is being handled;
///   3. impact detection - a gate combining the noise floor with the sensitivity
///      control, plus a peak-hold window and a refractory period so one strike
///      is scored once;
///   4. calibration - force is scored between a "soft" percentile and a "slam"
///      percentile measured while the user types normally, instead of magic
///      numbers that would be wrong on another desk or another MacBook.
final class ForceDetector {
    /// One detected impact.
    struct Impact {
        var start: UInt64          /* mach time */
        var end: UInt64
        var peak: Double           /* g, gravity-free */
        var score: Double          /* 0...1 continuous force */
        var consumed: Bool = false
    }

    /// Result of correlating a key event with the sensor stream.
    struct Reading {
        let score: Double          /* 0...1 */
        let impact: Impact
        let fromSensor: Bool
    }

    struct Telemetry {
        var noiseFloor: Double = 0
        var lastMagnitude: Double = 0
        var lastScore: Double = 0
        var magnitudeHistory: [Double] = []
        var recentImpacts: [Double] = []
        var impactCount: Int = 0
        var calibrating: Bool = false
        var calibrationSamples: Int = 0
        var calibrationProgress: Double = 0
    }

    // MARK: tuning
    var sensitivity: Double = 1.0          /* 0.4 ... 2.5 */
    var softCeiling: Double = 0.0075       /* g; below this is a brushed key */
    var slamFloor: Double = 0.14           /* g; above this is a slam */
    var minGate: Double = 0.0025
    var noiseFloor: Double = 0.0015

    let calibrationDurationMs: Double = 8000

    private let maxImpacts = 48
    private let historyLength = 320
    private var impacts: [Impact] = []
    private var magnitudeHistory: [Double] = []
    private var gravity = SIMD3<Double>(0, 0, 0)
    private var gravityReady = false
    private var lastSampleTime: UInt64 = 0
    private var lastMagnitude = 0.0
    private var tracking: Impact?
    private var lastImpactEnd: UInt64 = 0

    private var calibrationSamples: [Double] = []
    private var calibrationStart: UInt64 = 0
    private var calibrating = false

    private let lock = NSLock()

    init() {}

    // MARK: - intake (sensor thread)

    func ingest(_ s: MotionSensor.Sample) {
        lock.lock()
        defer { lock.unlock() }

        let dt: Double
        if lastSampleTime == 0 { dt = 0.001 }
        else { dt = max(1e-4, machIntervalMs(s.machTime, lastSampleTime) / 1000.0) }
        lastSampleTime = s.machTime

        let accel = SIMD3<Double>(s.x, s.y, s.z)
        if !gravityReady {
            gravity = accel
            gravityReady = true
            return
        }

        /* Gravity is a slow EMA, frozen while an impact is in flight so the
           strike does not drag the rest-point along with it. */
        if tracking == nil {
            let a = 1.0 - exp(-dt / 0.45)
            gravity += (accel - gravity) * a
        }

        let linear = accel - gravity
        let mag = simd_length(linear)

        /* Adaptive noise floor: falls fast (quiet desk), rises slowly (handled
           laptop) - both moves converge toward the current magnitude. */
        if mag < noiseFloor {
            noiseFloor += (mag - noiseFloor) * 0.25
        } else {
            noiseFloor += (0.005 + 0.0002 * dt) * (mag - noiseFloor)
        }
        lastMagnitude = mag
        magnitudeHistory.append(mag)
        if magnitudeHistory.count > historyLength {
            magnitudeHistory.removeFirst(magnitudeHistory.count - historyLength)
        }

        let gate = gateFor(sens: sensitivity, floor: noiseFloor)

        if tracking == nil {
            let quiet = s.machTime &- lastImpactEnd > ticks(forMs: 110)
            if quiet && mag > gate {
                tracking = Impact(start: s.machTime, end: s.machTime,
                                  peak: mag, score: 0)
            }
        } else {
            var imp = tracking!
            imp.peak = max(imp.peak, mag)
            imp.end = s.machTime
            let durationMs = machIntervalMs(imp.start, s.machTime)
            if durationMs > 90.0 || mag < imp.peak * 0.35 {
                imp.score = score(forPeak: imp.peak)
                lastImpactEnd = imp.end
                close(imp)
                tracking = nil
            } else {
                tracking = imp
            }
        }
    }

    private func close(_ impact: Impact) {
        impacts.append(impact)
        if impacts.count > maxImpacts {
            impacts.removeFirst(impacts.count - maxImpacts)
        }
        if calibrating { calibrationSamples.append(impact.peak) }
    }

    // MARK: - scoring

    private func gateFor(sens: Double, floor: Double) -> Double {
        max(minGate, floor * 2.5 / sens, 0.6 * softCeiling / sens)
    }

    private func score(forPeak peak: Double) -> Double {
        let lo = softCeiling / sensitivity
        let hi = max(slamFloor / sensitivity, lo * 1.3)
        let x = (peak - lo) / (hi - lo)
        return smoothstep(x)
    }

    /// Continuous 0...1 with a soft knee at both ends.
    private func smoothstep(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return x * x * (3 - 2 * x)
    }

    // MARK: - query

    /// Correlate a keystroke at `when` with the sensor stream.
    ///
    /// The chassis vibration starts slightly after the key event, so this waits a
    /// few milliseconds for the impact to develop instead of guessing from the
    /// first sample. Returns nil when nothing is attributable to this keystroke.
    func reading(at when: UInt64) -> Reading? {
        let gateDeadlineMs = 6.0
        var best: Impact?

        let deadline = machIntervalMs(when, machNow()) + gateDeadlineMs
        while true {
            lock.lock()
            if let candidate = impacts.first(where: { imp in
                !imp.consumed && machIntervalMs(imp.start, when) > -4.0
                    && machIntervalMs(imp.start, when) < deadline
            }) {
                best = candidate
            }
            lock.unlock()

            if best != nil {
                /* give the impact a moment to reach its true peak */
                usleep(800)
                lock.lock()
                var fresh: Impact?
                if let best { fresh = impacts.first(where: { $0.start == best.start }) }
                if let fresh {
                    if let idx = impacts.firstIndex(where: { $0.start == fresh.start }) {
                        impacts[idx].consumed = true
                    }
                }
                lock.unlock()
                if let fresh {
                    return Reading(score: fresh.score, impact: fresh, fromSensor: true)
                }
            }

            if machIntervalMs(when, machNow()) >= deadline { return nil }
            usleep(250)
        }
    }

    private func machNow() -> UInt64 { UInt64(mach_absolute_time()) }

    private func ticks(forMs ms: Double) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        if info.numer == 0 { return UInt64(ms * 1_000_000) }
        /* ticks = ms * 1e6 ns/ms * denom / numer */
        return UInt64((ms * 1_000_000.0 * Double(info.denom)) / Double(info.numer))
    }

    func telemetry() -> Telemetry {
        lock.lock()
        defer { lock.unlock() }
        var t = Telemetry()
        t.noiseFloor = noiseFloor
        t.lastMagnitude = lastMagnitude
        t.lastScore = impacts.last?.score ?? 0
        t.magnitudeHistory = magnitudeHistory
        t.recentImpacts = impacts.suffix(8).map(\.score)
        t.impactCount = impacts.count
        t.calibrating = calibrating
        t.calibrationSamples = calibrationSamples.count
        if calibrating && calibrationStart > 0 {
            t.calibrationProgress = min(1.0, machMs(machNow() &- calibrationStart) / calibrationDurationMs)
        }
        return t
    }

    // MARK: - calibration

    func beginCalibration() {
        lock.lock()
        calibrationSamples.removeAll(keepingCapacity: true)
        calibrationStart = machNow()
        calibrating = calibrationSamples.isEmpty
        lock.unlock()
    }

    struct CalibrationResult {
        var softCeiling: Double
        var slamFloor: Double
        var samples: Int
        var weakest: Double
        var strongest: Double
    }

    @discardableResult
    func endCalibration() -> CalibrationResult? {
        lock.lock()
        defer { lock.unlock() }
        calibrating = false
        let sorted = calibrationSamples.sorted()
        guard sorted.count >= 12 else { return nil }

        let soft = max(self.percentile(sorted, 0.35), softCeiling * 0.6)
        let slam = max(self.percentile(sorted, 0.92), soft * 1.8)
        softCeiling = soft
        slamFloor = slam
        calibrationSamples.removeAll(keepingCapacity: true)
        return CalibrationResult(softCeiling: soft, slamFloor: slam,
                                 samples: sorted.count,
                                 weakest: sorted.first ?? 0, strongest: sorted.last ?? 0)
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded())))
        return sorted[idx]
    }

    func resetCalibration() {
        lock.lock()
        defer { lock.unlock() }
        calibrating = false
        calibrationSamples.removeAll(keepingCapacity: true)
        softCeiling = 0.0075
        slamFloor = 0.14
    }

    /// Drops all state: history, gravity estimate and detected impacts.
    /// Used by the synthetic self test.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        impacts.removeAll(keepingCapacity: true)
        magnitudeHistory.removeAll(keepingCapacity: true)
        calibrationSamples.removeAll(keepingCapacity: true)
        calibrating = false
        gravityReady = false
        gravity = SIMD3<Double>(0, 0, 0)
        tracking = nil
        lastImpactEnd = 0
        lastSampleTime = 0
        lastMagnitude = 0
        noiseFloor = 0.0015
    }

    /// Number of impacts held in the ring, for the self test.
    var recordedImpactCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return impacts.count
    }

    /// The peaks of the detected impacts, oldest first, for the self test.
    var recordedImpacts: [(score: Double, peak: Double)] {
        lock.lock()
        defer { lock.unlock() }
        return impacts.map { (score: $0.score, peak: $0.peak) }
    }
}
