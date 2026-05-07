//
//  DashboardManager.swift
//  RedefineLighting
//
import Combine
import Foundation
import CoreGraphics

final class DashboardManager: ObservableObject {
    @Published var dashboardStatus: String = "Dashboard not connected"
    @Published var lastGCommand: String = ""

    private var webSocketTask: URLSessionWebSocketTask?

    private var lastSentCenterX: Double?
    private var lastSentCenterY: Double?

    private let xChangeThreshold = 0.03
    private let yChangeThreshold = 0.03

    private let targetCenterX = 0.5
    private let angleGain = 20.0
    private let minAngle = -10.0
    private let maxAngle = 10.0

    private var lastSentAngle: Double?
    private var smoothedAngle: Double?
    private let smoothingAlpha = 0.25
    private let angleSendThreshold = 0.5
    private let minimumSendInterval: TimeInterval = 0.10
    private var lastSendTime: Date?

    func connect(to urlString: String) {
        guard let url = URL(string: urlString) else {
            dashboardStatus = "Invalid dashboard URL"
            return
        }

        webSocketTask = URLSession.shared.webSocketTask(with: url)
        webSocketTask?.resume()

        dashboardStatus = "Dashboard connecting..."
        print("Dashboard connecting to \(urlString)")

        listen()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        dashboardStatus = "Dashboard disconnected"
    }

    func makeGCommandIfNeeded(from box: NormalizedBox?) -> String? {
        guard let box else {
            return nil
        }

        let shouldConsiderSending: Bool

        if let lastX = lastSentCenterX,
           let lastY = lastSentCenterY {
            let xChange = abs(box.x - lastX)
            let yChange = abs(box.y - lastY)

            shouldConsiderSending = xChange > xChangeThreshold || yChange > yChangeThreshold
        } else {
            shouldConsiderSending = true
        }

        guard shouldConsiderSending else {
            return nil
        }

        let errorX = box.x - targetCenterX
        var rawAngle = errorX * angleGain

        if rawAngle < minAngle {
            rawAngle = minAngle
        }

        if rawAngle > maxAngle {
            rawAngle = maxAngle
        }

        let filteredAngle: Double

        if let previousSmoothedAngle = smoothedAngle {
            filteredAngle = smoothingAlpha * rawAngle + (1.0 - smoothingAlpha) * previousSmoothedAngle
        } else {
            filteredAngle = rawAngle
        }

        smoothedAngle = filteredAngle

        let now = Date()

        if let lastSendTime,
           now.timeIntervalSince(lastSendTime) < minimumSendInterval {
            return nil
        }

        if let lastSentAngle,
           abs(filteredAngle - lastSentAngle) < angleSendThreshold {
            return nil
        }

        let command = String(format: "G%.2f", filteredAngle)

        lastSentCenterX = box.x
        lastSentCenterY = box.y
        lastSentAngle = filteredAngle
        lastSendTime = now
        lastGCommand = command

        print("Generated dashboard G command:", command)
        print("box.x: \(box.x), errorX: \(errorX), rawAngle: \(rawAngle), filteredAngle: \(filteredAngle)")

        return command
    }

    func sendMetadata(
        box: NormalizedBox?,
        handGesture: HandGesture,
        lastGestureEvent: HandGesture,
        gestureEventID: Int,
        gCommand: String
    ) {
        var payload: [String: Any] = [
            "type": "metadata",
            "timestamp": Date().timeIntervalSince1970,
            "handGesture": String(describing: handGesture),
            "lastGestureEvent": String(describing: lastGestureEvent),
            "gestureEventID": gestureEventID,
            "gCommand": gCommand
        ]

        if let box {
            payload["box"] = [
                "x": box.x,
                "y": box.y,
                "width": box.width,
                "height": box.height,
                "confidence": box.confidence
            ]
        } else {
            payload["box"] = NSNull()
        }

        sendJSON(payload)
    }

    func sendFrame(
        base64JPEG: String,
        width: Int,
        height: Int
    ) {
        let payload: [String: Any] = [
            "type": "frame",
            "timestamp": Date().timeIntervalSince1970,
            "imageBase64": base64JPEG,
            "width": width,
            "height": height
        ]

        sendJSON(payload)
    }

    private func sendJSON(_ payload: [String: Any]) {
        guard let webSocketTask else {
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            print("Dashboard JSON encoding failed")
            return
        }

        webSocketTask.send(.string(json)) { error in
            DispatchQueue.main.async {
                if let error {
                    print("Dashboard send failed:", error.localizedDescription)
                    self.dashboardStatus = "Dashboard send failed"
                } else {
                    self.dashboardStatus = "Dashboard connected"
                }
            }
        }
    }

    private func listen() {
        webSocketTask?.receive { result in
            switch result {
            case .success:
                DispatchQueue.main.async {
                    self.dashboardStatus = "Dashboard connected"
                }

                self.listen()

            case .failure(let error):
                print("Dashboard receive failed:", error.localizedDescription)

                DispatchQueue.main.async {
                    self.dashboardStatus = "Dashboard disconnected"
                }
            }
        }
    }
}
