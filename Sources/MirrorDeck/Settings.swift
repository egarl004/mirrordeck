import Foundation

enum Settings {
    private static let defaults = UserDefaults.standard

    /// Name shown in the iOS Screen Mirroring list.
    static var receiverName: String {
        get {
            if let custom = defaults.string(forKey: "receiverName") { return custom }
            let host = Host.current().localizedName ?? "Mac"
            return "\(host) (MirrorDeck)"
        }
        set { defaults.set(newValue, forKey: "receiverName") }
    }

    /// WebDriverAgent host remembered per mirrored device id.
    static func wdaHost(forDevice deviceID: String) -> String? {
        (defaults.dictionary(forKey: "wdaHosts") as? [String: String])?[deviceID]
    }

    static func setWDAHost(_ host: String, forDevice deviceID: String) {
        var hosts = (defaults.dictionary(forKey: "wdaHosts") as? [String: String]) ?? [:]
        hosts[deviceID] = host
        defaults.set(hosts, forKey: "wdaHosts")
        lastWDAHost = host
    }

    /// Most recent WDA host, used to prefill the setup field for a new device.
    static var lastWDAHost: String? {
        get { defaults.string(forKey: "lastWDAHost") }
        set { defaults.set(newValue, forKey: "lastWDAHost") }
    }

    /// Whether the mirror window floats above other applications.
    static var alwaysOnTop: Bool {
        get { defaults.bool(forKey: "alwaysOnTop") }
        set { defaults.set(newValue, forKey: "alwaysOnTop") }
    }
}
