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

    /// One keystroke as the app experienced it: what force it measured, which
    /// tier that landed on, and where the key sits. The visualiser and the
    /// recent-keystroke list both read this.
    struct KeyHit: Identifiable {
        var id = UUID()
        var keyCode: CGKeyCode
        var label: String
        var group: Int
        var tier: Int
        var score: Double
        var peakG: Double
        var pan: Float
        var dist: Float
        var measured: Bool
        var at: Date = Date()

        var tierLabel: String { AppState.tierLabels[min(3, max(0, tier))] }
    }

    /// A press or release for the on-screen keyboard. `serial` changes on every
    /// event so a repeated key still notifies the view.
    struct KeyPulse: Equatable {
        var serial: UInt64
        var keyCode: CGKeyCode
        var down: Bool
        var travel: Double
        var tier: Int
        var measured: Bool
    }

    /// Recent keystrokes, newest first, for the "what just happened" list.
    @Published var recentHits: [KeyHit] = []
    /// The keystroke currently being animated.
    @Published var activeHit: KeyHit?
    /// Latest press or release. The keyboard view springs the matching cap.
    @Published var keyPulse: KeyPulse?
    /// Settings asks the app delegate to open the keyboard window.
    var presentKeyboard: (() -> Void)?

    private var pulseSerial: UInt64 = 0
    private let pulseLock = NSLock()

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

    /// True when the tap object exists but no key events arrive while the
    /// accelerometer does hear impacts: macOS is dropping them, which means the
    /// Accessibility grant belongs to a different copy of the app.
    @Published var tapDeaf = false

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
        Log.info("thocky starting up; \(packs.count) packs available")

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

        /* macOS will only show this dialog a few times ever, so ask once per
           launch while the grant is missing; the retry timer below picks it up
           the moment the user toggles the switch. */
        if !KeyboardTap.hasPermission {
            Log.info("no Accessibility trust for this binary yet; prompting")
            requestAccessibility()
        }
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
            notice = "Thocky needs Accessibility permission to hear your keyboard."
            Log.error("event tap creation failed " +
                      "(AXIsProcessTrusted=\(KeyboardTap.hasPermission), " +
                      "bundle=\(Bundle.main.bundleIdentifier ?? "none"), " +
                      "exec=\(Bundle.main.executablePath ?? "none"))")
        } else {
            Log.info("event tap created (\(Bundle.main.executablePath ?? "?"))")
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
        var peakG = 0.0
        if let reading = detector.reading(at: now) {
            score = reading.score
            peakG = reading.impact.peak
        } else {
            sourceSensor = false
            score = fallbackForce ? fallbackScore(at: now) : 0.35
        }

        let (lo, hi, mix) = Self.tiers(for: score)
        let shown = mix >= 0.5 ? hi : lo
        let pan = KeyLayout.pan(for: keyCode)
        let dist = KeyLayout.distance(for: keyCode)
        engine.play(group: group, tierLo: lo, tierHi: hi, mix: mix,
                    event: Int(KS_EVENT_PRESS), gain: gain, pan: pan, dist: dist)

        record(hit: KeyHit(keyCode: keyCode,
                           label: keyLabel(keyCode),
                           group: group, tier: shown, score: score, peakG: peakG,
                           pan: pan, dist: dist, measured: sourceSensor))

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
        publishRelease(keyCode)
        guard releaseSounds else { return }
        let now = UInt64(mach_absolute_time())
        let group = KeyMap.group(for: keyCode)
        var score: Double = 0.3
        if let reading = detector.reading(at: now) { score = reading.score }
        let (lo, hi, mix) = Self.tiers(for: score * 0.6)
        let pan = KeyLayout.pan(for: keyCode)
        let dist = KeyLayout.distance(for: keyCode)
        engine.play(group: group, tierLo: lo, tierHi: hi, mix: mix,
                    event: Int(KS_EVENT_RELEASE), gain: 0.5, pan: pan, dist: dist)
    }

    private func keyLabel(_ keyCode: CGKeyCode) -> String {
        if let label = KeyLayout.position(for: keyCode)?.label, !label.isEmpty { return label }
        return KeyMap.name(for: keyCode)
    }

    /// Records a keystroke on the main thread for the UI, and sinks the keycap.
    private func record(hit: KeyHit) {
        let travel = 0.34 + 0.66 * min(1, max(0, hit.score))
        let pulse = nextPulse(code: hit.keyCode, down: true, travel: travel,
                              tier: hit.tier, measured: hit.measured)
        onMain { [weak self] in
            guard let self else { return }
            self.activeHit = hit
            self.keyPulse = pulse
            self.recentHits.insert(hit, at: 0)
            if self.recentHits.count > 12 { self.recentHits.removeLast() }
        }
    }

    private func publishRelease(_ keyCode: CGKeyCode) {
        let pulse = nextPulse(code: keyCode, down: false, travel: 0, tier: 0, measured: true)
        onMain { [weak self] in self?.keyPulse = pulse }
    }

    private func nextPulse(code: CGKeyCode, down: Bool, travel: Double, tier: Int, measured: Bool) -> KeyPulse {
        pulseLock.lock()
        pulseSerial &+= 1
        let serial = pulseSerial
        pulseLock.unlock()
        return KeyPulse(serial: serial, keyCode: code, down: down,
                        travel: travel, tier: tier, measured: measured)
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
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
        let tier = min(3, max(0, tier))
        let code: CGKeyCode = 49
        let score = [0.12, 0.40, 0.68, 0.96][tier]
        let pan = KeyLayout.pan(for: code)
        let dist = KeyLayout.distance(for: code)
        engine.play(group: KeyMap.space, tierLo: tier, tierHi: tier, mix: 0,
                    event: Int(KS_EVENT_PRESS), gain: 1.0, pan: pan, dist: dist)
        record(hit: KeyHit(keyCode: code, label: "space", group: KeyMap.space, tier: tier,
                           score: score, peakG: 0, pan: pan, dist: dist, measured: false))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            usleep(110_000)
            guard let self else { return }
            self.engine.play(group: KeyMap.space, tierLo: tier, tierHi: tier, mix: 0,
                             event: Int(KS_EVENT_RELEASE), gain: 0.5, pan: pan, dist: dist)
            self.publishRelease(code)
        }
    }

    /// Plays a plausible typing stream, for machines where the event tap has no
    /// permission yet (or no sensor).
    func simulateTyping(seconds: Double = 4, onDone: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let end = Date().addingTimeInterval(seconds)
            var i = 0
            let pattern: [(CGKeyCode, Int)] = [
                (3, KeyMap.generic), (38, KeyMap.generic), (40, KeyMap.generic),
                (12, KeyMap.generic), (49, KeyMap.space), (36, KeyMap.enter),
                (51, KeyMap.backspace), (1, KeyMap.generic)
            ]
            while Date() < end {
                let score = Double.random(in: 0.08...1.0)
                let (lo, hi, mix) = Self.tiers(for: score)
                let shown = mix >= 0.5 ? hi : lo
                let pair = pattern[i % pattern.count]
                let code = pair.0
                let group = pair.1
                let pan = KeyLayout.pan(for: code)
                let dist = KeyLayout.distance(for: code)
                self.engine.play(group: group, tierLo: lo, tierHi: hi, mix: mix,
                                 event: Int(KS_EVENT_PRESS), gain: 1.0, pan: pan, dist: dist)
                let label = KeyLayout.position(for: code)?.label ?? "key"
                self.record(hit: KeyHit(keyCode: code, label: label.isEmpty ? "space" : label,
                                        group: group, tier: shown, score: score, peakG: 0,
                                        pan: pan, dist: dist, measured: false))
                usleep(70_000)
                self.engine.play(group: group, tierLo: lo, tierHi: hi, mix: 0,
                                 event: Int(KS_EVENT_RELEASE), gain: 0.5, pan: pan, dist: dist)
                self.publishRelease(code)
                i += 1
                usleep(UInt32.random(in: 40_000...90_000))
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

        /* macOS happily *creates* an event tap for an untrusted process and then
           drops every event in silence: the app looks like it is listening and
           hears nothing at all. The accelerometer is an independent witness, so
           if impacts are arriving while keys are not, the tap is deaf and the
           Accessibility grant is attached to some other copy of the app. */
        if played == 0 && tele.impactCount >= 2 {
            if !tapDeaf {
                tapDeaf = true
                Log.warn("keyboard tap is deaf: \(tele.impactCount) impacts heard " +
                         "from the accelerometer, 0 key events from the tap")
            }
        } else if played > 0 && tapDeaf {
            tapDeaf = false
            Log.info("keyboard tap is hearing keys again")
        }

        Log.info(String(
            format: "heartbeat: renders=%llu voices=%llu dropped=%llu keys=%d sensor=%dHz samples=%lld mag=%.4f peak=%.4f noise=%.5f tap=%d trust=%d",
            stats.renderCalls, stats.voicesStarted, stats.dropped, played,
            Int(sensor.sampleRateHz), sensor.sampleCount,
            tele.lastMagnitude, peak, tele.noiseFloor,
            tapAuthorized ? 1 : 0, KeyboardTap.hasPermission ? 1 : 0))
    }
}
