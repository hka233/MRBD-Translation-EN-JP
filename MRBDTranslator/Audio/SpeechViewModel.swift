import AVFoundation
import Foundation
import Observation
import Speech

@Observable
@MainActor
final class SpeechViewModel {
  var transcription = ""
  var isListening = false
  var errorMessage: String?

  var onFinalizedSpeech: ((String) -> Void)?
  var onVolatileSpeech: ((String) -> Void)?

  @ObservationIgnored private let audioEngine = AVAudioEngine()
  @ObservationIgnored private var analyzer: SpeechAnalyzer?
  @ObservationIgnored private var transcriber: SpeechTranscriber?
  @ObservationIgnored private var analyzerFormat: AVAudioFormat?
  @ObservationIgnored private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
  @ObservationIgnored private var analysisTask: Task<Void, Never>?
  @ObservationIgnored private var resultTask: Task<Void, Never>?
  @ObservationIgnored private var isAudioTapInstalled = false

  func startListening() async {
    guard !isListening else { return }

    errorMessage = nil
    transcription = ""

    guard await requestMicrophonePermission() else { return }

    do {
      try await configureAnalyzer()
      try configureAudioSession()

      guard let analyzer, let transcriber else {
        throw SpeechAnalyzerError.configurationFailed
      }

      let (inputStream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
      inputContinuation = continuation
      startResultProcessing(transcriber: transcriber)

      analysisTask = Task { [weak self] in
        do {
          try await analyzer.start(inputSequence: inputStream)
        } catch is CancellationError {
          return
        } catch {
          await MainActor.run {
            self?.errorMessage = error.localizedDescription
          }
        }
      }

      try startAudioEngine()
      isListening = true
    } catch {
      errorMessage = error.localizedDescription
      stopListening()
    }
  }

  func stopListening() {
    audioEngine.stop()
    if isAudioTapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      isAudioTapInstalled = false
    }

    inputContinuation?.finish()
    inputContinuation = nil

    analysisTask?.cancel()
    analysisTask = nil
    resultTask?.cancel()
    resultTask = nil

    analyzer = nil
    transcriber = nil
    analyzerFormat = nil
    isListening = false

    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  private func requestMicrophonePermission() async -> Bool {
    let isAuthorized = await AVAudioApplication.requestRecordPermission()
    if !isAuthorized {
      errorMessage = "Microphone permission was denied."
    }
    return isAuthorized
  }

  private func configureAnalyzer() async throws {
    let locale = Locale(identifier: "en-US")
    let transcriber = SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [.volatileResults],
      attributeOptions: []
    )

    self.transcriber = transcriber
    analyzer = SpeechAnalyzer(modules: [transcriber])
    analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

    guard analyzerFormat != nil else {
      throw SpeechAnalyzerError.noCompatibleAudioFormat
    }

    try await ensureModel(transcriber: transcriber, locale: locale)
  }

  private func configureAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement, options: .duckOthers)
    try session.setActive(true, options: .notifyOthersOnDeactivation)
  }

  private func startAudioEngine() throws {
    guard let analyzerFormat else {
      throw SpeechAnalyzerError.noCompatibleAudioFormat
    }

    let inputNode = audioEngine.inputNode
    inputNode.removeTap(onBus: 0)
    let inputFormat = inputNode.outputFormat(forBus: 0)

    inputNode.installTap(
      onBus: 0,
      bufferSize: 4096,
      format: inputFormat
    ) { [weak self] buffer, _ in
      guard let self else { return }

      do {
        let convertedBuffer = try self.convertBuffer(buffer, to: analyzerFormat)
        self.inputContinuation?.yield(AnalyzerInput(buffer: convertedBuffer))
      } catch {
        #if DEBUG
        print("Audio conversion failed: \(error.localizedDescription)")
        #endif
      }
    }
    isAudioTapInstalled = true

    audioEngine.prepare()
    try audioEngine.start()
  }

  private func startResultProcessing(transcriber: SpeechTranscriber) {
    resultTask = Task { [weak self] in
      do {
        for try await result in transcriber.results {
          guard let self, !Task.isCancelled else { return }

          let text = String(result.text.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          guard !text.isEmpty else { continue }

          self.transcription = text
          if result.isFinal {
            self.onFinalizedSpeech?(text)
          } else {
            self.onVolatileSpeech?(text)
          }
        }
      } catch is CancellationError {
        return
      } catch {
        self?.errorMessage = error.localizedDescription
      }
    }
  }

  private func ensureModel(
    transcriber: SpeechTranscriber,
    locale: Locale
  ) async throws {
    let supportedLocales = await SpeechTranscriber.supportedLocales
    let isSupported = supportedLocales.contains {
      $0.identifier(.bcp47) == locale.identifier(.bcp47)
    }

    guard isSupported else {
      throw SpeechAnalyzerError.localeNotSupported
    }

    let installedLocales = await SpeechTranscriber.installedLocales
    let isInstalled = installedLocales.contains {
      $0.identifier(.bcp47) == locale.identifier(.bcp47)
    }
    guard !isInstalled else { return }

    if let request = try await AssetInventory.assetInstallationRequest(
      supporting: [transcriber]
    ) {
      try await request.downloadAndInstall()
    }
  }

  private func convertBuffer(
    _ buffer: AVAudioPCMBuffer,
    to format: AVAudioFormat
  ) throws -> AVAudioPCMBuffer {
    guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
      throw SpeechAnalyzerError.audioConversionFailed
    }

    let sampleRateRatio = format.sampleRate / buffer.format.sampleRate
    let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRateRatio) + 1

    guard let convertedBuffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: outputCapacity
    ) else {
      throw SpeechAnalyzerError.audioConversionFailed
    }

    var suppliedInput = false
    var conversionError: NSError?
    let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outputStatus in
      if suppliedInput {
        outputStatus.pointee = .noDataNow
        return nil
      }

      suppliedInput = true
      outputStatus.pointee = .haveData
      return buffer
    }

    if let conversionError {
      throw conversionError
    }

    switch status {
    case .haveData, .inputRanDry, .endOfStream:
      return convertedBuffer
    case .error:
      throw SpeechAnalyzerError.audioConversionFailed
    @unknown default:
      throw SpeechAnalyzerError.audioConversionFailed
    }
  }
}

private enum SpeechAnalyzerError: LocalizedError {
  case localeNotSupported
  case noCompatibleAudioFormat
  case audioConversionFailed
  case configurationFailed

  var errorDescription: String? {
    switch self {
    case .localeNotSupported:
      "English speech recognition is not supported on this device."
    case .noCompatibleAudioFormat:
      "SpeechAnalyzer could not determine a compatible audio format."
    case .audioConversionFailed:
      "Microphone audio could not be converted for SpeechAnalyzer."
    case .configurationFailed:
      "SpeechAnalyzer could not be configured."
    }
  }
}
