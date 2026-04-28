//
//  CameraPreviewView.swift
//  RedefineLighting
//
//  Created by Joshua Marino on 4/14/26.
//

import SwiftUI
import AVFoundation
import UIKit

// This UIView subclass is the actual camera preview on screen.
// It owns both the AVCaptureVideoPreviewLayer and a shape layer that draws
// the detection box on top of the live camera feed.
final class PreviewUIView: UIView {
    // Separate layer used only for drawing the current bounding box.
    private let boxLayer = CAShapeLayer()

    // Override layerClass so this view's backing layer is an AVCaptureVideoPreviewLayer.
    // That gives the view a built-in way to display the live camera session directly.
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    // This computed property makes it easier to work with the backing layer
    // as an AVCaptureVideoPreviewLayer instead of a generic CALayer.
    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    // Set up the preview layer and the overlay layer when the view is created.
    override init(frame: CGRect) {
        super.init(frame: frame)

        // resizeAspectFill keeps the camera preview filling the whole view,
        // even if some of the image needs to be cropped.
        previewLayer.videoGravity = .resizeAspectFill

        // Configure the overlay to draw a simple red outline with no fill.
        boxLayer.strokeColor = UIColor.red.cgColor
        boxLayer.fillColor = UIColor.clear.cgColor
        boxLayer.lineWidth = 3

        // Add the overlay above the preview so the box appears on top of the camera image.
        previewLayer.addSublayer(boxLayer)
    }

    // This project does not use storyboard/xib initialization for the preview view.
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Update the overlay whenever the latest detection changes.
    // If there is no box, clear the overlay. If there is a box, convert the
    // normalized model output into the preview layer's coordinate space.
    func updateDetection(_ box: NormalizedBox?) {
        guard let box else {
            boxLayer.path = nil
            return
        }

        // The model output is center-based and normalized from 0 to 1.
        // Convert it into a normalized CGRect first.
        let normalizedRect = CGRect(
            x: box.x - box.width / 2,
            y: box.y - box.height / 2,
            width: box.width,
            height: box.height
        )

        // Convert the normalized rect into the actual on-screen rect used by
        // the preview layer. This is what makes the overlay match the camera preview
        // better than simple SwiftUI width/height math.
        let convertedRect = previewLayer.layerRectConverted(
            fromMetadataOutputRect: normalizedRect
        )

        // Draw the updated box.
        boxLayer.path = UIBezierPath(rect: convertedRect).cgPath
    }

    // Keep the overlay layer sized to the view whenever layout changes.
    override func layoutSubviews() {
        super.layoutSubviews()
        boxLayer.frame = bounds
    }
}

// SwiftUI cannot use UIKit views directly, so UIViewRepresentable acts as the bridge.
// This wrapper creates the PreviewUIView once and updates it when SwiftUI state changes.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let detectedBox: NormalizedBox?

    // Create the UIKit preview view and attach the camera session to its preview layer.
    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        return view
    }

    // Keep the UIKit view in sync with SwiftUI state updates.
    // This is where the latest detection box gets pushed into the preview overlay.
    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.previewLayer.session = session
        uiView.updateDetection(detectedBox)
    }
}
