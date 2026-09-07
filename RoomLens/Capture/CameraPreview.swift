//
//  CameraPreview.swift
//  RoomLens
//
//  The live camera preview.
//

import AVFoundation
import SwiftUI
import UIKit

/// Hosts an `AVCaptureVideoPreviewLayer` for SwiftUI.
///
/// A `UIView` subclass whose backing layer *is* the preview layer. This is the
/// standard approach: it lets AutoLayout/SwiftUI drive the layer's size
/// directly, instead of manually syncing `frame` in `layoutSubviews` (which
/// lags during rotation and produces a stretched preview).
final class CameraPreviewView: UIView {
    override static var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // Safe: `layerClass` above guarantees the type.
        // swift-format-ignore: NeverForceUnwrap
        layer as! AVCaptureVideoPreviewLayer
    }

    var session: AVCaptureSession? {
        get { previewLayer.session }
        set { previewLayer.session = newValue }
    }
}

/// SwiftUI wrapper around the preview layer.
struct CameraPreview: UIViewRepresentable {
    /// The running capture session, or nil before configuration completes.
    let session: AVCaptureSession?

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        // `.resizeAspectFill` matches the system camera app: fill the viewport
        // and crop, rather than letterboxing a room shot.
        view.previewLayer.videoGravity = .resizeAspectFill
        view.session = session
        return view
    }

    func updateUIView(_ view: CameraPreviewView, context: Context) {
        // Only reassign when it actually changed; setting `session` is not
        // free and this runs on every SwiftUI update.
        if view.session !== session {
            view.session = session
        }
    }
}
