# MRBD English–Japanese Translator

An iPhone app that listens to spoken English, translates it into Japanese, and displays the result on Meta Ray-Ban Display glasses.

The app uses Apple's on-device Speech and Translation frameworks for the language pipeline and Meta's Wearables Device Access Toolkit (DAT) to render the English transcript and Japanese translation on the glasses.

## What it does

1. Captures English speech with the iPhone microphone.
2. Produces live English transcription with `SpeechAnalyzer`.
3. Translates stable speech segments from English to Japanese.
4. Shows both languages in the iPhone app.
5. Sends the latest translation to Meta Ray-Ban Display glasses.

## Requirements

- Xcode 26 or later
- An iPhone running iOS 26.0 or later
- Meta AI app installed on the iPhone
- Meta Ray-Ban Display glasses with compatible firmware
- Developer Mode enabled for the glasses in the Meta AI app
- A Meta Wearables developer project or Developer Mode configuration

This project depends on version `0.9.0` of [`meta-wearables-dat-ios`](https://github.com/facebook/meta-wearables-dat-ios) through Swift Package Manager.

> Regular Ray-Ban Meta glasses do not have a display. The visual-output portion of this app requires Meta Ray-Ban Display glasses.

## Setup

1. Clone the repository:

   ```bash
   git clone git@github.com:hka233/MRBD-Translation-EN-JP.git
   cd MRBD-Translation-EN-JP
   ```

2. Open `MRBDTranslator.xcodeproj` in Xcode.

3. Select the **MRBDTranslator** target, then open **Signing & Capabilities**:
   - Choose your Apple Developer team.
   - Replace `com.example.MRBDTranslator` with a unique bundle identifier.

4. Check the target's user-defined build settings:
   - `META_APP_ID` defaults to `0` for Developer Mode.
   - `CLIENT_TOKEN` is blank by default. Add the value required by your Meta Wearables project, if applicable.
   - Do not commit production tokens or private credentials.

5. In the Meta AI app, enable **Developer Mode** for the connected glasses.

6. Build and run on a physical iPhone. The simulator cannot test the real microphone-to-glasses workflow.

7. Open **Settings** in the app and tap **Register**. Complete the registration flow in Meta AI.

8. Return to **Translator**, tap **Start Translation**, and approve the microphone and language-model prompts when requested.

The first run may need to download English speech-recognition and English–Japanese translation assets.

## Project structure

```text
MRBDTranslator/
├── MRBDTranslatorApp.swift          App entry point and navigation
├── Audio/
│   └── SpeechViewModel.swift        Microphone capture and SpeechAnalyzer
├── Display/
│   ├── DisplayViewModel.swift       Meta display-session lifecycle
│   └── TranslationDisplay.swift     Layout rendered on the glasses
├── ViewModels/
│   └── WearablesViewModel.swift     Registration and device state
└── Views/
    ├── TranslatorView.swift         Translation UI and queue
    └── SettingsView.swift           Registration and compatibility UI
```

## How partial speech is handled

Speech recognition produces volatile results before it finalizes an utterance. The app waits briefly for a volatile result to stabilize, translates the newest candidate, and later replaces it with the finalized translation. Pending volatile requests are coalesced so old partial sentences do not build up behind newer speech.

## Privacy

This project does not contain a custom analytics service, translation server, or audio-recording store. Microphone buffers are passed to Apple's speech APIs, and translated text is sent to the connected display through Meta's SDK. Review Apple's and Meta's applicable privacy terms before distributing the app.

## Troubleshooting

- **No glasses appear:** Confirm Bluetooth is enabled, the glasses are connected in Meta AI, and Developer Mode is still on. Firmware updates can disable Developer Mode.
- **Registration fails:** Confirm the URL scheme and Meta build settings match your Wearables project.
- **The app reports an update requirement:** Use the update action shown in Settings for the glasses firmware or DAT app.
- **Speech does not start:** Check microphone permission in iOS Settings and confirm the English speech model can be installed.
- **Translation does not start:** Connect to the internet once so iOS can download the required language assets.
- **Nothing appears on the glasses:** Confirm the connected device supports Display and that its SDK, Meta AI app, and firmware versions are compatible.

## Limitations

- Audio currently comes from the iPhone microphone, not the glasses microphones.
- The language pair is fixed to English (`en-US`) → Japanese (`ja`).
- Meta Wearables DAT is a developer-preview SDK, so compatible app and firmware versions may change.
- Low-latency translation is requested on iOS 26.4 or later; earlier iOS 26 releases use the default translation strategy.

## Attribution and license

The connection and display-session code is derived from Meta's DisplayAccess sample. Meta copyright notices are retained in the relevant files. Use of the Meta Wearables Device Access Toolkit is subject to the terms in [LICENSE](LICENSE) and Meta's linked developer policies.

