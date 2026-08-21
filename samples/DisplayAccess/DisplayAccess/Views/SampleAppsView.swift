/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// SampleAppsView.swift
//
// Main screen listing available sample apps that demonstrate DAT SDK Display features.
// Each sample shows an icon, title, and description at the top with a "Try it" button
// pinned to the bottom of the screen that sends the display view to the glasses.
//

import SwiftUI
import Translation

@available(iOS 18.0, *)
struct SampleAppsView: View {
    var displayViewModel: DisplayViewModel
    
    @State private var speechViewModel = SpeechViewModel()

    @State private var japaneseText = ""
    @State private var translationError: String?
    @State private var isTranslating = false

    @State private var translationConfig:
        TranslationSession.Configuration?
    
    @State private var isContinuousMode = false
    @State private var isRestartingSpeech = false
    
    @State private var lastTranslatedText = ""
    @State private var isProcessingTranslation = false
    @State private var committedTranscript = ""
    
    @State private var translationQueue: [String] = []
    @State private var isProcessingQueue = false
    
    @State private var volatileTranslationTask: Task<Void, Never>?
    @State private var lastQueuedSpeech = ""
    
    var body: some View {
        VStack(spacing: 24) {

            Image(systemName: "translate")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(.blue, in: RoundedRectangle(cornerRadius: 16))
                .padding(.top, 48)

            Text("Ray-Ban Translator")
                .font(.title2.weight(.semibold))

            Text("English → Japanese")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {

                Text("English transcription")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(
                    speechViewModel.transcription.isEmpty
                    ? "Speak English..."
                    : speechViewModel.transcription
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: 70,
                    alignment: .topLeading
                )
                .padding()
                .background(
                    Color.secondary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }

            VStack(alignment: .leading, spacing: 8) {

                Text("Japanese")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(
                    japaneseText.isEmpty
                    ? "翻訳結果がここに表示されます"
                    : japaneseText
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: 70,
                    alignment: .topLeading
                )
                .padding()
                .background(
                    Color.secondary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }

            //Spacer()
/*
            Button {
                let text = speechViewModel.transcription
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard !text.isEmpty else {
                    translationError = "There is no English text to translate."
                    print("TRANSLATION: source text was empty")
                    return
                }

                print("===== TRANSLATE PRESSED =====")
                print("SOURCE:", text)

                if translationConfig == nil {
                    translationConfig =
                        TranslationSession.Configuration(
                            source: Locale.Language(identifier: "en"),
                            target: Locale.Language(identifier: "ja")
                        )
                } else {
                    translationConfig?.invalidate()
                }

            } label: {
                HStack {
                    Image(systemName: "translate")
                    Text(
                        isTranslating
                        ? "Translating..."
                        : "Translate to Japanese"
                    )
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    Color.indigo,
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
*/
            if let errorMessage = speechViewModel.errorMessage {

                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        

    .padding(.horizontal, 24)
    .padding(.bottom, 16)
    .frame(
        maxWidth: .infinity,
        maxHeight: .infinity
    )
    .toolbar(.hidden, for: .navigationBar)
    .translationTask(translationConfig) { session in

        do {
            // We only need to prepare the language pair once.
            try await session.prepareTranslation()

            while !Task.isCancelled {

                guard !translationQueue.isEmpty else {
                    try? await Task.sleep(
                        for: .milliseconds(50)
                    )
                    continue
                }

                let english = translationQueue.removeFirst()

                print("===== TRANSLATING QUEUED TEXT =====")
                print("English:", english)

                do {
                    let response =
                        try await session.translate(english)

                    japaneseText = response.targetText
                    translationError = nil

                    print("===== TRANSLATION SUCCESS =====")
                    print("English:", english)
                    print("Japanese:", response.targetText)

                    await displayViewModel.sendTranslation(
                        english: english,
                        japanese: response.targetText
                    )

                } catch is CancellationError {

                    print("Translation session cancelled")
                    return

                } catch {

                    translationError = error.localizedDescription

                    print(
                        "TRANSLATION ERROR:",
                        error.localizedDescription
                    )
                }
            }

        } catch {

            translationError = error.localizedDescription

            print(
                "TRANSLATION SESSION ERROR:",
                error.localizedDescription
            )
        }
    }
        
        Button {
            Task {
                if speechViewModel.isListening {

                    speechViewModel.onFinalizedSpeech = nil
                    speechViewModel.stopListening()

                } else {

                    japaneseText = ""
                    translationError = nil

                    speechViewModel.onVolatileSpeech = { text in
                        Task { @MainActor in
                            handleVolatileSpeech(text)
                        }
                    }

                    speechViewModel.onFinalizedSpeech = { text in
                        Task { @MainActor in
                            await translateFinalizedText(text)
                        }
                    }

                    await speechViewModel.startListening()
                }
            }

        } label: {

            HStack {
                Image(
                    systemName:
                        speechViewModel.isListening
                        ? "stop.circle.fill"
                        : "mic.fill"
                )

                Text(
                    speechViewModel.isListening
                        ? "Stop Translation"
                        : "Start Translation"
                )
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                speechViewModel.isListening
                    ? Color.red
                    : Color.blue,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }
    
    
    private func handleCompletedSpeech() async {

        let fullText = speechViewModel.transcription
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !fullText.isEmpty else {
            return
        }

        var text = fullText

        if !committedTranscript.isEmpty,
           fullText.hasPrefix(committedTranscript) {

            text = String(
                fullText.dropFirst(committedTranscript.count)
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !text.isEmpty else {
            print("No new speech to translate")
            return
        }

        guard text != lastTranslatedText else {
            print("Skipping duplicate transcription")
            return
        }

        guard !isProcessingTranslation else {
            print("Translation already processing")
            return
        }

        print("===== NEW UTTERANCE =====")
        print("Full transcript:", fullText)
        print("New text:", text)

        // Mark everything currently recognized as committed
        committedTranscript = fullText

        lastTranslatedText = text
        isProcessingTranslation = true

        if translationConfig == nil {
            if #available(iOS 26.4, *) {
                translationConfig =
                TranslationSession.Configuration(
                    source: Locale.Language(identifier: "en"),
                    target: Locale.Language(identifier: "ja"),
                    preferredStrategy: .lowLatency
                )
            } else {
                // Fallback on earlier versions
            };if #available(iOS 26.4, *) {
                translationConfig =
                TranslationSession.Configuration(
                    source: Locale.Language(identifier: "en"),
                    target: Locale.Language(identifier: "ja"),
                    preferredStrategy: .lowLatency
                )
            } else {
                // Fallback on earlier versions
            }
        } else {
            translationConfig?.invalidate()
        }
    }
    
    private func startListeningCycle() async {
        guard isContinuousMode else {
            return
        }

        guard !speechViewModel.isListening else {
            return
        }

        speechViewModel.transcription = ""

        await speechViewModel.startListening()
    }
    
    private func restartListening() async {

        guard isContinuousMode else {
            return
        }

        guard !isRestartingSpeech else {
            return
        }

        isRestartingSpeech = true

        print("===== RESTARTING LISTENING =====")

        try? await Task.sleep(
            for: .milliseconds(400)
        )

        guard isContinuousMode else {
            isRestartingSpeech = false
            return
        }

        speechViewModel.transcription = ""

        await startListeningCycle()

        isRestartingSpeech = false
    }

    private func translateFinalizedText(
        _ text: String
    ) async {

        let cleanText =
            text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !cleanText.isEmpty else {
            return
        }

        print("===== QUEUED FOR TRANSLATION =====")
        print("English:", cleanText)

        translationQueue.append(cleanText)

        // Create the translation session only once.
        if translationConfig == nil {
            translationConfig =
                TranslationSession.Configuration(
                    source: Locale.Language(
                        identifier: "en"
                    ),
                    target: Locale.Language(
                        identifier: "ja"
                    )
                )
        }
    }
    
    @MainActor
    private func queueTranslation(
        _ text: String
    ) {

        let cleanText = text
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !cleanText.isEmpty else {
            return
        }

        guard cleanText != lastQueuedSpeech else {
            print("Skipping duplicate:", cleanText)
            return
        }

        print("===== QUEUED =====")
        print(cleanText)

        lastQueuedSpeech = cleanText

        translationQueue.append(cleanText)

        if translationConfig == nil {

            if #available(iOS 26.4, *) {
                translationConfig =
                TranslationSession.Configuration(
                    source: Locale.Language(identifier: "en"),
                    target: Locale.Language(identifier: "ja"),
                    preferredStrategy: .lowLatency
                )
            } else {
                // Fallback on earlier versions
            }
        }
    }
    
    private func handleVolatileSpeech(
        _ text: String
    ) {

        volatileTranslationTask?.cancel()

        let candidate = text
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !candidate.isEmpty else {
            return
        }

        volatileTranslationTask =
            Task { @MainActor in

                do {
                    try await Task.sleep(
                        for: .milliseconds(450)
                    )
                } catch {
                    return
                }

                guard !Task.isCancelled else {
                    return
                }

                print("===== STABLE VOLATILE SPEECH =====")
                print(candidate)

                queueTranslation(candidate)
            }
    }
    
}
