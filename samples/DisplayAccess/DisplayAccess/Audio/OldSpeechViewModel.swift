//
//  SpeechViewModel.swift
//  DisplayAccess
//
//  Created by Hamza Ahmed on 8/12/26.
//
/*
import Foundation
import Speech
import AVFoundation
import Observation

@Observable
@MainActor
final class SpeechViewModel {

    var transcription: String = ""
    var isListening: Bool = false
    var errorMessage: String?

    private let speechRecognizer =
        SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    private let audioEngine = AVAudioEngine()

    private var recognitionRequest:
        SFSpeechAudioBufferRecognitionRequest?

    private var recognitionTask:
        SFSpeechRecognitionTask?
    
    private var silenceTask: Task<Void, Never>?
    var onSpeechEnded: (() -> Void)?

    func requestPermissions() async -> Bool {

        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(
                    returning: status == .authorized
                )
            }
        }

        guard speechAuthorized else {
            errorMessage = "Speech recognition permission was denied."
            return false
        }

        let microphoneAuthorized =
            await AVAudioApplication.requestRecordPermission()

        guard microphoneAuthorized else {
            errorMessage = "Microphone permission was denied."
            return false
        }

        return true
    }

    func startListening() async {

        guard !isListening else {
            return
        }

        errorMessage = nil

        let hasPermission = await requestPermissions()

        guard hasPermission else {
            return
        }

        do {
            try startRecognition()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    private func scheduleSilenceDetection() {

        silenceTask?.cancel()

        silenceTask = Task { @MainActor [weak self] in

            do {
                try await Task.sleep(
                    for: .milliseconds(1200)
                )
            } catch {
                return
            }

            guard let self else {
                return
            }

            let text = self.transcription
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

            guard !text.isEmpty else {
                return
            }

            print("===== SILENCE DETECTED =====")
            print("FINAL TEXT:", text)

            // Clear this first so stopListening()
            // doesn't cancel the currently executing task.
            self.silenceTask = nil

            let callback = self.onSpeechEnded

            callback?()
        }
    }

    private func startRecognition() throws {

        recognitionTask?.cancel()
        recognitionTask = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        audioEngine.inputNode.removeTap(onBus: 0)

        let audioSession = AVAudioSession.sharedInstance()

        try audioSession.setCategory(
            .record,
            mode: .measurement,
            options: .duckOthers
        )

        try audioSession.setActive(
            true,
            options: .notifyOthersOnDeactivation
        )

        let request = SFSpeechAudioBufferRecognitionRequest()

        request.shouldReportPartialResults = true

        recognitionRequest = request

        guard let speechRecognizer else {
            throw SpeechError.recognizerUnavailable
        }

        guard speechRecognizer.isAvailable else {
            throw SpeechError.recognizerUnavailable
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat =
            inputNode.outputFormat(forBus: 0)

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: recordingFormat
        ) { [weak self] buffer, _ in

            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isListening = true

        recognitionTask =
            speechRecognizer.recognitionTask(
                with: request
            ) { [weak self] result, error in

                guard let self else {
                    return
                }

                Task { @MainActor in

                    if let result {

                        self.transcription =
                            result.bestTranscription.formattedString

                        print(
                            "TRANSCRIPTION:",
                            self.transcription
                        )

                        if result.isFinal {

                            print("===== SPEECH RESULT FINAL =====")

                            self.silenceTask?.cancel()
                            self.silenceTask = nil

                            let callback = self.onSpeechEnded

                            self.stopListening()

                            callback?()

                        } else {

                            self.scheduleSilenceDetection()
                        }
                    }

                    if let error {
                        print(
                            "SPEECH ERROR:",
                            error.localizedDescription
                        )

                        self.errorMessage =
                            error.localizedDescription

                        self.stopListening()
                    }
                }
            }
    }

    func stopListening() {

        guard isListening else {
            return
        }
        
        silenceTask?.cancel()
        silenceTask = nil

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        recognitionRequest?.endAudio()

        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil

        isListening = false

        try? AVAudioSession.sharedInstance()
            .setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
    }
}

enum SpeechError: LocalizedError {
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "English speech recognition is unavailable."
        }
    }
}
*/
