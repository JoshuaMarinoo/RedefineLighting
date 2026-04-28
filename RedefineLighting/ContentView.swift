//
//  ContentView.swift
//  RedefineLighting
//
//  Created by Joshua Marino on 4/14/26.
//

import SwiftUI

import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()

    var body: some View {
        ZStack {
            CameraPreviewView(
                session: cameraManager.session,
                detectedBox: cameraManager.detectedBox
            )
            .ignoresSafeArea()
        }
        .onAppear {
            cameraManager.checkPermissionAndConfigure()
        }
        .onChange(of: cameraManager.isConfigured) { _, newValue in
            if newValue {
                cameraManager.startSession()
            }
        }
        .onDisappear {
            cameraManager.stopSession()
        }
    }
}

#Preview {
    ContentView()
}
