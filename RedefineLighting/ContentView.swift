//
//  ContentView.swift
//  RedefineLighting
//
//  Created by Joshua Marino on 4/14/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var bluetoothManager = BluetoothManager()

    var body: some View {
        ZStack {
            CameraPreviewView(
                session: cameraManager.session,
                detectedBox: cameraManager.detectedBox
            )
            .ignoresSafeArea()

            VStack {
                Text(bluetoothManager.bluetoothStatus)
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

                Text("Motors: \(bluetoothManager.servoCommandsEnabled ? "ON" : "OFF")")
                    .padding()
                    .background(bluetoothManager.servoCommandsEnabled ? .green.opacity(0.75) : .red.opacity(0.75))
                    .foregroundStyle(.white)
                    .cornerRadius(8)

                Spacer()
            }
            .padding()
        }
        .onAppear {
            cameraManager.checkPermissionAndConfigure()
        }
        .onChange(of: cameraManager.isConfigured) { _, newValue in
            if newValue {
                cameraManager.startSession()
            }
        }
        .onChange(of: cameraManager.detectedBox) { _, newBox in
            bluetoothManager.sendDynamixelCommandIfNeeded(newBox)
        }
        .onChange(of: cameraManager.gestureEventID) { _, _ in
            switch cameraManager.lastGestureEvent {
            case .thumbsUp:
                bluetoothManager.toggleServoCommands()

            case .openPalm:
                bluetoothManager.cycleLedBrightness()

            case .none:
                break
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
