/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// DisplayViewModel.swift
//
// Manages the display session lifecycle: attaching to a display-capable device,
// sending views, and detaching. Uses DSPN's pending action pattern so that
// tapping "play" auto-attaches and sends the view once the display is ready.
//

import MWDATCore
import MWDATDisplay
import Observation
import SwiftUI

@Observable
@MainActor
class DisplayViewModel {
  var isConnected: Bool = false
  var isSending: Bool = false
  var errorMessage: String?
  var requiresDATAppUpdate: Bool = false
  var didFailToStartSession: Bool = false

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private var deviceSelector: AutoDeviceSelector
  @ObservationIgnored private var deviceSession: DeviceSession?
  @ObservationIgnored private var display: Display?
  @ObservationIgnored private var stateListenerToken: AnyListenerToken?
  @ObservationIgnored private var coreStateTask: Task<Void, Never>?
  @ObservationIgnored private var sessionErrorTask: Task<Void, Never>?
  @ObservationIgnored private var registrationTask: Task<Void, Never>?
  @ObservationIgnored private var displayStateTask: Task<Void, Never>?
  @ObservationIgnored private var displayStateContinuation: AsyncStream<DisplayState>.Continuation?
  @ObservationIgnored private var pendingAction: (() async -> Void)?

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.deviceSelector = AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
    observeRegistration()
  }

  isolated deinit {
    stateListenerToken = nil
    coreStateTask?.cancel()
    sessionErrorTask?.cancel()
    registrationTask?.cancel()
    displayStateTask?.cancel()
  }

  // MARK: - Registration Observation

  private func observeRegistration() {
    registrationTask = Task { [weak self] in
      guard let wearables = self?.wearables else { return }
      for await state in wearables.registrationStateStream() {
        guard let self, !Task.isCancelled else { return }
        if state == .available || state == .unavailable {
          self.resetDisplaySession()
        }
      }
    }
  }

  private func resetDisplaySession() {
    detachFromDisplay()
    deviceSelector = AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
  }

  // MARK: - Public API

  /// Sends a display view to the glasses. Auto-attaches if not connected;
  /// the view is queued and sent once the display session is ready.
    func send(_ view: some DisplayableView) async {
        print("===== SEND CALLED =====")
        print("display exists:", display != nil)
        print("isConnected:", isConnected)

        if let display, isConnected {
            print("Already connected; sending directly")
            await doSend(view, on: display)
            return
        }

        print("Queueing pending display action")

        let sendableView = view
        pendingAction = { [weak self] in
            guard let self, let cap = self.display else {
                print("PENDING ACTION FAILED: display is nil")
                return
            }

            print("Executing pending action")
            await self.doSend(sendableView, on: cap)
        }

        if display == nil {
            print("Display nil → attachToDisplay")
            await attachToDisplay()
        }
    }

    private func doSend(
        _ view: some DisplayableView,
        on capability: Display
    ) async {

        print("===== ACTUALLY SENDING VIEW =====")

        isSending = true
        defer { isSending = false }

        do {
            try await capability.send(view)

            print("===== SEND SUCCEEDED =====")

        } catch {
            print("!!!!! SEND FAILED !!!!!")
            print(error)
            print(error.localizedDescription)

            let message =
                (error as? DisplayError)?.description
                ?? error.localizedDescription

            errorMessage = message
        }
    }

  // MARK: - Session Management

    func attachToDisplay() async {
        print("===== ATTACH TO DISPLAY =====")

        guard display == nil else {
            print("Display already exists; returning")
            return
        }

        didFailToStartSession = false

        do {
            print("Creating DeviceSession...")

            let devSession = try wearables.createSession(
                deviceSelector: deviceSelector
            )

            print("DeviceSession created successfully")

            deviceSession = devSession

            let stateStream = devSession.stateStream()
            let errorStream = devSession.errorStream()

            coreStateTask = Task { [weak self] in
                for await sessionState in stateStream {
                    guard let self, !Task.isCancelled else { return }

                    print("DEVICE SESSION STATE:", sessionState)

                    switch sessionState {
                    case .started:
                        print("DEVICE SESSION STARTED")
                        self.requiresDATAppUpdate = false
                        self.didFailToStartSession = false

                        print("Calling setupDisplay")
                        await self.setupDisplay(on: devSession)

                    case .stopping:
                        print("DEVICE SESSION STOPPING")
                        self.isConnected = false
                        self.display = nil

                    case .stopped:
                        print("DEVICE SESSION STOPPED")
                        self.isConnected = false
                        self.display = nil

                    case .starting:
                        print("DEVICE SESSION STARTING")

                    case .idle:
                        print("DEVICE SESSION IDLE")

                    case .paused:
                        print("DEVICE SESSION PAUSED")

                    @unknown default:
                        print("UNKNOWN DEVICE SESSION STATE")
                    }
                }
            }

            sessionErrorTask = Task { [weak self] in
                for await error in errorStream {
                    guard let self, !Task.isCancelled else { return }

                    print("!!!!! DEVICE SESSION ERROR !!!!!")
                    print(error)
                    print(error.localizedDescription)

                    self.handleSessionError(error)
                }
            }

            print("Calling devSession.start()")

            try devSession.start()

            print("devSession.start() returned")

        } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
            print("DAT APP UPDATE REQUIRED")

            requiresDATAppUpdate = true
            didFailToStartSession = true
            errorMessage =
                DeviceSessionError.datAppOnTheGlassesUpdateRequired.localizedDescription

        } catch {
            print("!!!!! CREATE/START SESSION FAILED !!!!!")
            print(error)
            print(error.localizedDescription)

            requiresDATAppUpdate = false
            didFailToStartSession = true
            errorMessage =
                "Failed to create session: \(error.localizedDescription)"
        }
    }

  func clearSessionStartFailure() {
    didFailToStartSession = false
  }

    private func setupDisplay(on devSession: DeviceSession) async {
        print("===== SETUP DISPLAY =====")

        guard display == nil else {
            print("Display already exists")
            return
        }

        do {
            print("Calling addDisplay()")

            let capability = try devSession.addDisplay()

            print("addDisplay() succeeded")

            let (stateStream, continuation) =
                AsyncStream.makeStream(of: DisplayState.self)

            displayStateContinuation = continuation

            stateListenerToken = capability.statePublisher.listen { state in
                print("DISPLAY PUBLISHER STATE:", state)
                continuation.yield(state)
            }

            displayStateTask = Task { [weak self] in
                for await state in stateStream {
                    guard let self, !Task.isCancelled else { return }

                    print("DISPLAY STATE:", state)

                    switch state {
                    case .starting:
                        print("DISPLAY STARTING")

                    case .started:
                        print("===== DISPLAY STARTED =====")
                        self.isConnected = true

                        if let action = self.pendingAction {
                            print("Running pending action")
                            self.pendingAction = nil
                            await action()
                        } else {
                            print("No pending action!")
                        }

                    case .stopping:
                        print("DISPLAY STOPPING")
                        self.isConnected = false

                    case .stopped:
                        print("DISPLAY STOPPED")
                        self.isConnected = false

                        self.stateListenerToken = nil
                        self.displayStateContinuation?.finish()
                        self.displayStateContinuation = nil
                        self.display = nil

                        self.coreStateTask?.cancel()
                        self.coreStateTask = nil

                        self.sessionErrorTask?.cancel()
                        self.sessionErrorTask = nil

                        self.deviceSession?.stop()
                        self.deviceSession = nil
                    }
                }
            }

            print("Calling capability.start()")

            capability.start()

            print("capability.start() returned")

            display = capability

        } catch {
            print("!!!!! ADD DISPLAY FAILED !!!!!")
            print(error)
            print(error.localizedDescription)

            errorMessage =
                "Failed to start display: \(error.localizedDescription)"
        }
    }

  // MARK: - Car Maintenance

    func sendCarMaintenanceTutorialList() async {
        await send(
            CarMaintenanceDisplay.helloWorld()
        )
    }

  func sendCarMaintenanceTutorialDetail(tutorialIndex: Int) async {
    await send(
      CarMaintenanceDisplay.tutorialDetail(
        tutorialIndex: tutorialIndex,
        onBack: { [weak self] in
          Task { @MainActor in
            await self?.sendCarMaintenanceTutorialList()
          }
        },
        onStart: { [weak self] in
          Task { @MainActor in
            await self?.sendCarMaintenanceTutorialStep(tutorialIndex: tutorialIndex, stepIndex: 0)
          }
        }
      )
    )
  }

  func sendTutorialVideo(tutorialIndex: Int, stepIndex: Int) async {
    await send(CarMaintenanceDisplay.tutorialVideo())
    display?.onPlaybackEvent = { [weak self] event in
      if event.type == .ended || event.type == .stopped {
        Task { @MainActor [weak self] in
          self?.display?.onPlaybackEvent = nil
          await self?.sendCarMaintenanceTutorialStep(
            tutorialIndex: tutorialIndex,
            stepIndex: stepIndex
          )
        }
      }
    }
  }

  func sendCarMaintenanceTutorialStep(tutorialIndex: Int, stepIndex: Int) async {
    let isLastStep = stepIndex == CarMaintenanceDisplay.tutorials[tutorialIndex].steps.count - 1
    await send(
      CarMaintenanceDisplay.tutorialStep(
        tutorialIndex: tutorialIndex,
        stepIndex: stepIndex,
        onPrevious: { [weak self] in
          Task { @MainActor in
            if stepIndex == 0 {
              await self?.sendCarMaintenanceTutorialDetail(tutorialIndex: tutorialIndex)
            } else {
              await self?.sendCarMaintenanceTutorialStep(
                tutorialIndex: tutorialIndex,
                stepIndex: stepIndex - 1
              )
            }
          }
        },
        onNext: { [weak self] in
          Task { @MainActor in
            if isLastStep {
              await self?.sendCarMaintenanceTutorialList()
            } else {
              await self?.sendCarMaintenanceTutorialStep(
                tutorialIndex: tutorialIndex,
                stepIndex: stepIndex + 1
              )
            }
          }
        },
        onWatchVideo: { [weak self] in
          Task { @MainActor in
            await self?.sendTutorialVideo(tutorialIndex: tutorialIndex, stepIndex: stepIndex)
          }
        }
      )
    )
  }

  func detachFromDisplay() {
    if let display {
      display.stop()
    } else {
      coreStateTask?.cancel()
      coreStateTask = nil
      sessionErrorTask?.cancel()
      sessionErrorTask = nil
      deviceSession?.stop()
      deviceSession = nil
    }
  }

  private func handleSessionError(_ error: DeviceSessionError) {
    requiresDATAppUpdate = error == .datAppOnTheGlassesUpdateRequired
    didFailToStartSession = true
    errorMessage = error.localizedDescription
  }
    
    func sendTranslation(
        english: String,
        japanese: String
    ) async {
        await send(
            CarMaintenanceDisplay.translation(
                english: english,
                japanese: japanese
            )
        )
    }
    
}


