//
//  ContentView.swift
//  RedefineLighting
//
//  Created by Joshua Marino on 4/14/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var dashboardManager = DashboardManager()

    // Replace this with the Mac's IP address on the third-iPhone hotspot.
    // Example: ws://172.20.10.3:8080/iphone
    private let dashboardURL = "ws://172.20.10.3:8080/iphone"

    var body: some View {
        ZStack {
            CameraPreviewView(
                session: cameraManager.session,
                detectedBox: cameraManager.detectedBox
            )
            .ignoresSafeArea()

            VStack {
                Text(dashboardManager.dashboardStatus)
                    .padding()
                    .background(.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .cornerRadius(8)

                Text("Current hand: \(String(describing: cameraManager.handGesture))")
                    .padding()
                    .background(.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .cornerRadius(8)

                Text("Last held gesture: \(String(describing: cameraManager.lastGestureEvent))")
                    .padding()
                    .background(.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .cornerRadius(8)

                Text("G command: \(dashboardManager.lastGCommand)")
                    .padding()
                    .background(.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .cornerRadius(8)

                Spacer()
            }
            .padding()
        }
        .onAppear {
            cameraManager.checkPermissionAndConfigure()
            dashboardManager.connect(to: dashboardURL)
        }
        .onChange(of: cameraManager.isConfigured) { _, newValue in
            if newValue {
                cameraManager.startSession()
            }
        }
        .onChange(of: cameraManager.detectedBox) { _, newBox in
            let newGCommand = dashboardManager.makeGCommandIfNeeded(from: newBox)

            dashboardManager.sendMetadata(
                box: newBox,
                handGesture: cameraManager.handGesture,
                lastGestureEvent: cameraManager.lastGestureEvent,
                gestureEventID: cameraManager.gestureEventID,
                gCommand: newGCommand ?? dashboardManager.lastGCommand
            )
        }
        .onChange(of: cameraManager.gestureEventID) { _, _ in
            dashboardManager.sendMetadata(
                box: cameraManager.detectedBox,
                handGesture: cameraManager.handGesture,
                lastGestureEvent: cameraManager.lastGestureEvent,
                gestureEventID: cameraManager.gestureEventID,
                gCommand: dashboardManager.lastGCommand
            )
        }
        .onChange(of: cameraManager.dashboardFrameID) { _, _ in
            guard let frame = cameraManager.dashboardFrameBase64 else {
                return
            }

            dashboardManager.sendFrame(
                base64JPEG: frame,
                width: cameraManager.dashboardFrameWidth,
                height: cameraManager.dashboardFrameHeight
            )
        }
        .onDisappear {
            cameraManager.stopSession()
            dashboardManager.disconnect()
        }
    }
}

#Preview {
    ContentView()
}
