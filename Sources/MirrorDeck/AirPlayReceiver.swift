import Foundation
import CMirrorBridge

enum ReceiverEvent {
    case connected
    case disconnected
    case connReset(reason: Int)
    case videoPause
    case videoResume
    case videoFlush
    case clientInfo(deviceID: String, model: String, name: String)
    case sourceSize(width: Int, height: Int)
    case mirrorRunning(Bool)
}

/// Swift wrapper around the C AirPlay receiver core (single instance).
final class AirPlayReceiver {
    static let shared = AirPlayReceiver()

    /// Called on a receiver thread with an Annex-B H.264 access unit. Copy the
    /// bytes before returning.
    var onVideo: ((UnsafePointer<UInt8>, Int, Bool) -> Void)?
    /// Called on the main thread.
    var onEvent: ((ReceiverEvent) -> Void)?
    var onLog: ((Int, String) -> Void)?

    private(set) var isRunning = false
    private init() {}

    @discardableResult
    func start(name: String, debug: Bool = false) -> Bool {
        guard !isRunning else { return true }
        var cbs = mb_callbacks_t()
        cbs.ctx = Unmanaged.passUnretained(self).toOpaque()
        cbs.on_video = { ctx, data, len, _, _, isH265 in
            guard let ctx, let data else { return }
            let receiver = Unmanaged<AirPlayReceiver>.fromOpaque(ctx).takeUnretainedValue()
            receiver.onVideo?(data, Int(len), isH265 != 0)
        }
        cbs.on_audio = { _, _, _, _, _ in
            // Audio rendering is not implemented yet; frames are dropped.
        }
        cbs.on_event = { ctx, event, value, info in
            guard let ctx else { return }
            let receiver = Unmanaged<AirPlayReceiver>.fromOpaque(ctx).takeUnretainedValue()
            let infoString = info.map { String(cString: $0) }
            receiver.handleEvent(event, value: Int(value), info: infoString)
        }
        cbs.on_log = { ctx, level, msg in
            guard let ctx, let msg else { return }
            let receiver = Unmanaged<AirPlayReceiver>.fromOpaque(ctx).takeUnretainedValue()
            receiver.onLog?(Int(level), String(cString: msg))
        }
        let result = mb_start(name, &cbs, debug ? 1 : 0)
        isRunning = result == 0
        return isRunning
    }

    func stop() {
        guard isRunning else { return }
        mb_stop()
        isRunning = false
    }

    private func handleEvent(_ event: Int32, value: Int, info: String?) {
        let mapped: ReceiverEvent?
        switch mb_event_t(rawValue: UInt32(event)) {
        case MB_EVENT_CONN_INIT: mapped = .connected
        case MB_EVENT_CONN_DESTROY: mapped = .disconnected
        case MB_EVENT_CONN_RESET: mapped = .connReset(reason: value)
        case MB_EVENT_VIDEO_PAUSE: mapped = .videoPause
        case MB_EVENT_VIDEO_RESUME: mapped = .videoResume
        case MB_EVENT_VIDEO_FLUSH: mapped = .videoFlush
        case MB_EVENT_CLIENT_INFO:
            let parts = (info ?? "").components(separatedBy: "\t")
            mapped = .clientInfo(
                deviceID: parts.count > 0 ? parts[0] : "",
                model: parts.count > 1 ? parts[1] : "",
                name: parts.count > 2 ? parts[2] : "")
        case MB_EVENT_SOURCE_SIZE:
            let dims = (info ?? "").components(separatedBy: "x").compactMap { Int($0) }
            mapped = dims.count == 2 ? .sourceSize(width: dims[0], height: dims[1]) : nil
        case MB_EVENT_MIRROR_RUNNING: mapped = .mirrorRunning(value != 0)
        default: mapped = nil
        }
        if let mapped {
            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(mapped)
            }
        }
    }
}
