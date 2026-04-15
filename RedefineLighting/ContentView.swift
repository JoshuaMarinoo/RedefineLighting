//
//  ContentView.swift
//  RedefineLighting
//
//  Created by Joshua Marino on 4/14/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()

    var body: some View {
        ZStack {
            if cameraManager.permissionDenied {
                VStack(spacing: 12) {
                    Text("Camera access denied")
                        .font(.title2)
                        .bold()

                    Text("Enable camera access in Settings to use marker tracking.")
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            } else {
                CameraPreviewView(session: cameraManager.session)
                    .ignoresSafeArea()
            }
        }
        .onAppear {
            cameraManager.checkPermissionAndConfigure()
        }
        .onChange(of: cameraManager.isConfigured) {
            if cameraManager.isConfigured {
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
