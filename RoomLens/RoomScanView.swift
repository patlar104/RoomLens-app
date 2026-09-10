//
//  RoomScanView.swift
//  RoomLens
//
//  Room Scan: captures a room's geometry (planes + LiDAR mesh) via ARKit.
//

import ARKit
@preconcurrency import AVFoundation
import SceneKit
import SwiftUI
import UIKit

/// User-facing Room Scan availability.
///
/// Kept as a Sendable value type so the async resolver can be unit-tested without
/// starting ARKit or triggering a camera permission prompt.
nonisolated enum RoomScanAvailability: Equatable, Sendable {
    case checking
    case ready
    case unavailable(RoomScanUnavailableReason)
}

nonisolated enum RoomScanUnavailableReason: Equatable, Sendable {
    case unsupportedHardware
    case denied
    case restricted

    var isResolvableInSettings: Bool {
        self == .denied
    }

    var message: String {
        switch self {
        case .unsupportedHardware:
            "Room Scan needs a real iPhone or iPad with AR world-tracking support. The simulator cannot run the scan viewport."
        case .denied:
            "RoomLens needs camera access to run Room Scan. You can grant it in Settings."
        case .restricted:
            "Camera access is restricted on this device, so Room Scan cannot start."
        }
    }
}

/// Testable gate for entering Room Scan.
///
/// ARKit uses the camera, so it follows the same explicit authorization handling
/// rule as the capture stack instead of letting ARSession fail implicitly.
nonisolated struct RoomScanAvailabilityResolver: Sendable {
    private let authorization: CameraAuthorizing
    private let supportsWorldTracking: @Sendable () -> Bool

    init(
        authorization: CameraAuthorizing = SystemCameraAuthorization(),
        supportsWorldTracking: @escaping @Sendable () -> Bool = {
            ARWorldTrackingConfiguration.isSupported
        }
    ) {
        self.authorization = authorization
        self.supportsWorldTracking = supportsWorldTracking
    }

    func resolve() async -> RoomScanAvailability {
        guard supportsWorldTracking() else {
            return .unavailable(.unsupportedHardware)
        }

        switch authorization.status {
        case .authorized:
            return .ready
        case .notDetermined:
            return await authorization.requestAccess() ? .ready : .unavailable(.denied)
        case .denied:
            return .unavailable(.denied)
        case .restricted:
            return .unavailable(.restricted)
        @unknown default:
            return .unavailable(.restricted)
        }
    }
}

struct RoomScanView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var availability: RoomScanAvailability = .checking
    @State private var resetToken = 0

    private let resolver: RoomScanAvailabilityResolver

    init(resolver: RoomScanAvailabilityResolver = RoomScanAvailabilityResolver()) {
        self.resolver = resolver
    }

    var body: some View {
        Group {
            switch availability {
            case .checking:
                ProgressView("Checking AR support…")

            case .ready:
                ZStack {
                    ARViewport(resetToken: resetToken, isActive: scenePhase == .active)
                        .ignoresSafeArea()

                    ARReticle()

                    VStack {
                        RoomScanStatusBar()
                        Spacer()
                        RoomScanBottomBar(resetToken: $resetToken)
                    }
                    .padding()
                }

            case .unavailable(let reason):
                RoomScanUnavailableView(reason: reason)
                    .padding()
            }
        }
        .task {
            availability = await resolver.resolve()
        }
    }
}

private struct ARViewport: UIViewRepresentable {
    let resetToken: Int
    let isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(resetToken: resetToken)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = true
        view.autoenablesDefaultLighting = true
        view.debugOptions = [.showFeaturePoints, .showWorldOrigin]
        view.rendersContinuously = false

        if isActive {
            runSession(on: view, coordinator: context.coordinator, resetTracking: true)
        }

        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        if resetToken != context.coordinator.resetToken {
            context.coordinator.resetToken = resetToken
            runSession(on: view, coordinator: context.coordinator, resetTracking: true)
            return
        }

        switch (isActive, context.coordinator.isRunning) {
        case (true, false):
            runSession(on: view, coordinator: context.coordinator, resetTracking: false)
        case (false, true):
            view.session.pause()
            context.coordinator.isRunning = false
        default:
            break
        }
    }

    static func dismantleUIView(_ view: ARSCNView, coordinator: Coordinator) {
        view.session.pause()
        coordinator.isRunning = false
    }

    private func runSession(
        on view: ARSCNView,
        coordinator: Coordinator,
        resetTracking: Bool
    ) {
        guard ARWorldTrackingConfiguration.isSupported else { return }

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }

        let options: ARSession.RunOptions =
            resetTracking
            ? [.resetTracking, .removeExistingAnchors]
            : []
        view.session.run(configuration, options: options)
        coordinator.isRunning = true
    }

    final class Coordinator {
        var resetToken: Int
        var isRunning = false

        init(resetToken: Int) {
            self.resetToken = resetToken
        }
    }
}

private struct ARReticle: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.85), lineWidth: 1)
                .frame(width: 54, height: 54)
            Rectangle()
                .fill(.white.opacity(0.85))
                .frame(width: 2, height: 18)
            Rectangle()
                .fill(.white.opacity(0.85))
                .frame(width: 18, height: 2)
        }
        .shadow(radius: 4)
        .accessibilityHidden(true)
    }
}

private struct RoomScanStatusBar: View {
    var body: some View {
        HStack(spacing: 10) {
            Label("Room Scan", systemImage: "arkit")
                .font(.headline)
            Spacer()
            CapabilityPill(text: "Planes")
            CapabilityPill(text: meshCapabilityText)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var meshCapabilityText: String {
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            "LiDAR mesh + labels"
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            "LiDAR mesh"
        } else {
            "No LiDAR mesh"
        }
    }
}

private struct RoomScanBottomBar: View {
    @Binding var resetToken: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Move slowly around the room to let RoomLens find walls, floors, and depth features."
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Reset scan") {
                    resetToken += 1
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Label("Early access", systemImage: "hammer")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct CapabilityPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
    }
}

private struct RoomScanUnavailableView: View {
    let reason: RoomScanUnavailableReason

    var body: some View {
        ContentUnavailableView {
            Label("Room Scan unavailable", systemImage: "arkit")
        } description: {
            Text(reason.message)
        } actions: {
            if reason.isResolvableInSettings,
                let url = URL(string: UIApplication.openSettingsURLString)
            {
                Link("Open Settings", destination: url)
            }
        }
    }
}

#Preview("Room Scan") {
    RoomScanView()
}
