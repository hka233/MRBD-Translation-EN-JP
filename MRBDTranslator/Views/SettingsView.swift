/*
 * Portions copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * Use of the Meta Wearables Device Access Toolkit is subject to the license
 * found in the LICENSE file at the root of this repository.
 */

import MWDATCore
import SwiftUI

struct SettingsViewModel {
  let registrationState: RegistrationState
  let deviceItemStates: [DeviceItemState]
  let requiresFirmwareUpdate: Bool
  let requiresDATAppUpdate: Bool
  let connectGlasses: () -> Void
  let disconnectGlasses: () -> Void
  let openFirmwareUpdate: () -> Void
  let openDATGlassesAppUpdate: () -> Void
}

struct SettingsView: View {
  let viewModel: SettingsViewModel

  var body: some View {
    List {
      Section("Registration") {
        HStack {
          Image(systemName: registrationIcon)
            .foregroundStyle(registrationColor)
          Text(registrationLabel)
            .foregroundStyle(registrationColor)
          Spacer()
          registrationAction
        }
      }

      if viewModel.requiresFirmwareUpdate || viewModel.requiresDATAppUpdate {
        Section("Compatibility") {
          if viewModel.requiresFirmwareUpdate {
            Button("Update glasses firmware", action: viewModel.openFirmwareUpdate)
          }
          if viewModel.requiresDATAppUpdate {
            Button("Update DAT app on glasses", action: viewModel.openDATGlassesAppUpdate)
          }
        }
      }

      Section("Devices") {
        if viewModel.deviceItemStates.isEmpty {
          Text("No devices found")
            .foregroundStyle(.secondary)
        } else {
          ForEach(viewModel.deviceItemStates) { device in
            DeviceRow(device: device)
          }
        }
      }
    }
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var registrationLabel: String {
    switch viewModel.registrationState {
    case .unavailable:
      "Unavailable"
    case .available:
      "Not registered"
    case .registering:
      "Registering…"
    case .registered:
      "Registered"
    @unknown default:
      "Unknown"
    }
  }

  private var registrationIcon: String {
    switch viewModel.registrationState {
    case .registered:
      "checkmark.circle.fill"
    case .registering:
      "ellipsis.circle.fill"
    case .unavailable, .available:
      "xmark.circle.fill"
    @unknown default:
      "questionmark.circle.fill"
    }
  }

  private var registrationColor: Color {
    switch viewModel.registrationState {
    case .registered:
      .green
    case .registering:
      .orange
    case .unavailable:
      .red
    case .available:
      .yellow
    @unknown default:
      .gray
    }
  }

  @ViewBuilder
  private var registrationAction: some View {
    switch viewModel.registrationState {
    case .registered:
      Button("Unregister", role: .destructive, action: viewModel.disconnectGlasses)
    case .unavailable, .available:
      Button("Register", action: viewModel.connectGlasses)
    case .registering:
      ProgressView()
    @unknown default:
      EmptyView()
    }
  }
}

private struct DeviceRow: View {
  let device: DeviceItemState

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(device.deviceName)
          .font(.headline)
        Text(device.deviceTypeValue)
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Text(device.identifier)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Text(statusLabel)
        .font(.caption.weight(.medium))
        .foregroundStyle(statusColor)
    }
  }

  private var statusLabel: String {
    if device.compatibility == .deviceUpdateRequired {
      return "Update required"
    }

    switch device.linkState {
    case .disconnected:
      "Disconnected"
    case .connecting:
      "Connecting"
    case .connected:
      "Connected"
    @unknown default:
      "Unknown"
    }
  }

  private var statusColor: Color {
    if device.compatibility == .deviceUpdateRequired {
      return .orange
    }

    switch device.linkState {
    case .disconnected:
      .red
    case .connecting:
      .orange
    case .connected:
      .green
    @unknown default:
      .gray
    }
  }
}

