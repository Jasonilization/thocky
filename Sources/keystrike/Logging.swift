import Foundation

/// Minimal append-only file logger: `~/Library/Logs/Keystrike/keystrike.log`.
///
/// The app has no visible console, so everything that would normally go to
/// stdout/stderr lands here. `THOCK_DEBUG=1` (or the "Verbose logging" menu
/// item) adds the per-keystroke trace.
final class Log {
    static let shared = Log()
    static let verbose = ProcessInfo.processInfo.environment["THOCK_DEBUG"] != nil

    static func info(_ message: @autoclosure () -> String) { shared.write { message() } }
    static func debug(_ message: @autoclosure () -> String) { if verbose { shared.write { "[debug] \(message())" } } }
    static func error(_ message: @autoclosure () -> String) { shared.write { "[error] \(message())" } }
    static func clear() {
        try? FileManager.default.removeItem(atPath: shared.path)
    }

    private let queue = DispatchQueue(label: "keystrike.log", qos: .utility)
    private let path: String
    private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Keystrike", isDirectory: true)
        path = dir.appendingPathComponent("keystrike.log").path
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func write(_ message: () -> String) {
        let line = "\(dateFormatter.string(from: Date())) \(message())\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async { [path] in
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
    }
}
