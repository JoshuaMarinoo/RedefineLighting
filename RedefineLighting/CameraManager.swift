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

// This struct stores one detection from the model in a simple Swift type.
// The model gives normalized values, so x, y, width, and height are all
// relative to the image size rather than absolute pixel values.
struct NormalizedBox: Equatable{
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let confidence: Double
}

// CameraManager owns the camera session and handles live frame processing.
// NSObject is needed here because AVCaptureVideoDataOutput uses a delegate
// pattern from AVFoundation, and that delegate must be an NSObject subclass.
// ObservableObject lets SwiftUI watch this class for published state changes.
final class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    // The capture session is the main AVFoundation object that coordinates
    // camera input and video output.
    let session = AVCaptureSession()

    // These stored references let the session keep using the configured
    // camera input, frame output, and processing queue after setup finishes.
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var videoDeviceOutput: AVCaptureVideoDataOutput?
    private var videoQueue: DispatchQueue?

    // This flag prevents multiple frames from being processed at the same time.
    // Since model inference is relatively expensive, we skip new frames while
    // one frame is still being handled.
    private var isProcessingFrame = false

    // Load the Core ML model once so it can be reused for each frame.
    let mlModel = try? Redefine_Lighting_1(configuration: .init())

    // These published values are read by SwiftUI views.
    // permissionDenied tells the UI whether camera access failed.
    // isConfigured tells the UI whether the session is ready to start.
    // detectedBox stores the latest model detection for the overlay.
    @Published var permissionDenied = false
    @Published var isConfigured = false
    @Published var detectedBox: NormalizedBox?

    // There is no custom setup needed here yet, but override init is still
    // included so the class can call super.init() properly.
    // Since this class inherits from NSObject, Swift requires the parent class
    // initializer to run before the object is fully ready.
    override init() {
        super.init()
    }

    // Before the camera can be configured, the app has to know whether it has
    // permission to access video capture. This function checks the current
    // authorization state and either moves forward with setup or updates UI state.
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

    // This function builds the camera pipeline.
    // It chooses the back camera, creates the session input and output,
    // and connects the output to this class through the delegate callback.
    private func configureSession() {
        guard !isConfigured else { return }

        // beginConfiguration/commitConfiguration groups session changes together
        // before AVFoundation starts using them.
        session.beginConfiguration()
        session.sessionPreset = .high

        // Search for the built-in back wide-angle camera.
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

            // Make sure the session accepts the input and output before adding them.
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                return
            }

            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                return
            }

            // The input is the physical back camera.
            session.addInput(input)
            videoDeviceInput = input

            // The output gives the app access to each video frame as it arrives.
            session.addOutput(output)
            videoDeviceOutput = output

            // Set this class as the sample buffer delegate so captureOutput(...)
            // gets called for every frame. The dedicated queue keeps frame work
            // off the main thread.
            videoQueue = queue
            output.setSampleBufferDelegate(self, queue: queue)

            // If the model falls behind, discard older frames instead of letting
            // them build up and cause lag.
            output.alwaysDiscardsLateVideoFrames = true

            session.commitConfiguration()
            isConfigured = true
        } catch {
            session.commitConfiguration()
            print("Failed to configure camera: \(error)")
        }
    }

    // Once the session is configured, this starts live capture.
    // The actual startRunning call is moved off the main thread so the UI
    // does not freeze while AVFoundation starts the camera.
    func startSession() {
        guard isConfigured, !session.isRunning else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }

    // Stop the session when the camera view disappears or no longer needs input.
    // Like startRunning, this is done off the main thread.
    func stopSession() {
        guard session.isRunning else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            self.session.stopRunning()
        }
    }

    // This delegate method is called by AVFoundation whenever a new frame is ready.
    // The sample buffer holds the frame data, and CMSampleBufferGetImageBuffer
    // extracts the CVPixelBuffer that Core ML can use as model input.
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("No pixel buffer")
            return
        }

        // Skip the frame if the previous one is still being processed.
        guard !isProcessingFrame else {
            print("Still Processing Frame")
            return
        }

        isProcessingFrame = true
        processFrame(pixelBuffer)
    }

    // This function runs the Core ML model on one frame and keeps only the
    // highest-confidence detection. That best detection is then published so
    // the UI can update the overlay.
    private func processFrame(_ pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        DispatchQueue.global(qos: .userInitiated).async {
            print("START processing frame: \(width) x \(height)")

            // Run the model on the current camera frame.
            // The thresholds control which detections are kept by the model.
            guard let output = try? self.mlModel?.prediction(
                image: pixelBuffer,
                iouThreshold: 0.33,
                confidenceThreshold: 0.7
            ) else {
                print("Prediction failed")
                self.isProcessingFrame = false
                return
            }

            if output.coordinates.count != 0 {
                var bestIndex = -1
                var bestConfidence = -Double.infinity

                // The model may return multiple detections.
                // This loop scans the confidence array once and keeps only
                // the index of the strongest detection.
                for r in 0..<output.confidence.shape[0].intValue {
                    let c = output.confidence[[NSNumber(value: r), 0]].doubleValue
                    if c > bestConfidence {
                        bestConfidence = c
                        bestIndex = r
                    }
                }

                // Use the best row index to read the matching coordinates
                // from the model output and package them into NormalizedBox.
                let detected = NormalizedBox(
                    x: output.coordinates[[NSNumber(value: bestIndex), NSNumber(value: 0)]].doubleValue,
                    y: output.coordinates[[NSNumber(value: bestIndex), NSNumber(value: 1)]].doubleValue,
                    width: output.coordinates[[NSNumber(value: bestIndex), NSNumber(value: 2)]].doubleValue,
                    height: output.coordinates[[NSNumber(value: bestIndex), NSNumber(value: 3)]].doubleValue,
                    confidence: output.confidence[[NSNumber(value: bestIndex), NSNumber(value: 0)]].doubleValue
                )

                // Publish UI-facing state on the main thread since SwiftUI
                // expects @Published updates to happen there.
                DispatchQueue.main.async {
                    self.detectedBox = detected
                }

                print(
                    detected.x,
                    detected.y,
                    detected.width,
                    detected.height,
                    detected.confidence
                )
                print("END processing frame")
                self.isProcessingFrame = false

            } else {
                // Clear the current overlay when the model does not find anything.
                DispatchQueue.main.async {
                    self.detectedBox = nil
                }

                print("No Bounding Box Detected")
                self.isProcessingFrame = false
            }
        }
    }
}
