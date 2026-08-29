import Foundation

/// Minimal WebDriverAgent HTTP client. WDA runs on the phone (installed once
/// via Xcode / go-ios) and exposes tap/swipe/type over Wi-Fi on port 8100.
/// All requests run on a serial queue so gestures arrive in order.
final class WDAClient {
    enum State: Equatable {
        case disconnected
        case connecting
        case connected(screenSize: CGSize) // in device points
    }

    private(set) var state: State = .disconnected {
        didSet {
            let newState = state
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onStateChange?(newState)
            }
        }
    }
    var onStateChange: ((State) -> Void)?

    /// While true, the phone is kept unlocked so mirroring never goes black.
    var keepAwake = true

    private var baseURL: URL?
    private var sessionID: String?
    private var keepAwakeTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "mirrordeck.wda")
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    // MARK: - Lifecycle

    func connect(host: String, port: Int = 8100) {
        guard let url = URL(string: "http://\(host):\(port)") else { return }
        baseURL = url
        state = .connecting
        queue.async { [weak self] in
            self?.performConnect()
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.stopKeepAwake()
            self?.sessionID = nil
            self?.state = .disconnected
        }
    }

    // MARK: - Keep awake

    /// Polls the lock state and re-unlocks if the phone auto-locked, so the
    /// mirror never drops to a black/lock screen. Reactive-only by design:
    /// a periodic synthetic tap would risk activating whatever's on screen.
    private func startKeepAwake() {
        stopKeepAwake()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 8, repeating: 8)
        timer.setEventHandler { [weak self] in
            guard let self, self.keepAwake, let sid = self.sessionID else { return }
            if let locked = self.request("GET", "/session/\(sid)/wda/locked")?["value"] as? Bool,
               locked {
                _ = self.request("POST", "/session/\(sid)/wda/unlock", body: [:])
            }
        }
        timer.resume()
        keepAwakeTimer = timer
    }

    private func stopKeepAwake() {
        keepAwakeTimer?.cancel()
        keepAwakeTimer = nil
    }

    private func performConnect() {
        // A fresh session; WDA replies with the created sessionId.
        guard let response = request(
            "POST", "/session",
            body: ["capabilities": ["alwaysMatch": [String: String]()]]) else {
            state = .disconnected
            return
        }
        let sid = (response["sessionId"] as? String)
            ?? ((response["value"] as? [String: Any])?["sessionId"] as? String)
        guard let sid else {
            state = .disconnected
            return
        }
        sessionID = sid
        guard let sizeValue = request("GET", "/session/\(sid)/window/size")?["value"] as? [String: Any],
              let width = sizeValue["width"] as? Double,
              let height = sizeValue["height"] as? Double else {
            state = .disconnected
            return
        }
        applyFastSettings(sessionID: sid)
        if let locked = request("GET", "/session/\(sid)/wda/locked")?["value"] as? Bool, locked {
            _ = request("POST", "/session/\(sid)/wda/unlock", body: [:])
        }
        startKeepAwake()
        state = .connected(screenSize: CGSize(width: width, height: height))
    }

    /// Disable WDA's post-gesture idle/animation waits — cuts ~40% off every
    /// gesture's round trip. Best-effort; failure just leaves defaults.
    private func applyFastSettings(sessionID sid: String) {
        _ = request("POST", "/session/\(sid)/appium/settings", body: [
            "settings": [
                "waitForIdleTimeout": 0,
                "animationCoolOffTimeout": 0,
                "shouldWaitForQuiescence": false,
                "shouldUseCompactResponses": true,
            ]
        ])
    }

    // MARK: - Gestures (device points)

    func tap(at point: CGPoint) {
        performActions([
            pointerAction([
                move(to: point, duration: 0),
                ["type": "pointerDown", "button": 0],
                ["type": "pause", "duration": 60],
                ["type": "pointerUp", "button": 0],
            ])
        ])
    }

    func longPress(at point: CGPoint, duration: TimeInterval) {
        performActions([
            pointerAction([
                move(to: point, duration: 0),
                ["type": "pointerDown", "button": 0],
                ["type": "pause", "duration": Int(duration * 1000)],
                ["type": "pointerUp", "button": 0],
            ])
        ])
    }

    /// Drag through the given points; `timestamps` are seconds from gesture start.
    func drag(points: [CGPoint], timestamps: [TimeInterval]) {
        guard points.count >= 2, points.count == timestamps.count else { return }
        var steps: [[String: Any]] = [
            move(to: points[0], duration: 0),
            ["type": "pointerDown", "button": 0],
        ]
        for i in 1..<points.count {
            let dt = max(1, Int((timestamps[i] - timestamps[i - 1]) * 1000))
            steps.append(move(to: points[i], duration: dt))
        }
        steps.append(["type": "pointerUp", "button": 0])
        performActions([pointerAction(steps)])
    }

    func typeText(_ text: String) {
        guard let sid = sessionID else { return }
        enqueueRequest("POST", "/session/\(sid)/wda/keys", body: ["value": [text]])
    }

    /// name: "home", "volumeUp", "volumeDown"
    func pressButton(_ name: String) {
        guard let sid = sessionID else { return }
        enqueueRequest("POST", "/session/\(sid)/wda/pressButton", body: ["name": name])
    }

    // MARK: - W3C actions plumbing

    private func move(to point: CGPoint, duration: Int) -> [String: Any] {
        ["type": "pointerMove", "duration": duration,
         "x": Int(point.x.rounded()), "y": Int(point.y.rounded())]
    }

    private func pointerAction(_ steps: [[String: Any]]) -> [String: Any] {
        ["type": "pointer", "id": "finger1",
         "parameters": ["pointerType": "touch"], "actions": steps]
    }

    private func performActions(_ actions: [[String: Any]]) {
        guard let sid = sessionID else { return }
        // Fire-and-forget: WDA blocks the HTTP response for ~0.5s per gesture
        // (XCUITest event synthesis), but the Mac must never stall for that.
        // Sending without waiting keeps input fluid and lets gestures pipeline.
        sendGesture("/session/\(sid)/actions", body: ["actions": actions])
    }

    /// Non-blocking gesture send. Detects an expired session and reconnects.
    private func sendGesture(_ path: String, body: [String: Any]) {
        guard let baseURL else { return }
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        session.dataTask(with: urlRequest) { [weak self] data, response, _ in
            guard let self else { return }
            let expired = (response as? HTTPURLResponse)?.statusCode != 200
            if expired, case .connected = self.state {
                self.queue.async { self.performConnect() }
            }
        }.resume()
    }

    // MARK: - HTTP

    private func enqueueRequest(_ method: String, _ path: String, body: [String: Any]? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.request(method, path, body: body)
            if result == nil, case .connected = self.state {
                // Session may have expired (WDA restart); try to re-establish once.
                self.performConnect()
            }
        }
    }

    /// Synchronous request — only ever called on `queue`.
    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) -> [String: Any]? {
        guard let baseURL else { return nil }
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = method
        if let body {
            urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        let task = session.dataTask(with: urlRequest) { data, response, _ in
            defer { semaphore.signal() }
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            result = json
        }
        task.resume()
        semaphore.wait()
        return result
    }
}
