//
//  CameraPreviewView.swift
//  RedefineLighting
//
//  Created by Joshua Marino on 4/14/26.
//
import SwiftUI
import AVFoundation
import UIKit

final class PreviewUIView: UIView {
    private let boxLayer = CAShapeLayer()

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        previewLayer.videoGravity = .resizeAspectFill

        boxLayer.strokeColor = UIColor.red.cgColor
        boxLayer.fillColor = UIColor.clear.cgColor
        boxLayer.lineWidth = 3

        previewLayer.addSublayer(boxLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateDetection(_ box: NormalizedBox?) {
        guard let box else {
            boxLayer.path = nil
            return
        }

        // Start with your model's normalized center-based box.
        // If vertical placement is still wrong, this is the one line
        // we tweak next.
        let normalizedRect = CGRect(
            x: box.x - box.width / 2,
            y: box.y - box.height / 2,
            width: box.width,
            height: box.height
        )

        let convertedRect = previewLayer.layerRectConverted(
            fromMetadataOutputRect: normalizedRect
        )

        boxLayer.path = UIBezierPath(rect: convertedRect).cgPath
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        boxLayer.frame = bounds
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let detectedBox: NormalizedBox?

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.previewLayer.session = session
        uiView.updateDetection(detectedBox)
    }
}
