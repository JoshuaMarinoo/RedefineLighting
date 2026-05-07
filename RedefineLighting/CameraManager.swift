//
//  CameraManager.swift
//  RedefineLighting
//
//  Created by Joshua Marino on 4/14/26.
//

import AVFoundation
import UIKit
import Combine
import Dispatch
import CoreML
import Vision

struct NormalizedBox: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let confidence: Double
}

enum HandGesture: Equatable {
    case none
    case thumbsUp
    case openPalm
}

final class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()

    private var videoDeviceInput: AVCaptureDeviceInput?
    private var videoDeviceOutput: AVCaptureVideoDataOutput?
    private var videoQueue: DispatchQueue?

    private var isProcessingFrame = false

    // Load the Core ML object detection model once.
    let mlModel = try? Redefine_Lighting_1(configuration: .init())

    // -------------------- HAND POSE / GESTURE STATE --------------------
    @Published var handGesture: HandGesture = .none

    // ContentView watches this. It increments only when a held gesture fires.
    @Published var gestureEventID = 0
    @Published var lastGestureEvent: HandGesture = .none

    private var frameCounter = 0
    private let handPoseEveryNFrames = 5

    private let handPoseRequest = VNDetectHumanHandPoseRequest()
    private let handPoseConfidenceThreshold: VNConfidence = 0.35

    private let gestureHoldDuration: TimeInterval = 1.0

    private var stableGesture: HandGesture = .none
    private var stableGestureStartTime: Date?
    private var didFireHeldGesture = false

    // -------------------- PUBLISHED UI STATE --------------------
    @Published var permissionDenied = false
    @Published var isConfigured = false
    @Published var detectedBox: NormalizedBox?

    override init() {
        super.init()
    }

    func checkPermissionAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.configureSession()
                    } else {
                        self.permissionDenied = true
                    }
                }
            }

        case .denied, .restricted:
            permissionDenied = true

        @unknown default:
            permissionDenied = true
        }
    }

    private func configureSession() {
        guard !isConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = .high

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )

        guard let camera = discoverySession.devices.first else {
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            let output = AVCaptureVideoDataOutput()
            let queue = DispatchQueue(label: "VideoQueue")

            guard session.canAddInput(input) else {
                session.commitConfiguration()
                return
            }

            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                return
            }

            session.addInput(input)
            videoDeviceInput = input

            session.addOutput(output)
            videoDeviceOutput = output

            videoQueue = queue
            output.setSampleBufferDelegate(self, queue: queue)

            // If processing falls behind, drop old frames instead of creating lag.
            output.alwaysDiscardsLateVideoFrames = true

            session.commitConfiguration()
            isConfigured = true
        } catch {
            session.commitConfiguration()
            print("Failed to configure camera: \(error)")
        }
    }

    func startSession() {
        guard isConfigured, !session.isRunning else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }

    func stopSession() {
        guard session.isRunning else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            self.session.stopRunning()
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("No pixel buffer")
            return
        }

        guard !isProcessingFrame else {
            return
        }

        isProcessingFrame = true
        processFrame(pixelBuffer)
    }

    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                self.isProcessingFrame = false
            }

            print("START processing frame: \(width) x \(height)")

            self.frameCounter += 1

            if self.frameCounter % self.handPoseEveryNFrames == 0 {
                self.runHandPose(pixelBuffer)
            }

            self.runDetector(pixelBuffer)

            print("END processing frame using object detector only")
        }
    }

    // -------------------- CORE ML OBJECT DETECTION --------------------

    private func runDetector(_ pixelBuffer: CVPixelBuffer) {
        guard let output = try? self.mlModel?.prediction(
            image: pixelBuffer,
            iouThreshold: 0.33,
            confidenceThreshold: 0.7
        ) else {
            print("Prediction failed")

            DispatchQueue.main.async {
                self.detectedBox = nil
            }

            return
        }

        guard output.coordinates.count != 0 else {
            DispatchQueue.main.async {
                self.detectedBox = nil
            }

            print("No Bounding Box Detected")
            return
        }

        var bestIndex = -1
        var bestConfidence = -Double.infinity

        // The model may return multiple detections.
        // Keep the highest-confidence detection only.
        for r in 0..<output.confidence.shape[0].intValue {
            let c = output.confidence[[NSNumber(value: r), 0]].doubleValue

            if c > bestConfidence {
                bestConfidence = c
                bestIndex = r
            }
        }

        guard bestIndex >= 0 else {
            DispatchQueue.main.async {
                self.detectedBox = nil
            }

            return
        }

        let detected = NormalizedBox(
            x: output.coordinates[[NSNumber(value: bestIndex), NSNumber(value: 0)]].doubleValue,
            y: output.coordinates[[NSNumber(value: bestIndex), NSNumber(value: 1)]].doubleValue,
            width: output.coordinates[[NSNumber(value: bestIndex), NSNumber(value: 2)]].doubleValue,
            height: output.coordinates[[NSNumber(value: bestIndex), NSNumber(value: 3)]].doubleValue,
            confidence: output.confidence[[NSNumber(value: bestIndex), NSNumber(value: 0)]].doubleValue
        )

        DispatchQueue.main.async {
            self.detectedBox = detected
        }

        print(
            "DETECTOR:",
            detected.x,
            detected.y,
            detected.width,
            detected.height,
            detected.confidence
        )
    }

    // -------------------- HAND POSE HELPERS --------------------

    private func runHandPose(_ pixelBuffer: CVPixelBuffer) {
        handPoseRequest.maximumHandCount = 1

        do {
            let requestHandler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: .right,
                options: [:]
            )

            try requestHandler.perform([handPoseRequest])

            guard let observation = handPoseRequest.results?.first else {
                updateGesture(.none)
                return
            }

            let points = try observation.recognizedPoints(.all)
            let gesture = classifyHandGesture(points: points)

            updateGesture(gesture)

        } catch {
            print("Hand pose failed:", error.localizedDescription)
            updateGesture(.none)
        }
    }

    private func classifyHandGesture(
        points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]
    ) -> HandGesture {
        guard
            let wrist = confidentPoint(points[.wrist]),
            let thumbTip = confidentPoint(points[.thumbTip]),
            let indexTip = confidentPoint(points[.indexTip]),
            let middleTip = confidentPoint(points[.middleTip]),
            let ringTip = confidentPoint(points[.ringTip]),
            let littleTip = confidentPoint(points[.littleTip]),
            let indexPIP = confidentPoint(points[.indexPIP]),
            let middlePIP = confidentPoint(points[.middlePIP]),
            let ringPIP = confidentPoint(points[.ringPIP]),
            let littlePIP = confidentPoint(points[.littlePIP])
        else {
            return .none
        }

        let indexExtended = distance(indexTip.location, wrist.location) > distance(indexPIP.location, wrist.location) * 1.15
        let middleExtended = distance(middleTip.location, wrist.location) > distance(middlePIP.location, wrist.location) * 1.15
        let ringExtended = distance(ringTip.location, wrist.location) > distance(ringPIP.location, wrist.location) * 1.15
        let littleExtended = distance(littleTip.location, wrist.location) > distance(littlePIP.location, wrist.location) * 1.15

        let extendedFingerCount = [
            indexExtended,
            middleExtended,
            ringExtended,
            littleExtended
        ].filter { $0 }.count

        if extendedFingerCount >= 4 {
            return .openPalm
        }

        let thumbDistance = distance(thumbTip.location, wrist.location)
        let indexDistance = distance(indexTip.location, wrist.location)
        let middleDistance = distance(middleTip.location, wrist.location)
        let ringDistance = distance(ringTip.location, wrist.location)
        let littleDistance = distance(littleTip.location, wrist.location)

        let thumbIsDominant =
            thumbDistance > indexDistance * 1.15 &&
            thumbDistance > middleDistance * 1.15 &&
            thumbDistance > ringDistance * 1.15 &&
            thumbDistance > littleDistance * 1.15

        let otherFingersMostlyFolded = extendedFingerCount <= 1

        if thumbIsDominant && otherFingersMostlyFolded {
            return .thumbsUp
        }

        return .none
    }

    private func confidentPoint(_ point: VNRecognizedPoint?) -> VNRecognizedPoint? {
        guard let point,
              point.confidence >= handPoseConfidenceThreshold else {
            return nil
        }

        return point
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    private func updateGesture(_ gesture: HandGesture) {
        DispatchQueue.main.async {
            self.handGesture = gesture

            let now = Date()

            if gesture == .none {
                self.stableGesture = .none
                self.stableGestureStartTime = nil
                self.didFireHeldGesture = false
                return
            }

            if gesture != self.stableGesture {
                self.stableGesture = gesture
                self.stableGestureStartTime = now
                self.didFireHeldGesture = false
                return
            }

            guard let startTime = self.stableGestureStartTime else {
                self.stableGestureStartTime = now
                return
            }

            let heldTime = now.timeIntervalSince(startTime)

            if heldTime >= self.gestureHoldDuration && !self.didFireHeldGesture {
                self.lastGestureEvent = gesture
                self.gestureEventID += 1
                self.didFireHeldGesture = true

                print("Held gesture triggered:", gesture)
            }
        }
    }
}
