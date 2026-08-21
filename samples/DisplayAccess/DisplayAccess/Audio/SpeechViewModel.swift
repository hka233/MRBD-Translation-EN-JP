//
//  Untitled.swift
//  DisplayAccess
//
//  Created by Hamza Ahmed on 8/12/26.
//

import Foundation
import Speech
import AVFoundation
import Observation

@available(iOS 26.0, *)
@Observable
@MainActor
final class SpeechViewModel {

    var transcription: String = ""
    var finalizedText: String = ""

    var isListening = false
    var errorMessage: String?

    /// Called whenever SpeechAnalyzer gives us new finalized speech.
    var onFinalizedSpeech: ((String) -> Void)?
    var onVolatileSpeech: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?

    private var inputContinuation:
        AsyncStream<AnalyzerInput>.Continuation?

    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    
    private var analyzerFormat: AVAudioFormat?

    func requestPermissions() async -> Bool {

        let microphoneAuthorized =
            await AVAudioApplication.requestRecordPermission()

        guard microphoneAuthorized else {
            errorMessage = "Microphone permission was denied."
            return false
        }

        return true
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

        let analyzer = SpeechAnalyzer(
            modules: [transcriber]
        )

        self.analyzer = analyzer

        // Ask SpeechAnalyzer what audio format it actually expects.
        self.analyzerFormat =
            await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber]
            )

        guard analyzerFormat != nil else {
            throw SpeechAnalyzerError.noCompatibleAudioFormat
        }

        // Make sure the on-device English model exists.
        try await ensureModel(
            transcriber: transcriber,
            locale: locale
        )
    }
    
    func startListening() async {

        guard !isListening else {
            return
        }

        errorMessage = nil
        transcription = ""
        finalizedText = ""

        guard await requestPermissions() else {
            return
        }

        do {

            try await configureAnalyzer()

            try configureAudioSession()

            guard let analyzer,
                  let transcriber
            else {
                return
            }

            let (stream, continuation) =
                AsyncStream.makeStream(
                    of: AnalyzerInput.self
                )

            inputContinuation = continuation

            startResultProcessing(
                transcriber: transcriber
            )

            analysisTask = Task {

                do {

                    try await analyzer.start(
                        inputSequence: stream
                    )

                } catch {

                    await MainActor.run {
                        self.errorMessage =
                            error.localizedDescription
                    }

                    print(
                        "SPEECH ANALYZER ERROR:",
                        error
                    )
                }
            }

            try startAudioEngine()

            isListening = true

            print(
                "===== SPEECH ANALYZER STARTED ====="
            )

        } catch {

            errorMessage =
                error.localizedDescription

            print(
                "START SPEECH ANALYZER ERROR:",
                error
            )
        }
    }

    private func configureAudioSession() throws {

        let session =
            AVAudioSession.sharedInstance()

        try session.setCategory(
            .record,
            mode: .measurement,
            options: .duckOthers
        )

        try session.setActive(
            true,
            options: .notifyOthersOnDeactivation
        )
    }

    private func startAudioEngine() throws {

        let inputNode =
            audioEngine.inputNode

        inputNode.removeTap(
            onBus: 0
        )

        let format =
            inputNode.outputFormat(
                forBus: 0
            )

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: format
        ) { [weak self] buffer, _ in

            guard let self,
                  let analyzerFormat = self.analyzerFormat
            else {
                return
            }

            do {

                let converted =
                    try self.convertBuffer(
                        buffer,
                        to: analyzerFormat
                    )

                let input =
                    AnalyzerInput(
                        buffer: converted
                    )

                self.inputContinuation?
                    .yield(input)

            } catch {

                print(
                    "AUDIO CONVERSION ERROR:",
                    error
                )
            }
        }

        audioEngine.prepare()

        try audioEngine.start()
    }
    
    private func startResultProcessing(
        transcriber: SpeechTranscriber
    ) {

        resultTask = Task {

            do {

                for try await result in transcriber.results {

                    let text =
                        String(result.text.characters)
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )

                    guard !text.isEmpty else {
                        continue
                    }

                    await MainActor.run {

                        // Always show live transcription
                        self.transcription = text

                        print(
                            result.isFinal
                            ? "FINAL:"
                            : "VOLATILE:",
                            text
                        )

                        // Only send stable speech to translation
                        if result.isFinal {

                            self.finalizedText = text

                            print("===== FINALIZED SPEECH =====")
                            print(text)

                            self.onFinalizedSpeech?(text)

                        } else {

                            self.onVolatileSpeech?(text)
                        }
                    }
                }

            } catch {

                await MainActor.run {
                    self.errorMessage =
                        error.localizedDescription
                }

                print(
                    "TRANSCRIBER RESULT ERROR:",
                    error
                )
            }
        }
    }
    func stopListening() {

        guard isListening else {
            return
        }

        print(
            "===== STOPPING SPEECH ANALYZER ====="
        )

        audioEngine.stop()

        audioEngine.inputNode
            .removeTap(
                onBus: 0
            )

        inputContinuation?.finish()
        inputContinuation = nil

        analysisTask?.cancel()
        analysisTask = nil

        resultTask?.cancel()
        resultTask = nil

        analyzer = nil
        transcriber = nil

        isListening = false

        try? AVAudioSession
            .sharedInstance()
            .setActive(
                false,
                options:
                    .notifyOthersOnDeactivation
            )
    }
    
    private func ensureModel(
        transcriber: SpeechTranscriber,
        locale: Locale
    ) async throws {

        let supported =
            await SpeechTranscriber.supportedLocales

        let localeSupported =
            supported.contains {
                $0.identifier(.bcp47)
                    == locale.identifier(.bcp47)
            }

        guard localeSupported else {
            throw SpeechAnalyzerError.localeNotSupported
        }

        let installed =
            await SpeechTranscriber.installedLocales

        let localeInstalled =
            installed.contains {
                $0.identifier(.bcp47)
                    == locale.identifier(.bcp47)
            }

        if localeInstalled {
            print("English speech model already installed")
            return
        }

        print("Downloading English speech model...")

        if let request =
            try await AssetInventory
                .assetInstallationRequest(
                    supporting: [transcriber]
                ) {

            try await request.downloadAndInstall()

            print("English speech model installed")
        }
    }

    private func convertBuffer(
        _ buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {

        guard let converter = AVAudioConverter(
            from: buffer.format,
            to: format
        ) else {
            throw SpeechAnalyzerError.audioConversionFailed
        }

        let ratio =
            format.sampleRate
            / buffer.format.sampleRate

        let outputCapacity =
            AVAudioFrameCount(
                Double(buffer.frameLength) * ratio
            ) + 1

        guard let convertedBuffer =
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: outputCapacity
            )
        else {
            throw SpeechAnalyzerError.audioConversionFailed
        }

        var supplied = false
        var conversionError: NSError?

        let status = converter.convert(
            to: convertedBuffer,
            error: &conversionError
        ) { _, outStatus in

            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }

            supplied = true
            outStatus.pointee = .haveData

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

    enum SpeechAnalyzerError: LocalizedError {

        case localeNotSupported
        case noCompatibleAudioFormat
        case audioConversionFailed

        var errorDescription: String? {

            switch self {

            case .localeNotSupported:
                return "English is not supported by SpeechTranscriber on this device."

            case .noCompatibleAudioFormat:
                return "SpeechAnalyzer could not determine a compatible audio format."

            case .audioConversionFailed:
                return "Microphone audio could not be converted for SpeechAnalyzer."
            }
        }
    }
}
