import Foundation
import ThockAudio

/// Swift-side wrapper around the native Core Audio engine.
///
/// Owns the loaded pack and turns "play this force" into C trigger calls. All
/// the real-time work happens inside the C render callback; this class only
/// bridges and reports.
final class AudioEngine {
    struct Stats {
        var voicesStarted: UInt64 = 0
        var dropped: UInt64 = 0
        var activeVoices: UInt64 = 0
        var renderCalls: UInt64 = 0
    }

    private let lock = NSLock()
    private var packPointer: OpaquePointer?
    private(set) var currentPackID: String?

    var isReady = false
    var errorMessage: String?

    // MARK: lifecycle

    func start() -> Bool {
        if isReady { return true }
        guard ks_audio_start() != 0 else {
            errorMessage = String(cString: ks_audio_error())
            Log.error("audio start failed: \(errorMessage ?? "?")")
            return false
        }
        isReady = true
        errorMessage = nil
        Log.info("audio engine up: rate=\(Int(ks_audio_sample_rate()))Hz buffer=\(ks_audio_buffer_frames())f latency=\(String(format: "%.2f", ks_audio_latency_ms()))ms")
        return true
    }

    func stop() {
        guard isReady else { return }
        ks_audio_stop()
        isReady = false
        Log.info("audio engine stopped")
    }

    func shutdown() {
        stop()
        lock.lock()
        if let packPointer { ks_pack_release(packPointer); self.packPointer = nil }
        currentPackID = nil
        lock.unlock()
        ks_audio_shutdown()
    }

    func setVolume(_ v: Float) { ks_audio_set_volume(v) }
    var volume: Float { ks_audio_get_volume() }

    // MARK: packs

    func select(pack: PackInfo) -> Bool {
        let result = lock.withLock { () -> Bool in
            if currentPackID == pack.id, packPointer != nil { return true }
            let path = pack.directory.path
            let loaded = ks_pack_load(path)
            guard let loaded else {
                Log.error("pack load failed: \(path)")
                return false
            }
            if let old = packPointer { ks_pack_release(old) }
            packPointer = loaded
            currentPackID = pack.id
            Log.info("pack selected: \(pack.id) (\(ks_pack_clip_count(loaded)) clips)")
            return true
        }
        return result
    }

    // MARK: playback

    /// Trigger one clip. `tierLo`/`tierHi` + `mix` express continuous force: mix 0
    /// is fully tierLo, 1 is fully tierHi. `pan` places it in the stereo field and
    /// `dist` is 0 (front row) .. 1 (back row).
    func play(group: Int, tierLo: Int, tierHi: Int, mix: Float, event: Int, gain: Float,
              pan: Float = 0, dist: Float = 0) {
        lock.lock()
        let pack = packPointer
        lock.unlock()
        guard let pack else { return }
        ks_play(pack, Int32(group), Int32(tierLo), Int32(tierHi), mix, Int32(event), gain, pan, dist)
    }

    // MARK: diagnostics

    var stats: Stats {
        var v: UInt64 = 0, d: UInt64 = 0, a: UInt64 = 0, r: UInt64 = 0
        ks_audio_stats(&v, &d, &a, &r)
        return Stats(voicesStarted: v, dropped: d, activeVoices: a, renderCalls: r)
    }

    var sampleRate: Double { ks_audio_sample_rate() }
    var bufferFrames: Int { Int(ks_audio_buffer_frames()) }
    var latencyMs: Double { ks_audio_latency_ms() }

    /// Called periodically by the app; pauses rendering after sustained silence
    /// so the machine can sleep normally.
    func idleTick() { ks_audio_idle_pause() }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
