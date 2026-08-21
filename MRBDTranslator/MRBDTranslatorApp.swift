/*
 * Portions copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * Use of the Meta Wearables Device Access Toolkit is subject to the license
 * found in the LICENSE file at the root of this repository.
 */

import MWDATCore
import SwiftUI

private enum AppTab: Hashable {
  case translator
  case settings
}

@main
struct MRBDTranslatorApp: App {
  @State private var wearablesViewModel: WearablesViewModel
  @State private var displayViewModel: DisplayViewModel
  @State private var selectedTab: AppTab = .translator

  init() {
    do {
      try Wearables.configure()
    } catch {
      #if DEBUG
      NSLog("[MRBDTranslator] Failed to configure Wearables SDK: \(error)")
      #endif
    }

    let wearables = Wearables.shared
    _wearablesViewModel = State(wrappedValue: WearablesViewModel(wearables: wearables))
    _displayViewModel = State(wrappedValue: DisplayViewModel(wearables: wearables))
  }

  var body: some Scene {
    WindowGroup {
      TabView(selection: $selectedTab) {
        NavigationStack {
          TranslatorView(displayViewModel: displayViewModel)
        }
        .tabItem {
          Label("Translator", systemImage: "translate")
        }
        .tag(AppTab.translator)

        NavigationStack {
          SettingsView(
            viewModel: SettingsViewModel(
              registrationState: wearablesViewModel.registrationState,
              deviceItemStates: wearablesViewModel.deviceItemStates,
              requiresFirmwareUpdate: wearablesViewModel.requiresFirmwareUpdate,
              requiresDATAppUpdate: displayViewModel.requiresDATAppUpdate,
              connectGlasses: {
                Task { await wearablesViewModel.connectGlasses() }
              },
              disconnectGlasses: {
                Task { await wearablesViewModel.disconnectGlasses() }
              },
              openFirmwareUpdate: wearablesViewModel.openFirmwareUpdate,
              openDATGlassesAppUpdate: wearablesViewModel.openDATGlassesAppUpdate
            )
          )
        }
        .tabItem {
          Label("Settings", systemImage: "gearshape")
        }
        .tag(AppTab.settings)
      }
      .onOpenURL { url in
        Task { await wearablesViewModel.handleIncomingURL(url) }
      }
      .onChange(of: displayViewModel.didFailToStartSession) { _, didFail in
        guard didFail else { return }
        selectedTab = .settings
        displayViewModel.clearSessionStartFailure()
      }
      .alert("Registration error", isPresented: $wearablesViewModel.showError) {
        Button("OK") { wearablesViewModel.dismissError() }
      } message: {
        Text(wearablesViewModel.errorMessage)
      }
    }
  }
}

