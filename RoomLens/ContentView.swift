//
//  ContentView.swift
//  RoomLens
//
//  Created by patrick larocque on 2026-09-02.
//

import SwiftUI

struct ContentView: View {
    @State private var camera = CameraModel()
    @Environment(\.scenePhase) private var scenePhase

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
        // Drives the session from the app lifecycle. `.task(id:)` re-runs on
        // each phase change and is cancelled when the view disappears, so no
        // free-standing `Task {}` is needed (per the project conventions).
        //
        // Releasing the camera when not frontmost matters: a running capture
        // session drains the battery, and iOS may terminate an app that holds
        // the camera in the background.
        .task(id: scenePhase) {
            switch scenePhase {
            case .active:
                await camera.resume()
            case .inactive, .background:
                await camera.stop()
            @unknown default:
                await camera.stop()
            }
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
