import Foundation

/// Where scans go: the Desktop, or another folder (a network share, for example) when the scan panel's
/// checkbox is ticked. The folder is picked with the panel's Choose… button and kept in the defaults key
/// `otherFolder`.
enum Folders {
    static let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]

    static var other: URL? {
        guard let path = UserDefaults.standard.string(forKey: "otherFolder"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Whether the folder is there, decided without contacting a network server (a share whose server has gone
    /// away can block file calls for a long time). A folder under /Volumes needs its volume mounted: an unmounted
    /// share can leave its empty mount point behind.
    static func isReachable(_ folder: URL) -> Bool {
        let parts = folder.standardizedFileURL.pathComponents   // ["/", "Volumes", "scans", ...]
        guard parts.count >= 3, parts[1] == "Volumes" else { return FileManager.default.fileExists(atPath: folder.path) }
        let mountPoint = "/Volumes/" + parts[2]
        var mounts: UnsafeMutablePointer<statfs>?
        let count = Int(getmntinfo(&mounts, MNT_NOWAIT))
        guard count > 0, let mounts else { return false }
        return (0..<count).contains { i in
            withUnsafeBytes(of: mounts[i].f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == mountPoint
        }
    }

    /// Writes a scan with `write` to a local temporary file, then puts it into `folder` as
    /// "Scan 2026-11-02 at 03.12.45.jpg" (named like macOS screenshots). If the folder cannot take it (share not
    /// connected or gone during the copy, no permission), the scan goes to the Desktop instead: `fellBack`.
    static func store(extension ext: String, in folder: URL, write: (URL) throws -> Void) throws -> (url: URL, fellBack: Bool) {
        let files = FileManager.default
        let temporary = files.temporaryDirectory.appendingPathComponent("z300-\(UUID().uuidString).\(ext)")
        defer { try? files.removeItem(at: temporary) }
        try write(temporary)
        let elsewhere = folder.standardizedFileURL.path != desktop.standardizedFileURL.path
        if elsewhere {
            if isReachable(folder) {
                let url = newFile(in: folder, extension: ext)
                do {
                    try files.copyItem(at: temporary, to: url)
                    return (url, false)
                } catch {
                    log("cannot save to \(folder.path), using the Desktop: \(error)")
                    try? files.removeItem(at: url)   // a partial copy
                }
            } else {
                log("\(folder.path) is not connected, using the Desktop")
            }
        }
        let url = newFile(in: desktop, extension: ext)
        try files.moveItem(at: temporary, to: url)
        return (url, elsewhere)
    }

    private static func newFile(in folder: URL, extension ext: String) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = f.string(from: Date())
        var url = folder.appendingPathComponent("Scan \(stamp).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("Scan \(stamp) \(n).\(ext)")
            n += 1
        }
        return url
    }
}
