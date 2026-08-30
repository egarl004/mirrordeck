import Foundation

/// Diagnostic log, enabled with:
///   defaults write com.emersongarland.MirrorDeck debugLog -bool true
/// Written to /tmp/mirrordeck.log because environment variables do not survive
/// launching through LaunchServices, and running the binary directly bypasses
/// the bundle's Info.plist and is killed for it.
enum DebugLog {
    static let enabled = UserDefaults.standard.bool(forKey: "debugLog")
        || ProcessInfo.processInfo.environment["MIRRORDECK_DEBUG"] == "1"
    private static let path = "/tmp/mirrordeck.log"
    private static let queue = DispatchQueue(label: "mirrordeck.log")

    static func write(_ message: String) {
        guard enabled else { return }
        queue.async {
            let line = "\(Date().formatted(date: .omitted, time: .standard))  \(message)\n"
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); fh.closeFile()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
}
