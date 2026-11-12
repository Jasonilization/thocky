import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (macOS 13+).
enum LaunchAtLogin {
    static var isSupported: Bool {
        if #available(macOS 13, *) { return true }
        return false
    }

    static func setEnabled(_ enabled: Bool, completion: @escaping (Error?) -> Void) {
        guard #available(macOS 13, *) else {
            completion(LaunchAtLoginError.unsupported)
            return
        }
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .enabled { completion(nil); return }
                try service.register()
            } else {
                if service.status != .enabled { completion(nil); return }
                try service.unregister()
            }
            completion(nil)
        } catch {
            completion(error)
        }
    }

    static var status: String {
        guard #available(macOS 13, *) else { return "unsupported" }
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "off"
        case .notFound: return "not found"
        case .requiresApproval: return "requires approval"
        default: return "unknown"
        }
    }

    enum LaunchAtLoginError: LocalizedError {
        case unsupported
        var errorDescription: String? { "Launch at login requires macOS 13 or later." }
    }
}
