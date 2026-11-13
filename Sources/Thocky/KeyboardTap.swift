import AppKit
import CoreGraphics

/// Global keyboard event tap.
///
/// This is the only part of the app that sees key events at all. It needs
/// Accessibility permission, never sees typed content beyond keyCode, and does
/// not block or modify the event stream. The tap is listen-only, so a slow
/// force reading cannot stall the keys the user is actually typing.
final class KeyboardTap {
    private let onKeyDown: (CGKeyCode, Bool) -> Void
    private let onKeyUp: (CGKeyCode) -> Void
    private let onStatusChange: (Bool) -> Void

    private var machPort: CFMachPort?
    private var runLoop: CFRunLoop?
    private let loopLock = NSLock()
    private var thread: Thread?
    private var boxedSelf: UnsafeMutableRawPointer?
    private(set) var isEnabled = false
    private(set) var lastError: String?
    private var heldModifiers = Set<CGKeyCode>()
    private var lastCaps: Date?

    init(onKeyDown: @escaping (CGKeyCode, Bool) -> Void,
         onKeyUp: @escaping (CGKeyCode) -> Void,
         onStatusChange: @escaping (Bool) -> Void) {
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
        self.onStatusChange = onStatusChange
    }

    deinit { destroy() }

    /// Accessibility permission, without prompting.
    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// Prompts the user if needed; returns current state.
    static var hasPermissionWithPrompt: Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// `kCGEventTapDisabledByUserInput`, which has no Swift name.
    private static let disabledByUser = CGEventType(rawValue: 0xFFFFFFFF)!

    func createAndEnable() -> Bool {
        destroy()

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << Self.disabledByUser.rawValue)

        let box = UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque())
        boxedSelf = box

        guard let machPort = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: keyboardTapCallback,
            userInfo: box
        ) else {
            Unmanaged<KeyboardTap>.fromOpaque(box).release()
            boxedSelf = nil
            lastError = "Failed to create the event tap. Grant Accessibility permission."
            isEnabled = false
            onStatusChange(false)
            return false
        }
        self.machPort = machPort
        runTapOnDedicatedThread(machPort)
        isEnabled = true
        lastError = nil
        onStatusChange(true)
        return true
    }

    func destroy() {
        let port = machPort
        machPort = nil
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        let loop = takeRunLoop()
        if let loop { CFRunLoopStop(loop) }
        thread = nil
        heldModifiers.removeAll()
        if isEnabled {
            isEnabled = false
            onStatusChange(false)
        }
        if let boxedSelf {
            self.boxedSelf = nil
            Unmanaged<KeyboardTap>.fromOpaque(boxedSelf).release()
        }
    }

    private func takeRunLoop() -> CFRunLoop? {
        loopLock.lock()
        defer { loopLock.unlock() }
        let loop = runLoop
        runLoop = nil
        return loop
    }

    private func storeRunLoop(_ loop: CFRunLoop) {
        loopLock.lock()
        runLoop = loop
        loopLock.unlock()
    }

    private func runTapOnDedicatedThread(_ machPort: CFMachPort) {
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0)
        let t = Thread { [weak self] in
            guard let runLoop = CFRunLoopGetCurrent() else { return }
            self?.storeRunLoop(runLoop)
            if let source {
                CFRunLoopAddSource(runLoop, source, .defaultMode)
            }
            CFRunLoopRun()
            if let source {
                CFRunLoopRemoveSource(runLoop, source, .defaultMode)
            }
            self?.isEnabled = false
        }
        t.name = "thocky.tap"
        t.qualityOfService = QualityOfService.userInteractive
        thread = t
        t.start()
    }

    /// Handled on the tap thread.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, Self.disabledByUser:
            if let machPort, !CGEvent.tapIsEnabled(tap: machPort) {
                CGEvent.tapEnable(tap: machPort, enable: true)
            }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            onKeyDown(keyCode, isRepeat)
            return Unmanaged.passUnretained(event)
        case .keyUp:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            onKeyUp(keyCode)
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            handleFlags(event)
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Shift, control, option, command and fn arrive as `flagsChanged`, not as
    /// key down / key up. Caps lock only reports the toggle, so it is a click.
    private func handleFlags(_ event: CGEvent) {
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if code == 57 {
            let now = Date()
            if let lastCaps, now.timeIntervalSince(lastCaps) < 0.08 { return }
            lastCaps = now
            onKeyDown(code, false)
            onKeyUp(code)
            return
        }
        let down: Bool
        if let bit = Self.deviceBit(for: code) {
            down = (event.flags.rawValue & bit) != 0
        } else if code == 63 {
            down = event.flags.contains(.maskSecondaryFn)
        } else {
            return
        }
        let was = heldModifiers.contains(code)
        if down && !was {
            heldModifiers.insert(code)
            onKeyDown(code, false)
        } else if !down && was {
            heldModifiers.remove(code)
            onKeyUp(code)
        }
    }

    /// Device-dependent modifier bits from `NSEvent` / `IOLLEvent.h`.
    /// Left and right share a public flag, so the side has to come from these.
    private static func deviceBit(for keyCode: CGKeyCode) -> UInt64? {
        switch Int(keyCode) {
        case 56: return 0x0002  // left shift
        case 60: return 0x0004  // right shift
        case 59: return 0x0001  // left control
        case 62: return 0x2000  // right control
        case 58: return 0x0020  // left option
        case 61: return 0x0040  // right option
        case 55: return 0x0008  // left command
        case 54: return 0x0010  // right command
        default: return nil
        }
    }
}

/// C shim: forwards CGEventTap callbacks into `KeyboardTap.handle`.
/// The extra retain keeps the tap alive if `destroy` races a callback.
private let keyboardTapCallback: CGEventTapCallBack = { _, type, event, ctx in
    guard let ctx else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyboardTap>.fromOpaque(ctx).takeUnretainedValue()
    let hold = Unmanaged.passRetained(tap)
    defer { hold.release() }
    return tap.handle(type: type, event: event) ?? Unmanaged.passUnretained(event)
}
