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

    @State private var requestedZoom = 1.0
    @State private var requestedExposureBias = 0.0
    @State private var requestedWhiteBalance = WhiteBalanceSetting.neutral
    @State private var centerFocusRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CameraControlSlider(
                title: "Zoom",
                valueText: String(format: "%.1fx", camera.zoomFactor),
                value: $requestedZoom,
                range: 1...5)

            CameraControlSlider(
                title: "Exposure",
                valueText: String(format: "%+.1f EV", camera.exposureBias),
                value: $requestedExposureBias,
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
            await camera.setZoomFactor(requestedZoom)
        }
        .task(id: requestedExposureBias) {
            await camera.setExposureBias(requestedExposureBias)
        }
        .task(id: requestedWhiteBalance) {
            await camera.setWhiteBalance(requestedWhiteBalance)
        }
        .task(id: centerFocusRequest) {
            guard centerFocusRequest > 0 else { return }
            await camera.setFocusPoint(.center)
        }
    }

    private var whiteBalanceTemperatureBinding: Binding<Double> {
        Binding {
            requestedWhiteBalance.temperature
        } set: { newValue in
            requestedWhiteBalance = WhiteBalanceSetting(
                temperature: newValue,
                tint: requestedWhiteBalance.tint)
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
