import Foundation

/// Persisted preferences. Kept deliberately tiny: everything lives in UserDefaults
/// under one domain so the values survive app updates and are easy to inspect.
enum Settings {
    private static let defaults = UserDefaults.standard

    enum Key {
        static let enabled        = "keystrike.enabled"
        static let volume         = "keystrike.volume"
        static let sensitivity    = "keystrike.sensitivity"
        static let packID         = "keystrike.pack"
        static let releaseSounds  = "keystrike.releaseSounds"
        static let softCeiling    = "keystrike.softCeiling"
        static let slamFloor      = "keystrike.slamFloor"
        static let calibrated     = "keystrike.calibrated"
        static let idlePause      = "keystrike.idlePause"
        static let launchAtLogin  = "keystrike.launchAtLogin"
        static let fallbackMode   = "keystrike.fallbackForce"
    }

    static var enabled: Bool {
        get { defaults.object(forKey: Key.enabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }
    static var volume: Float {
        get { (defaults.object(forKey: Key.volume) as? Float) ?? 0.8 }
        set { defaults.set(newValue, forKey: Key.volume) }
    }
    static var sensitivity: Double {
        get { (defaults.object(forKey: Key.sensitivity) as? Double) ?? 1.0 }
        set { defaults.set(newValue, forKey: Key.sensitivity) }
    }
    static var packID: String {
        get { defaults.string(forKey: Key.packID) ?? "cream" }
        set { defaults.set(newValue, forKey: Key.packID) }
    }
    static var releaseSounds: Bool {
        get { defaults.object(forKey: Key.releaseSounds) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.releaseSounds) }
    }
    static var softCeiling: Double {
        get { (defaults.object(forKey: Key.softCeiling) as? Double) ?? 0.0075 }
        set { defaults.set(newValue, forKey: Key.softCeiling) }
    }
    static var slamFloor: Double {
        get { (defaults.object(forKey: Key.slamFloor) as? Double) ?? 0.14 }
        set { defaults.set(newValue, forKey: Key.slamFloor) }
    }
    static var isCalibrated: Bool {
        get { defaults.object(forKey: Key.calibrated) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.calibrated) }
    }
    static var idlePause: Bool {
        get { defaults.object(forKey: Key.idlePause) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.idlePause) }
    }
    static var launchAtLogin: Bool {
        get { defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }
    /// Plays a plausible force variation even when no accelerometer is available
    /// (Bluetooth keyboards, desktops, MacBook Airs without the SPU sensor).
    static var fallbackForce: Bool {
        get { defaults.object(forKey: Key.fallbackMode) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.fallbackMode) }
    }
}
