//
//  RedefineLightingApp.swift
//  RedefineLighting
//
//  Created by Joshua Marino on 4/14/26.
//

import SwiftUI

// The @main attribute marks this as the app's entry point.
// SwiftUI starts here, creates the main scene, and loads the first view.
@main
struct RedefineLightingApp: App {
    var body: some Scene {
        // WindowGroup creates the main app window scene.
        // ContentView becomes the root view shown when the app launches.
        WindowGroup {
            ContentView()
        }
    }
}
