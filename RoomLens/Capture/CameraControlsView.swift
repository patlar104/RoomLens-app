//
//  CameraControlsView.swift
//  RoomLens
//
//  Manual control overlay for the live preview.
//

import SwiftUI

/// Minimal manual-control UI.
///
/// Slider changes are applied through `.task(id:)` instead of fire-and-forget
/// `Task {}` closures. That keeps work scoped to the view lifecycle: if the
/// capture view disappears, SwiftUI cancels the in-flight control task.
struct CameraControlsView: View {
    let camera: CameraModel

    /// Local mirrors exist only so sliders can track a drag smoothly. They are
    /// seeded from the model's applied values, never from hardcoded defaults,
    /// so re-appearing after a background/foreground cycle no longer resets
    /// the photographer's settings.
    @State private var requestedZoom: Double?
    @State private var requestedExposureBias: Double?
    @State private var requestedWhiteBalance: WhiteBalanceSetting?
    @State private var centerFocusRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CameraControlSlider(
                title: "Zoom",
                valueText: String(format: "%.1fx", camera.zoomFactor),
                value: binding(for: $requestedZoom, applied: camera.zoomFactor),
                range: 1...5)

            CameraControlSlider(
                title: "Exposure",
                valueText: String(format: "%+.1f EV", camera.exposureBias),
                value: binding(for: $requestedExposureBias, applied: camera.exposureBias),
                range: -3...3)

            CameraControlSlider(
                title: "White balance",
                valueText: "\(Int(camera.whiteBalance.temperature)) K",
                value: whiteBalanceTemperatureBinding,
                range: 2_500...7_500)

            HStack {
                Button("Focus center") {
                    centerFocusRequest += 1
                }
                .buttonStyle(.borderedProminent)

                if let controlError = camera.controlError {
                    Text(controlError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding()
        .task(id: requestedZoom) {
            guard let requestedZoom else { return }
            await camera.setZoomFactor(requestedZoom)
        }
        .task(id: requestedExposureBias) {
            guard let requestedExposureBias else { return }
            await camera.setExposureBias(requestedExposureBias)
        }
        .task(id: requestedWhiteBalance) {
            guard let requestedWhiteBalance else { return }
            await camera.setWhiteBalance(requestedWhiteBalance)
        }
        .task(id: centerFocusRequest) {
            guard centerFocusRequest > 0 else { return }
            await camera.setFocusPoint(.center)
        }
    }

    /// A slider binding that reads the model until the user actually moves it.
    private func binding(for request: Binding<Double?>, applied: Double) -> Binding<Double> {
        Binding {
            request.wrappedValue ?? applied
        } set: { newValue in
            request.wrappedValue = newValue
        }
    }

    private var whiteBalanceTemperatureBinding: Binding<Double> {
        Binding {
            (requestedWhiteBalance ?? camera.whiteBalance).temperature
        } set: { newValue in
            let current = requestedWhiteBalance ?? camera.whiteBalance
            requestedWhiteBalance = WhiteBalanceSetting(
                temperature: newValue,
                tint: current.tint)
        }
    }
}

private struct CameraControlSlider: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit())
            }
            Slider(value: $value, in: range)
        }
        .foregroundStyle(.primary)
    }
}
