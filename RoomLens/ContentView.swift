//
//  ContentView.swift
//  RoomLens
//
//  Created by patrick larocque on 2026-09-02.
//

import SwiftUI

struct ContentView: View {
    @State private var camera = CameraModel()

    var body: some View {
        Group {
            switch camera.state {
            case .idle, .preparing:
                ProgressView("Preparing camera…")

            case .running:
                CameraPreview(session: camera.previewSession)
                    // The preview fills the screen; a room shot letterboxed
                    // into a padded box would defeat the point.
                    .ignoresSafeArea()

            case .unavailable(let reason):
                CameraUnavailableView(reason: reason)
                    .padding()
            }
        }
        // `.task` is cancelled automatically when the view disappears, which
        // is why no free-standing `Task {}` is used here.
        .task {
            await camera.prepare()
        }
    }
}

/// Explains why the camera cannot run, and offers Settings only when that
/// would actually help.
private struct CameraUnavailableView: View {
    let reason: CaptureUnavailableReason

    var body: some View {
        ContentUnavailableView {
            Label("Camera unavailable", systemImage: "camera.fill")
        } description: {
            Text(message)
        } actions: {
            if reason.isResolvableInSettings,
                let url = URL(string: UIApplication.openSettingsURLString)
            {
                Link("Open Settings", destination: url)
            }
        }
    }

    private var message: String {
        switch reason {
        case .denied:
            "RoomLens needs camera access to capture rooms. You can grant it in Settings."
        case .restricted:
            "Camera access is restricted on this device."
        case .noCaptureDevice:
            "No camera is available on this device."
        case .configurationFailed(let detail):
            "The camera could not be configured. \(detail)"
        }
    }
}

#Preview {
    ContentView()
}
