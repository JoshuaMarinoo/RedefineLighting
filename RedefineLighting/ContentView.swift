//
//  ContentView.swift
//  RedefineLighting
//
//  Created by Joshua Marino on 4/14/26.
//

import SwiftUI

struct ContentView: View {
    // @StateObject tells SwiftUI to create and keep one CameraManager instance
    // alive for this view. Since the camera manager owns long-lived state like
    // the capture session, it should not be recreated every time the view redraws.
    @StateObject private var cameraManager = CameraManager()

    var body: some View {
        // ZStack layers views on top of each other.
        // Right now the preview fills the screen, and the detection overlay
        // is handled inside CameraPreviewView / PreviewUIView.
        ZStack {
            CameraPreviewView(
                session: cameraManager.session,
                detectedBox: cameraManager.detectedBox
            )
            .ignoresSafeArea()
        }
        // When the view appears, first check camera permission and configure
        // the session if access is available.
        .onAppear {
            cameraManager.checkPermissionAndConfigure()
        }
        // onChange watches isConfigured and responds once the camera session
        // setup finishes. This keeps session startup separate from permission
        // checking and configuration.
        .onChange(of: cameraManager.isConfigured) { _, newValue in
            if newValue {
                cameraManager.startSession()
            }
        }
        // Stop the camera session when the view disappears so the app is not
        // still capturing frames in the background.
        .onDisappear {
            cameraManager.stopSession()
        }
    }
}

// #Preview is Xcode's preview entry point for showing this view in the canvas.
#Preview {
    ContentView()
}
