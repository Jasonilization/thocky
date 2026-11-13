import Foundation
import ThockSPU

/// Wraps the undocumented AppleSPU accelerometer (`AppleSPUHIDDevice`).
///
/// Samples arrive on the sensor's own CFRunLoop thread at ~800-1000 Hz and are
/// pushed into a fixed-size ring buffer. The force detector drains that ring, so
/// a keystroke can be correlated with the chassis vibration it produced.
final class MotionSensor {
    /// Raw accelerometer sample, in g, stamped when it was handled.
    struct Sample {
        var x: Double
        var y: Double
        var z: Double
        var machTime: UInt64
    }

    private let capacity = 4096                  /* ~4 s at 1 kHz */
    private var buffer: [Sample]
    private var writeIndex = 0
    private var count = 0
    private let lock = NSLock()
    private var retainedSelf: UnsafeMutableRawPointer?

    private(set) var isRunning = false
    private(set) var sampleRateHz: Double = 0
    private(set) var sampleCount: UInt64 = 0
    private(set) var lastError: String?

    init() {
        buffer = Array(repeating: Sample(x: 0, y: 0, z: 0, machTime: 0), count: capacity)
    }

    deinit { stop() }

    var isAvailable: Bool { ks_spu_available() != 0 }

    // MARK: - lifecycle

    func start() {
        guard !isRunning else { return }
        guard isAvailable else {
            lastError = String(cString: ks_spu_error())
            return
        }

        let box = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque())
        let cb: ks_spu_callback = { sample, ctx in
            guard let ctx, let sample else { return }
            let sensor = Unmanaged<MotionSensor>.fromOpaque(ctx).takeUnretainedValue()
            sensor.ingest(sample.pointee)
        }

        if ks_spu_start(cb, box) == 0 {
            Unmanaged<MotionSensor>.fromOpaque(box).release()
            lastError = String(cString: ks_spu_error())
            return
        }
        retainedSelf = box
        isRunning = true
        lastError = nil
    }

    func stop() {
        guard isRunning else { return }
        ks_spu_stop()
        isRunning = false
        if let retainedSelf {
            Unmanaged<MotionSensor>.fromOpaque(retainedSelf).release()
            self.retainedSelf = nil
        }
    }

    // MARK: - sample intake (sensor thread)

    /// Set by the app to feed samples into the force detector.
    var onSample: ((Sample) -> Void)?

    fileprivate func ingest(_ s: ks_spu_sample_t) {
        let sample = Sample(x: Double(s.x) / 65536.0,
                            y: Double(s.y) / 65536.0,
                            z: Double(s.z) / 65536.0,
                            machTime: s.mach_time)
        append(sample)
        onSample?(sample)
        let rate = ks_spu_sample_rate_hz()
        if rate > 0 { sampleRateHz = rate }
    }

    private func append(_ s: Sample) {
        lock.lock()
        buffer[writeIndex] = s
        writeIndex = (writeIndex + 1) % capacity
        if count < capacity { count += 1 }
        sampleCount += 1
        lock.unlock()
    }

    // MARK: - reader API (any thread)

    /// Newest sample, if any.
    var latest: Sample? {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return nil }
        return buffer[(writeIndex - 1 + capacity) % capacity]
    }

    /// The most recent `n` samples, oldest first.
    func recent(_ n: Int) -> [Sample] {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return [] }
        let take = min(n, count)
        var out = [Sample]()
        out.reserveCapacity(take)
        let start = (writeIndex - take + capacity) % capacity
        for i in 0..<take { out.append(buffer[(start + i) % capacity]) }
        return out
    }

    func bufferedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func resetRing() {
        lock.lock()
        count = 0
        writeIndex = 0
        lock.unlock()
    }
}

// MARK: - mach time helpers

/// Mach ticks -> milliseconds, for comparing stamps taken in this process.
func machMs(_ ticks: UInt64) -> Double {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let nanos = Double(ticks) * Double(info.numer) / Double(info.denom)
    return nanos / 1_000_000.0
}

func machIntervalMs(_ from: UInt64, _ to: UInt64) -> Double {
    guard to >= from else { return 0 }
    return machMs(to - from)
}

/// Signed milliseconds from `from` to `to`. Negative when `to` is earlier.
/// `machIntervalMs` collapses that case to zero, which made the force matcher
/// treat "impact has not started yet" as "impact started this instant".
func machSignedIntervalMs(_ from: UInt64, _ to: UInt64) -> Double {
    if to >= from { return machMs(to &- from) }
    return -machMs(from &- to)
}
