/*
 * Portions copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * Use of the Meta Wearables Device Access Toolkit is subject to the license
 * found in the LICENSE file at the root of this repository.
 */

import Foundation
import MWDATCore
import MWDATDisplay
import Observation

@Observable
@MainActor
final class DisplayViewModel {
  var isConnected = false
  var isSending = false
  var errorMessage: String?
  var requiresDATAppUpdate = false
  var didFailToStartSession = false

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private var deviceSelector: AutoDeviceSelector
  @ObservationIgnored private var deviceSession: DeviceSession?
  @ObservationIgnored private var display: Display?
  @ObservationIgnored private var displayStateToken: AnyListenerToken?
  @ObservationIgnored private var sessionStateTask: Task<Void, Never>?
  @ObservationIgnored private var sessionErrorTask: Task<Void, Never>?
  @ObservationIgnored private var registrationTask: Task<Void, Never>?
  @ObservationIgnored private var pendingTranslation: PendingTranslation?

  private struct PendingTranslation {
    let english: String
    let japanese: String
  }

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    deviceSelector = AutoDeviceSelector(
      wearables: wearables,
      filter: { $0.supportsDisplay() }
    )
    observeRegistration()
  }

  isolated deinit {
    sessionStateTask?.cancel()
    sessionErrorTask?.cancel()
    registrationTask?.cancel()
  }

  func attachToDisplay() async {
    guard deviceSession == nil, display == nil else { return }

    errorMessage = nil
    didFailToStartSession = false

    do {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session

      let stateStream = session.stateStream()
      let errorStream = session.errorStream()

      sessionStateTask = Task { [weak self] in
        for await state in stateStream {
          guard let self, !Task.isCancelled else { return }
          await self.handleSessionState(state, session: session)
        }
      }

      sessionErrorTask = Task { [weak self] in
        for await error in errorStream {
          guard let self, !Task.isCancelled else { return }
          self.handleSessionError(error)
        }
      }

      try session.start()
    } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
      requiresDATAppUpdate = true
      didFailToStartSession = true
      errorMessage = DeviceSessionError.datAppOnTheGlassesUpdateRequired.localizedDescription
      clearSessionReferences(stopHardware: true)
    } catch {
      requiresDATAppUpdate = false
      didFailToStartSession = true
      errorMessage = "Failed to start the display session: \(error.localizedDescription)"
      clearSessionReferences(stopHardware: true)
    }
  }

  func sendTranslation(english: String, japanese: String) async {
    let cleanEnglish = english.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanJapanese = japanese.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanEnglish.isEmpty, !cleanJapanese.isEmpty else { return }

    pendingTranslation = PendingTranslation(
      english: cleanEnglish,
      japanese: cleanJapanese
    )

    if isConnected {
      await flushPendingTranslation()
    } else {
      await attachToDisplay()
    }
  }

  func detachFromDisplay() {
    pendingTranslation = nil
    clearSessionReferences(stopHardware: true)
  }

  func clearSessionStartFailure() {
    didFailToStartSession = false
  }

  func clearError() {
    errorMessage = nil
  }

  private func observeRegistration() {
    registrationTask = Task { [weak self] in
      guard let wearables = self?.wearables else { return }

      for await state in wearables.registrationStateStream() {
        guard let self, !Task.isCancelled else { return }
        if state == .available || state == .unavailable {
          self.detachFromDisplay()
          self.deviceSelector = AutoDeviceSelector(
            wearables: wearables,
            filter: { $0.supportsDisplay() }
          )
        }
      }
    }
  }

  private func handleSessionState(
    _ state: DeviceSessionState,
    session: DeviceSession
  ) async {
    switch state {
    case .started:
      requiresDATAppUpdate = false
      didFailToStartSession = false
      await setupDisplay(on: session)
    case .stopping, .stopped:
      clearSessionReferences(stopHardware: false)
    case .idle, .starting, .paused:
      break
    @unknown default:
      break
    }
  }

  private func setupDisplay(on session: DeviceSession) async {
    guard display == nil else { return }

    do {
      let capability = try session.addDisplay()
      display = capability

      displayStateToken = capability.statePublisher.listen { [weak self] state in
        Task { @MainActor [weak self] in
          await self?.handleDisplayState(state)
        }
      }

      capability.start()
    } catch {
      errorMessage = "Failed to start the glasses display: \(error.localizedDescription)"
    }
  }

  private func handleDisplayState(_ state: DisplayState) async {
    switch state {
    case .started:
      isConnected = true
      await flushPendingTranslation()
    case .starting:
      break
    case .stopping:
      isConnected = false
    case .stopped:
      clearSessionReferences(stopHardware: false)
    }
  }

  private func flushPendingTranslation() async {
    guard let pendingTranslation, let display, isConnected else { return }

    self.pendingTranslation = nil
    isSending = true
    defer { isSending = false }

    do {
      try await display.send(
        TranslationDisplay.make(
          english: pendingTranslation.english,
          japanese: pendingTranslation.japanese
        )
      )
    } catch {
      errorMessage = (error as? DisplayError)?.description ?? error.localizedDescription
    }
  }

  private func handleSessionError(_ error: DeviceSessionError) {
    requiresDATAppUpdate = error == .datAppOnTheGlassesUpdateRequired
    didFailToStartSession = true
    errorMessage = error.localizedDescription
  }

  private func clearSessionReferences(stopHardware: Bool) {
    let currentDisplay = display
    let currentSession = deviceSession

    displayStateToken = nil
    sessionStateTask?.cancel()
    sessionStateTask = nil
    sessionErrorTask?.cancel()
    sessionErrorTask = nil
    display = nil
    deviceSession = nil
    isConnected = false

    if stopHardware {
      currentDisplay?.stop()
      currentSession?.stop()
    }
  }
}
