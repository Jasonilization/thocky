import AppKit
import Combine
import Foundation
import ThockAudio

/// Central application state: the sensor, the force detector and the audio
/// engine wired together behind the menu bar.
///
/// Threading:
///  * sensor callback (CFRunLoop thread, ~800 Hz) -> detector
///  * keyboard tap callback (run loop thread)        -> force lookup -> engine
///  * a 20 Hz timer on main                          -> UI telemetry
final class AppState: ObservableObject {
    static let tierLabels = ["Soft", "Medium", "Hard", "Slam"]

    // MARK: published state

    @Published var isEnabled = Settings.enabled
    @Published var volume: Double = Double(Settings.volume) { didSet { setVolume(Double(volume)) } }
    @Published var sensitivity: Double = Settings.sensitivity { didSet { applySensitivity() } }
    @Published var selectedPackID = Settings.packID
    @Published var packs: [PackInfo] = []
    @Published var releaseSounds = Settings.releaseSounds
    @Published var fallbackForce = Settings.fallbackForce
    @Published var idlePause = Settings.idlePause

    @Published var sensorAvailable = false
    @Published var sensorRunning = false
    @Published var sensorRateHz: Double = 0
    @Published var tapAuthorized = false

    @Published var telemetry = ForceDetector.Telemetry()
    @Published var audioRate = 48000
    @Published var audioBuffer = 128
    @Published var audioLatency = 0.0
    @Published var renderCalls: UInt64 = 0
    @Published var dropped: UInt64 = 0

    @Published var keysPlayed = 0
    @Published var lastForce: Double = 0
    @Published var lastTier = 0
    @Published var lastFromSensor = true
    @Published var isCalibrating = false
    @Published var calibrationMessage: String?
    @Published var notice: String?

    // MARK: engine

    let sensor = MotionSensor()
    let detector = ForceDetector()
    let engine = AudioEngine()
    var tap: KeyboardTap?

    private var timers: [Timer] = []
    private let statsLock = NSLock()
    private var played = 0
    private var lastScore = 0.0
    private var lastTierIdx = 0
    private var fromSensor = true
    private var lastKeyTime: UInt64?
    private var strikes = 0

    // MARK: init

    init() {
        volume = Double(Settings.volume)
        sensitivity = Settings.sensitivity
        detector.softCeiling = Settings.softCeiling
        detector.slamFloor = Settings.slamFloor
        detector.sensitivity = sensitivity
        sensor.onSample = { [weak self] sample in self?.detector.ingest(sample) }

        packs = PackInfo.availablePacks()
        if packs.isEmpty {
            Log.error("no sound packs found in \(PackInfo.searchRoots().map { $0.path }.joined(separator: ", "))")
        }
        Log.info("keystrike starting up; \(packs.count) packs available")

        /* enable() owns its timers, so it can start (or restart) them safely. */
        if isEnabled { enable() } else { startTimers() }

        /* Headless checks. KS_SELFTEST=1 plays a scripted stream (needs a
           working audio output); KS_FORCE_TEST=1 feeds synthetic accelerometer
           data through the detector and reports the scores it scores. */
        let env = ProcessInfo.processInfo.environment
        if env["KS_FORCE_TEST"] != nil { syntheticForceTest() }
        if env["KS_SELFTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                Log.info("selftest: playing scripted stream")
                self.simulateTyping(seconds: 4) {
                    let stats = self.engine.stats
                    Log.info(String(
                        format: "selftest done: renders=%llu voices=%llu dropped=%llu keys=%d",
                        stats.renderCalls, stats.voicesStarted, stats.dropped, self.played))
                }
            }
        }
    }

    deinit {
        for t in timers { t.invalidate() }
    }

    // MARK: enable / disable

    func enable() {
        isEnabled = true
        Settings.enabled = true

        for t in timers { t.invalidate() }
        timers.removeAll()

        if !engine.start() {
            notice = "Audio engine failed to start: \(engine.errorMessage ?? "unknown error")"
        }
        engine.setVolume(Float(volume))
        ensurePack()

        sensorAvailable = sensor.isAvailable
        if sensorAvailable {
            sensor.start()
            Log.info("SPU accelerometer started (rate target ~1 kHz)")
        } else {
            Log.info("no SPU accelerometer on this machine; force comes from typing rhythm")
        }
        sensorRunning = sensor.isRunning

        ensureTap()
        startTimers()
    }

    func disable() {
        isEnabled = false
        Settings.enabled = false
        shutDown()
    }

    /// Stops everything without touching preferences, so quitting does not
    /// silently disable the app for its next launch.
    func shutDown() {
        sensor.stop()
        sensorRunning = false
        tap?.destroy()
        tap = nil
        engine.stop()
        for t in timers { t.invalidate() }
        timers.removeAll()
    }

    func toggleEnabled() { isEnabled ? disable() : enable() }

    // MARK: tap

    func ensureTap() {
        guard isEnabled else { return }
        if tap != nil, tapAuthorized { return }
        let newTap = KeyboardTap(
            onKeyDown: { [weak self] keyCode, isRepeat in self?.handleKeyDown(keyCode, isRepeat: isRepeat) },
            onKeyUp: { [weak self] key in self?.handleKeyUp(key) },
            onStatusChange: { [weak self] ok in self?.tapAuthorized = ok })
        let made = newTap.createAndEnable()
        tap = newTap
        if !made {
            notice = "Keystrike needs Accessibility permission to hear your keyboard."
            Log.error("event tap creation failed")
        }
    }

    func requestAccessibility() {
        let ok = KeyboardTap.hasPermissionWithPrompt
        tapAuthorized = ok
        Log.info("accessibility prompt -> \(ok)")
        if ok { ensureTap() }
    }

    // MARK: key handling

    private func handleKeyDown(_ keyCode: CGKeyCode, isRepeat: Bool) {
        let now = UInt64(mach_absolute_time())
        let group = KeyMap.group(for: keyCode)
        let gain: Float = isRepeat ? 0.45 : 1.0

        var score: Double
        var sourceSensor = true
        if let reading = detector.reading(at: now) {
            score = reading.score
        } else {
            sourceSensor = false
            score = fallbackForce ? fallbackScore(at: now) : 0.35
        }

        let (lo, hi, mix) = Self.tiers(for: score)
        engine.play(group: group, tierLo: lo, tierHi: hi, mix: mix,
                    event: Int(KS_EVENT_PRESS), gain: gain)

        statsLock.lock()
        played += 1
        lastScore = score
        lastTierIdx = lo
        fromSensor = sourceSensor
        statsLock.unlock()
        strikes += 1
        lastKeyTime = now
    }

    private func handleKeyUp(_ keyCode: CGKeyCode) {
        guard releaseSounds else { return }
        let now = UInt64(mach_absolute_time())
        let group = KeyMap.group(for: keyCode)
        var score: Double = 0.3
        if let reading = detector.reading(at: now) { score = reading.score }
        let (lo, hi, mix) = Self.tiers(for: score * 0.6)
        engine.play(group: group, tierLo: lo, tierHi: hi, mix: mix,
                    event: Int(KS_EVENT_RELEASE), gain: 0.5)
    }

    /// Force tiers from a continuous 0...1 score; boundaries at 0.25/0.5/0.75.
    static func tiers(for score: Double) -> (lo: Int, hi: Int, mix: Float) {
        let x = max(0, min(1, score)) * 4.0
        let lo = Int(min(3, floor(x)))
        let hi = Int(min(3, lo + 1))
        let mix = Float(x - floor(x))
        return (lo, hi, mix)
    }

    /// Typing-rhythm estimate used when the accelerometer shows nothing that can
    /// be attributed to this keystroke (external keyboard, no SPU sensor).
    private func fallbackScore(at now: UInt64) -> Double {
        let interval: Double
        if let last = lastKeyTime { interval = machIntervalMs(last, now) }
        else { interval = 400 }

        var base: Double
        switch interval {
        case ..<60:       base = 0.86
        case 60..<130:    base = 0.52
        case 130..<260:   base = 0.34
        default:          base = 0.20
        }
        let seed = (UInt64(0x9E3779B9) &* UInt64(strikes + 1)) ^ (UInt64(strikes) &<< 13)
        let jitter = (Double(seed % 997) / 997.0 - 0.5) * 0.32
        return max(0.02, min(0.99, base + jitter))
    }

    // MARK: packs, volume, sensitivity

    func ensurePack() {
        if packs.isEmpty { packs = PackInfo.availablePacks() }
        guard let wanted = packs.first(where: { $0.id == selectedPackID }) ?? packs.first else { return }
        if engine.select(pack: wanted) { selectedPackID = wanted.id; Settings.packID = wanted.id }
    }

    func selectPack(id: String) {
        guard let pack = packs.first(where: { $0.id == id }) else { return }
        if engine.select(pack: pack) {
            selectedPackID = id
            Settings.packID = id
        }
    }

    func setVolume(_ v: Double) {
        let clamped = max(0, min(1, v))
        Settings.volume = Float(clamped)
        engine.setVolume(Float(clamped))
    }

    func applySensitivity() {
        Settings.sensitivity = sensitivity
        detector.sensitivity = sensitivity
    }

    func setSensitivity(_ v: Double) {
        sensitivity = max(0.4, min(2.5, v))
        applySensitivity()
    }

    // MARK: test playback

    func testPlay(tier: Int) {
        ensurePack()
        engine.play(group: KeyMap.generic, tierLo: tier, tierHi: tier, mix: 0,
                    event: Int(KS_EVENT_PRESS), gain: 1.0)
        usleep(120_000)
        engine.play(group: KeyMap.generic, tierLo: tier, tierHi: tier, mix: 0,
                    event: Int(KS_EVENT_RELEASE), gain: 0.5)
    }

    /// Plays a plausible typing stream, for machines where the event tap has no
    /// permission yet (or no sensor).
    func simulateTyping(seconds: Double = 4, onDone: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let end = Date().addingTimeInterval(seconds)
            var i = 0
            while Date() < end {
                let score = Double.random(in: 0.05...1.0)
                let (lo, hi, mix) = Self.tiers(for: score)
                let group = [KeyMap.generic, KeyMap.enter, KeyMap.space, KeyMap.backspace][i % 4]
                self.engine.play(group: group, tierLo: lo, tierHi: hi, mix: mix,
                                 event: Int(KS_EVENT_PRESS), gain: 1.0)
                if i % 2 == 0 {
                    usleep(40_000)
                    self.engine.play(group: group, tierLo: lo, tierHi: hi, mix: 0,
                                     event: Int(KS_EVENT_RELEASE), gain: 0.5)
                }
                i += 1
                usleep(UInt32.random(in: 55_000...135_000))
            }
            DispatchQueue.main.async { onDone?() }
        }
    }

    // MARK: mach time helpers

    private func machNow() -> UInt64 { UInt64(mach_absolute_time()) }

    private func machTicks(forMs ms: Double) -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return UInt64(ms * 1_000_000.0 * Double(info.denom) / Double(info.numer))
    }

    private func machMs(_ ticks: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(ticks) * Double(info.numer) / Double(info.denom) / 1_000_000.0
    }

    // MARK: calibration

    /// Feeds known synthetic impacts through the detector and logs the force
    /// scores they produce. The signal is a halved sine burst riding on a quiet
    /// desk, exactly the shape a keystroke produces in the chassis.
    func syntheticForceTest() {
        let bursts: [(label: String, peak: Double)] = [
            ("brushed key", 0.006),
            ("soft tap",    0.015),
            ("normal",      0.050),
            ("hard",        0.100),
            ("slam",        0.350)
        ]

        detector.reset()

        func ticks(_ ms: Double) -> UInt64 { machTicks(forMs: ms) }

        /* Bursts ride on the real resting vector, so the test works no matter
           how the laptop sits on the desk (the sensor's axes are arbitrary). */
        let rest = sensor.latest ?? MotionSensor.Sample(x: 0, y: 1, z: 0, machTime: 0)
        let restVec = SIMD3<Double>(rest.x, rest.y, rest.z)
        let axis = SIMD3<Double>(1, 0, 0)

        func feed(_ label: String, peak: Double, at offsetMs: Double) {
            /* quiet desk for 30 ms before the burst */
            for i in 0..<30 {
                let t = machNow() + ticks(offsetMs + Double(i))
                detector.ingest(MotionSensor.Sample(x: rest.x, y: rest.y, z: rest.z, machTime: t))
            }
            let start = offsetMs + 30
            for i in 0..<40 {
                let ms = start + Double(i)
                let env = sin(.pi * Double(i + 1) / 41.0)
                let pulse = restVec + axis * (peak * env)
                detector.ingest(MotionSensor.Sample(x: pulse.x, y: pulse.y, z: pulse.z,
                                                    machTime: machNow() + ticks(ms)))
            }
            Log.info("force test: fed \(label) peak=\(String(format: "%.3f", peak)) g")
        }

        Log.info("force test: quiet desk baseline for 250 ms")
        let t0 = machNow()
        detector.ingest(MotionSensor.Sample(x: rest.x, y: rest.y, z: rest.z, machTime: t0))
        var t = t0
        for _ in 0..<250 {
            t += ticks(1)
            detector.ingest(MotionSensor.Sample(x: rest.x, y: rest.y, z: rest.z, machTime: t))
        }

        for (i, burst) in bursts.enumerated() {
            feed(burst.label, peak: burst.peak, at: Double(i * 150))
            /* let the detector close the impact window */
            usleep(20_000)
            let tailBase = machNow() + ticks(Double(i * 150) + 70)
            var tail = tailBase
            for _ in 0..<30 {
                tail += ticks(1)
                detector.ingest(MotionSensor.Sample(x: rest.x, y: rest.y, z: rest.z, machTime: tail))
            }
        }

        let recorded = detector.recordedImpacts

        /* Match each injected burst to the impact it produced. Peaks far from
           any burst are real desk noise (fans, the machine being handled) and
           are reported as such rather than counted as misses. */
        var matched: [(label: String, expected: Double, peak: Double, score: Double)] = []
        var used = Array(repeating: false, count: recorded.count)
        for burst in bursts {
            guard let idx = recorded.enumerated().first(where: { pair in
                !used[pair.offset] && abs(pair.element.peak - burst.peak) < burst.peak * 0.6
            })?.offset else { continue }
            used[idx] = true
            let hit = recorded[idx]
            matched.append((burst.label, burst.peak, hit.peak, hit.score))
        }

        for (i, m) in matched.enumerated() {
            let tier = Self.tiers(for: m.score)
            Log.info(String(format: "  burst %d (%@): expected %.3f g, measured %.3f g, score %.2f, tier %d %@",
                            i + 1, m.label, m.expected, m.peak, m.score, tier.lo,
                            Self.tierLabels[tier.lo]))
        }
        let noise = recorded.enumerated().filter { !used[$0.offset] }
        for n in noise {
            Log.info(String(format: "  (desk noise: %.3f g, below the burst set)", n.element.peak))
        }
        Log.info(String(format: "force test: %d/%d bursts matched, %d desk-noise impacts",
                        matched.count, bursts.count, noise.count))

        guard matched.count == bursts.count else {
            Log.error("force test: FAIL - not every burst was detected")
            return
        }
        let scores = matched.map { $0.score }
        let monotonic = scores.sorted() == scores
        let sane = matched.allSatisfy { $0.peak > 0.004 && $0.score <= 1.0 }
        Log.info(monotonic && sane
                 ? "force test: PASS - scores rise monotonically with input force"
                 : "force test: FAIL - scores are not monotonic, or a peak is implausible")
    }

    func startCalibration() {
        guard sensorRunning else {
            calibrationMessage = "The accelerometer is not streaming, so there is nothing to calibrate."
            return
        }
        detector.beginCalibration()
        isCalibrating = true
        calibrationMessage = "Type normally for a few seconds — use real keystrokes, mixed soft and hard."
    }

    func finishCalibration() {
        isCalibrating = false
        guard let result = detector.endCalibration() else {
            calibrationMessage = "Not enough keystrokes captured — type for the full 8 seconds and try again."
            return
        }
        Settings.softCeiling = result.softCeiling
        Settings.slamFloor = result.slamFloor
        Settings.isCalibrated = true
        detector.softCeiling = result.softCeiling
        detector.slamFloor = result.slamFloor
        calibrationMessage = String(
            format: "Calibrated from %d keystrokes: soft ≤ %.3f g, slam ≥ %.3f g (weakest %.3f, strongest %.3f).",
            result.samples, result.softCeiling, result.slamFloor, result.weakest, result.strongest)
    }

    func resetCalibration() {
        detector.resetCalibration()
        Settings.softCeiling = 0.0075
        Settings.slamFloor = 0.14
        Settings.isCalibrated = false
        detector.softCeiling = Settings.softCeiling
        detector.slamFloor = Settings.slamFloor
        calibrationMessage = "Calibration reset to defaults."
    }

    // MARK: timers

    private func startTimers() {
        let telemetryTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.refreshTelemetry()
        }
        RunLoop.main.add(telemetryTimer, forMode: .common)
        timers.append(telemetryTimer)

        let slowTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.slowTick()
        }
        RunLoop.main.add(slowTimer, forMode: .common)
        timers.append(slowTimer)
    }

    private func refreshTelemetry() {
        telemetry = detector.telemetry()
        let stats = engine.stats
        renderCalls = stats.renderCalls
        dropped = stats.dropped
        if engine.isReady {
            audioRate = Int(engine.sampleRate)
            audioBuffer = engine.bufferFrames
            audioLatency = engine.latencyMs
        }
        sensorRateHz = sensor.sampleRateHz
        sensorRunning = sensor.isRunning

        statsLock.lock()
        keysPlayed = played
        lastForce = lastScore
        lastTier = lastTierIdx
        lastFromSensor = fromSensor
        statsLock.unlock()
    }

    private func slowTick() {
        guard isEnabled else { return }
        if idlePause { engine.idleTick() }
        if sensorRunning && !tapAuthorized && KeyboardTap.hasPermission { ensureTap() }

        let stats = engine.stats
        let tele = detector.telemetry()
        let peak = tele.magnitudeHistory.max() ?? 0
        Log.info(String(
            format: "heartbeat: renders=%llu voices=%llu dropped=%llu keys=%d sensor=%dHz samples=%lld mag=%.4f peak=%.4f noise=%.5f",
            stats.renderCalls, stats.voicesStarted, stats.dropped, played,
            Int(sensor.sampleRateHz), sensor.sampleCount,
            tele.lastMagnitude, peak, tele.noiseFloor))
    }
}
