/*
 * Portions copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * Use of the Meta Wearables Device Access Toolkit is subject to the license
 * found in the LICENSE file at the root of this repository.
 */

import Foundation
import MWDATCore
import Observation

@Observable
@MainActor
final class DeviceItemState: Identifiable {
  let identifier: DeviceIdentifier
  var linkState: LinkState
  var compatibility: Compatibility
  var deviceName: String
  var deviceTypeValue: String

  @ObservationIgnored private var linkStateToken: AnyListenerToken?

  nonisolated var id: DeviceIdentifier { identifier }

  init(device: Device) {
    identifier = device.identifier
    deviceName = device.nameOrId()
    deviceTypeValue = device.deviceType().rawValue
    linkState = device.linkState
    compatibility = device.compatibility()

    linkStateToken = device.addLinkStateListener { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        linkState = device.linkState
        compatibility = device.compatibility()
        deviceName = device.nameOrId()
      }
    }
  }
}

@Observable
@MainActor
final class WearablesViewModel {
  var deviceItemStates: [DeviceItemState] = []
  var registrationState: RegistrationState
  var showError = false
  var errorMessage = ""
  var requiresFirmwareUpdate = false

  @ObservationIgnored private var registrationTask: Task<Void, Never>?
  @ObservationIgnored private var deviceStreamTask: Task<Void, Never>?
  @ObservationIgnored private var deviceCompatibility: [DeviceIdentifier: Compatibility] = [:]
  @ObservationIgnored private var compatibilityListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]
  @ObservationIgnored private let wearables: WearablesInterface

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    registrationState = wearables.registrationState
    observeDevices()
    observeRegistration()
  }

  isolated deinit {
    registrationTask?.cancel()
    deviceStreamTask?.cancel()
    for token in compatibilityListenerTokens.values {
      Task { await token.cancel() }
    }
  }

  func connectGlasses() async {
    guard registrationState != .registering else { return }

    do {
      try await wearables.startRegistration()
    } catch {
      presentError(error.localizedDescription)
    }
  }

  func disconnectGlasses() async {
    do {
      try await wearables.startUnregistration()
    } catch {
      presentError(error.localizedDescription)
    }
  }

  func handleIncomingURL(_ url: URL) async {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
    else {
      return
    }

    do {
      _ = try await Wearables.shared.handleUrl(url)
    } catch let error as RegistrationError {
      presentError(error.description)
    } catch {
      presentError(error.localizedDescription)
    }
  }

  func openFirmwareUpdate() {
    Task {
      do {
        try await wearables.openFirmwareUpdate()
      } catch {
        presentError(error.localizedDescription)
      }
    }
  }

  func openDATGlassesAppUpdate() {
    Task {
      do {
        try await wearables.openDATGlassesAppUpdate()
      } catch {
        presentError(error.localizedDescription)
      }
    }
  }

  func dismissError() {
    showError = false
  }

  private func observeDevices() {
    deviceStreamTask = Task { [weak self] in
      guard let wearables = self?.wearables else { return }

      for await deviceIdentifiers in wearables.devicesStream() {
        guard let self, !Task.isCancelled else { return }
        deviceItemStates = deviceIdentifiers.compactMap { identifier in
          guard let device = wearables.deviceForIdentifier(identifier) else { return nil }
          return DeviceItemState(device: device)
        }
        monitorDeviceCompatibility(deviceIdentifiers)
      }
    }
  }

  private func observeRegistration() {
    registrationTask = Task { [weak self] in
      guard let wearables = self?.wearables else { return }

      for await state in wearables.registrationStateStream() {
        guard let self, !Task.isCancelled else { return }
        registrationState = state
      }
    }
  }

  private func monitorDeviceCompatibility(_ identifiers: [DeviceIdentifier]) {
    let currentIdentifiers = Set(identifiers)
    let removedIdentifiers = compatibilityListenerTokens.keys.filter {
      !currentIdentifiers.contains($0)
    }

    for identifier in removedIdentifiers {
      if let token = compatibilityListenerTokens.removeValue(forKey: identifier) {
        Task { await token.cancel() }
      }
      deviceCompatibility[identifier] = nil
    }

    for identifier in identifiers {
      guard compatibilityListenerTokens[identifier] == nil else { continue }
      guard let device = wearables.deviceForIdentifier(identifier) else { continue }

      deviceCompatibility[identifier] = device.compatibility()
      compatibilityListenerTokens[identifier] = device.addCompatibilityListener {
        [weak self] compatibility in
        Task { @MainActor [weak self] in
          self?.handleCompatibilityChange(compatibility, for: identifier)
        }
      }
    }

    updateFirmwareRequirement()
  }

  private func handleCompatibilityChange(
    _ compatibility: Compatibility,
    for identifier: DeviceIdentifier
  ) {
    deviceCompatibility[identifier] = compatibility
    deviceItemStates.first { $0.identifier == identifier }?.compatibility = compatibility
    updateFirmwareRequirement()
  }

  private func updateFirmwareRequirement() {
    requiresFirmwareUpdate = deviceCompatibility.values.contains(.deviceUpdateRequired)
  }

  private func presentError(_ message: String) {
    errorMessage = message
    showError = true
  }
}
