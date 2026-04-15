//
//  CameraManager.swift
//  RedefineLighting
//
//  Created by Joshua Marino on 4/14/26.
//
import AVFoundation
import UIKit
import Combine

final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var videoDeviceOutput:AVCaptureVideoDataOutput?

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
}
