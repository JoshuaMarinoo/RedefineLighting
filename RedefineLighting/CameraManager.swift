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

final class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var videoDeviceOutput:AVCaptureVideoDataOutput?
    private var videoQueue:DispatchQueue?

    @Published var permissionDenied = false
    @Published var isConfigured = false

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
            session.addOutput(output)
            videoDeviceOutput=output
            session.addInput(input)
            videoDeviceInput=input
            videoQueue=queue
            output.setSampleBufferDelegate(self, queue: queue)
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
            print("Could not get pixel buffer")
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        print("Frame size: \(width) x \(height)")
    }
}
