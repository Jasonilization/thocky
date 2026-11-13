import Foundation

/// A sound pack: a directory of WAVs plus the `pack.json` metadata beside them.
struct PackInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let family: String
    let directory: URL
    var clipCount: Int

    static let builtinOrder = ["cream", "holypanda", "blackink", "topre", "mxblue"]

    /// Where the packs live: the app bundle first, then dev-tree fallbacks so
    /// `swift run thocky` works without building a bundle.
    static func searchRoots() -> [URL] {
        var roots: [URL] = []

        if let env = ProcessInfo.processInfo.environment["KS_PACKS"], !env.isEmpty {
            roots.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        if let res = Bundle.main.resourceURL {
            roots.append(res.appendingPathComponent("Packs", isDirectory: true))
        }
        // <repo>/.build/.../thocky -> <repo>/Resources/Packs
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        for up in 1...5 {
            var url = exe
            for _ in 0..<up { url = url.deletingLastPathComponent() }
            roots.append(url.appendingPathComponent("Resources/Packs", isDirectory: true))
        }
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                         isDirectory: true).appendingPathComponent("Resources/Packs", isDirectory: true))
        return roots
    }

    /// All packs found across the search roots, de-duplicated by id.
    static func availablePacks() -> [PackInfo] {
        var byID: [String: PackInfo] = [:]
        for root in searchRoots() {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for dir in entries where dir.hasDirectoryPath {
                let id = dir.lastPathComponent
                if byID[id] != nil { continue }
                if let info = Self.load(from: dir, id: id) { byID[id] = info }
            }
        }
        return byID.values.sorted { a, b in
            let ai = builtinOrder.firstIndex(of: a.id) ?? builtinOrder.count
            let bi = builtinOrder.firstIndex(of: b.id) ?? builtinOrder.count
            if ai != bi { return ai < bi }
            return a.name < b.name
        }
    }

    private static func load(from dir: URL, id: String) -> PackInfo? {
        let metaURL = dir.appendingPathComponent("pack.json")
        var name = id.capitalized
        var family = "linear"
        if let data = try? Data(contentsOf: metaURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let n = json["name"] as? String { name = n }
            if let f = json["family"] as? String { family = f }
        }
        let clips = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]))?.filter { $0.pathExtension == "wav" }.count ?? 0
        guard clips > 0 else { return nil }
        return PackInfo(id: id, name: name, family: family, directory: dir, clipCount: clips)
    }

    var familyLabel: String {
        family.capitalized
    }
}
