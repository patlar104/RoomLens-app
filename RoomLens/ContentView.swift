//
//  ContentView.swift
//  RoomLens
//
//  Created by patrick larocque on 2026-09-02.
//

import SwiftUI

struct ContentView: View {
    @State private var camera = CameraModel()
    @State private var mode = RoomLensMode.camera
    @State private var isRoomScanReady = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .top) {
            modeContent

            RoomLensModePicker(selection: $mode)
                .padding(.horizontal)
                .padding(.top, 12)
        }
        // The capture layer is the authority on session state: interruptions
        // and runtime errors happen without the app asking. This long-lived
        // task mirrors them, so the UI cannot keep showing a dead preview.
        .task {
            await camera.observeState()
        }
        // Drives the camera from both app lifecycle and the selected workspace.
        // ARKit also needs the camera, so switching into Room Scan releases
        // the AVFoundation session before the AR viewport starts.
        .task(id: "\(scenePhase)-\(mode.rawValue)") {
            await updateCameraLifecycle()
        }
    }

    @ViewBuilder
    private var modeContent: some View {
        switch mode {
        case .camera:
            cameraContent
        case .roomScan:
            if isRoomScanReady {
                RoomScanView()
            } else {
                ProgressView("Opening Room Scan…")
            }
        }
    }

    @ViewBuilder
    private var cameraContent: some View {
        switch camera.state {
        case .idle, .preparing:
            ProgressView("Preparing camera…")

        case .running:
            ZStack(alignment: .bottom) {
                CameraPreview(session: camera.previewSession)
                    // The preview fills the screen; a room shot letterboxed
                    // into a padded box would defeat the point.
                    .ignoresSafeArea()

                CameraControlsView(camera: camera)
            }

        case .interrupted(let reason):
            CameraInterruptedView(reason: reason)
                .padding()

        case .unavailable(let reason):
            CameraUnavailableView(reason: reason)
                .padding()
        }
    }

    private func updateCameraLifecycle() async {
        guard scenePhase == .active else {
            isRoomScanReady = false
            await camera.stop()
            return
        }

        switch mode {
        case .camera:
            isRoomScanReady = false
            await camera.resume()
        case .roomScan:
            // ARKit also owns the camera. Do not construct the AR viewport until
            // the AVFoundation session has fully stopped, or both stacks can
            // race for camera ownership on real hardware.
            await camera.stop()
            guard !Task.isCancelled, scenePhase == .active, mode == .roomScan else {
                return
            }
            isRoomScanReady = true
        }
    }
}

private enum RoomLensMode: String, CaseIterable, Identifiable {
    case camera
    case roomScan

    var id: Self { self }

    var title: String {
        switch self {
        case .camera:
            "Camera"
        case .roomScan:
            "Room Scan"
        }
    }
}

private struct RoomLensModePicker: View {
    @Binding var selection: RoomLensMode

    var body: some View {
        Picker("RoomLens mode", selection: $selection) {
            ForEach(RoomLensMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(8)
        .background(.ultraThinMaterial, in: Capsule())
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
        case .sessionFailed(let detail):
            "The camera stopped working. \(detail)"
        }
    }
}

/// Shown while the system holds the camera. Deliberately offers no Settings
/// link: an interruption resolves itself, and the capture layer restarts the
/// session when it ends.
private struct CameraInterruptedView: View {
    let reason: CaptureInterruptionReason

    var body: some View {
        ContentUnavailableView {
            Label("Camera paused", systemImage: "pause.circle")
        } description: {
            Text(message)
        }
    }

    private var message: String {
        switch reason {
        case .cameraInUseByAnotherClient:
            "Another app is using the camera. RoomLens will resume automatically."
        case .videoDeviceNotAvailableInBackground:
            "The camera is unavailable right now. RoomLens will resume automatically."
        case .unknown:
            "The system paused the camera. RoomLens will resume automatically."
        }
    }
}

#Preview {
    ContentView()
}
