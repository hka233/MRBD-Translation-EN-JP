import SwiftUI
import Translation

struct TranslatorView: View {
  var displayViewModel: DisplayViewModel

  @State private var speechViewModel = SpeechViewModel()
  @State private var japaneseText = ""
  @State private var translationError: String?
  @State private var translationConfiguration: TranslationSession.Configuration?
  @State private var translationQueue: [TranslationRequest] = []
  @State private var volatileTranslationTask: Task<Void, Never>?
  @State private var lastQueuedSpeech = ""
  @State private var isTranslationActive = false
  @State private var isTranslating = false

  private struct TranslationRequest {
    let text: String
    let isFinal: Bool
  }

  var body: some View {
    VStack(spacing: 20) {
      header
      transcriptCard
      translationCard
      statusArea
      Spacer(minLength: 0)
      translationButton
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 20)
    .navigationTitle("Translator")
    .navigationBarTitleDisplayMode(.inline)
    .translationTask(translationConfiguration) { session in
      await processTranslationQueue(with: session)
    }
    .onDisappear {
      stopTranslation()
    }
  }

  private var header: some View {
    VStack(spacing: 10) {
      Image(systemName: "translate")
        .font(.system(size: 30, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 68, height: 68)
        .background(.blue, in: RoundedRectangle(cornerRadius: 16))

      Text("English → Japanese")
        .font(.headline)

      Label(
        displayViewModel.isConnected ? "Display connected" : "Display connects automatically",
        systemImage: displayViewModel.isConnected ? "eyeglasses" : "eyeglasses.slash"
      )
      .font(.caption)
      .foregroundStyle(displayViewModel.isConnected ? Color.green : Color.secondary)
    }
  }

  private var transcriptCard: some View {
    languageCard(
      title: "English transcription",
      text: speechViewModel.transcription,
      placeholder: "Speak English…"
    )
  }

  private var translationCard: some View {
    languageCard(
      title: "Japanese translation",
      text: japaneseText,
      placeholder: "翻訳結果がここに表示されます"
    )
  }

  @ViewBuilder
  private var statusArea: some View {
    if isTranslating || displayViewModel.isSending {
      HStack(spacing: 8) {
        ProgressView()
        Text(displayViewModel.isSending ? "Sending to display…" : "Translating…")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }

    if let error = currentError {
      Text(error)
        .font(.caption)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var translationButton: some View {
    Button {
      Task {
        if isTranslationActive {
          stopTranslation()
        } else {
          await startTranslation()
        }
      }
    } label: {
      Label(
        isTranslationActive ? "Stop Translation" : "Start Translation",
        systemImage: isTranslationActive ? "stop.circle.fill" : "mic.fill"
      )
      .font(.body.weight(.semibold))
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
      .background(isTranslationActive ? Color.red : Color.blue, in: Capsule())
    }
    .buttonStyle(.plain)
  }

  private var currentError: String? {
    speechViewModel.errorMessage ?? translationError ?? displayViewModel.errorMessage
  }

  private func languageCard(
    title: String,
    text: String,
    placeholder: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(text.isEmpty ? placeholder : text)
        .foregroundStyle(text.isEmpty ? .secondary : .primary)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .padding()
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
  }

  private func startTranslation() async {
    japaneseText = ""
    translationError = nil
    displayViewModel.clearError()
    translationQueue.removeAll()
    lastQueuedSpeech = ""
    isTranslationActive = true

    speechViewModel.onVolatileSpeech = { text in
      Task { @MainActor in
        handleVolatileSpeech(text)
      }
    }
    speechViewModel.onFinalizedSpeech = { text in
      Task { @MainActor in
        handleFinalizedSpeech(text)
      }
    }

    await displayViewModel.attachToDisplay()
    await speechViewModel.startListening()
    isTranslationActive = speechViewModel.isListening
  }

  private func stopTranslation() {
    isTranslationActive = false
    volatileTranslationTask?.cancel()
    volatileTranslationTask = nil
    translationQueue.removeAll()
    speechViewModel.onVolatileSpeech = nil
    speechViewModel.onFinalizedSpeech = nil
    speechViewModel.stopListening()
  }

  private func handleVolatileSpeech(_ text: String) {
    volatileTranslationTask?.cancel()
    let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty else { return }

    volatileTranslationTask = Task { @MainActor in
      do {
        try await Task.sleep(for: .milliseconds(450))
      } catch {
        return
      }

      guard !Task.isCancelled, isTranslationActive else { return }
      enqueueTranslation(candidate, isFinal: false)
    }
  }

  private func handleFinalizedSpeech(_ text: String) {
    volatileTranslationTask?.cancel()
    volatileTranslationTask = nil
    enqueueTranslation(text, isFinal: true)
  }

  private func enqueueTranslation(_ text: String, isFinal: Bool) {
    let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanText.isEmpty, cleanText != lastQueuedSpeech else { return }

    lastQueuedSpeech = cleanText
    let request = TranslationRequest(text: cleanText, isFinal: isFinal)

    if isFinal {
      translationQueue.removeAll { !$0.isFinal }
      translationQueue.append(request)
    } else if let index = translationQueue.lastIndex(where: { !$0.isFinal }) {
      translationQueue[index] = request
    } else {
      translationQueue.append(request)
    }

    configureTranslationIfNeeded()
  }

  private func configureTranslationIfNeeded() {
    guard translationConfiguration == nil else { return }

    if #available(iOS 26.4, *) {
      translationConfiguration = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "ja"),
        preferredStrategy: .lowLatency
      )
    } else {
      translationConfiguration = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "ja")
      )
    }
  }

  private func processTranslationQueue(with session: TranslationSession) async {
    do {
      try await session.prepareTranslation()

      while !Task.isCancelled {
        guard !translationQueue.isEmpty else {
          try await Task.sleep(for: .milliseconds(50))
          continue
        }

        let request = translationQueue.removeFirst()
        isTranslating = true

        do {
          let response = try await session.translate(request.text)
          if isTranslationActive {
            japaneseText = response.targetText
            translationError = nil
            await displayViewModel.sendTranslation(
              english: request.text,
              japanese: response.targetText
            )
          }
        } catch is CancellationError {
          return
        } catch {
          translationError = error.localizedDescription
        }

        isTranslating = false
      }
    } catch is CancellationError {
      return
    } catch {
      isTranslating = false
      translationError = error.localizedDescription
    }
  }
}
