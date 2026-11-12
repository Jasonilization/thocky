import AppKit
import CoreGraphics

/// Global keyboard event tap.
///
/// This is the only part of the app that sees key events at all. It needs
/// Accessibility permission, never sees typed content beyond keyCode, and does
/// not block or modify the event stream.
final class KeyboardTap {
    private let onKeyDown: (CGKeyCode, Bool) -> Void
    private let onKeyUp: (CGKeyCode) -> Void
    private let onStatusChange: (Bool) -> Void

    private var machPort: CFMachPort?
    private var thread: Thread?
    private var boxedSelf: UnsafeMutableRawPointer?
    private(set) var isEnabled = false
    private(set) var lastError: String?

    init(onKeyDown: @escaping (CGKeyCode, Bool) -> Void,
         onKeyUp: @escaping (CGKeyCode) -> Void,
         onStatusChange: @escaping (Bool) -> Void) {
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
        self.onStatusChange = onStatusChange
    }

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
            options: .defaultTap,
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
        if let machPort {
            CGEvent.tapEnable(tap: machPort, enable: false)
            CFMachPortInvalidate(machPort)
            self.machPort = nil
        }
        isEnabled = false
        onStatusChange(false)
        /* the run loop thread exits when its source is invalidated */
        if let boxedSelf {
            Unmanaged<KeyboardTap>.fromOpaque(boxedSelf).release()
            self.boxedSelf = nil
        }
    }

    private func runTapOnDedicatedThread(_ machPort: CFMachPort) {
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0)
        let t = Thread { [weak self] in
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .defaultMode)
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, source, .defaultMode)
            self?.isEnabled = false
        }
        t.name = "keystrike.tap"
        t.qualityOfService = .userInteractive
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
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// C shim: forwards CGEventTap callbacks into `KeyboardTap.handle`.
private let keyboardTapCallback: CGEventTapCallBack = { proxy, type, event, ctx in
    guard let ctx else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyboardTap>.fromOpaque(ctx).takeUnretainedValue()
    return tap.handle(type: type, event: event) ?? Unmanaged.passUnretained(event)
}
