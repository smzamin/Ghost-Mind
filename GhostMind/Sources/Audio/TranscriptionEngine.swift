import Speech
import AVFoundation
import Foundation
import Combine
import os.log

// MARK: - TranscriptSegment

struct TranscriptSegment: Identifiable, Codable {
    let id: UUID
    let speaker: Speaker
    let text: String
    let timestamp: Date
    var isFinal: Bool

    enum Speaker: String, Codable, CaseIterable {
        case you = "You"
        case interviewer = "Interviewer"
        case participant = "Participant"
        case unknown = "Unknown"
    }
}

// MARK: - STT Provider (separate from AI providers)

enum STTProvider: String, CaseIterable, Identifiable, Codable {
    case appleOnDevice = "Apple (On-Device)"
    case openAIWhisper = "OpenAI Whisper"
    case groqWhisper   = "Groq Whisper"
    case deepgram      = "Deepgram"
    case assemblyAI    = "AssemblyAI"
    case googleSTT     = "Google Speech-to-Text"
    case localWhisper  = "Local Whisper (whisper.cpp)"

    var id: String { rawValue }

    var icon: String {
        Self.specs[self]?.icon ?? "waveform"
    }

    var availableModels: [String] {
        Self.specs[self]?.suggestedModels ?? []
    }

    var apiKeyRequired: Bool { Self.specs[self]?.apiKeyRequired ?? false }
    var endpointRequired: Bool { Self.specs[self]?.endpointRequired ?? false }

    struct Spec {
        let icon: String
        let suggestedModels: [String]
        let apiKeyRequired: Bool
        let endpointRequired: Bool
        let helpText: String
    }

    static let specs: [STTProvider: Spec] = [
        .appleOnDevice: .init(
            icon: "apple.logo",
            suggestedModels: ["on-device (neural engine)"],
            apiKeyRequired: false,
            endpointRequired: false,
            helpText: "On-device · No internet needed"
        ),
        .openAIWhisper: .init(
            icon: "waveform",
            suggestedModels: ["whisper-1"],
            apiKeyRequired: true,
            endpointRequired: false,
            helpText: "Requires API key"
        ),
        .groqWhisper: .init(
            icon: "bolt.fill",
            suggestedModels: ["whisper-large-v3", "whisper-large-v3-turbo", "distil-whisper-large-v3-en"],
            apiKeyRequired: true,
            endpointRequired: false,
            helpText: "Requires API key"
        ),
        .deepgram: .init(
            icon: "waveform.circle.fill",
            suggestedModels: ["nova-2", "nova-2-meeting", "nova-2-phonecall", "enhanced", "base"],
            apiKeyRequired: true,
            endpointRequired: false,
            helpText: "Requires API key"
        ),
        .assemblyAI: .init(
            icon: "mic.circle.fill",
            suggestedModels: ["best", "nano"],
            apiKeyRequired: true,
            endpointRequired: false,
            helpText: "Requires API key"
        ),
        .googleSTT: .init(
            icon: "g.circle",
            suggestedModels: ["chirp_3", "latest_long", "latest_short"],
            apiKeyRequired: true,
            endpointRequired: false,
            helpText: "Requires API key"
        ),
        .localWhisper: .init(
            icon: "server.rack",
            suggestedModels: ["tiny.en", "base.en", "small.en", "medium.en", "large-v3"],
            apiKeyRequired: false,
            endpointRequired: true,
            helpText: "Requires local server"
        )
    ]
}

// MARK: - STT Configuration

final class STTConfiguration: ObservableObject, Codable {
    @Published var selectedProvider: STTProvider = STTProvider(rawValue: UserDefaults.standard.string(forKey: "stt_selected_provider") ?? "") ?? .appleOnDevice {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: "stt_selected_provider") }
    }
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "stt_selected_model") ?? "" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "stt_selected_model") }
    }
    @Published var localEndpoint: String = UserDefaults.standard.string(forKey: "stt_local_endpoint") ?? "http://localhost:8178" {
        didSet { UserDefaults.standard.set(localEndpoint, forKey: "stt_local_endpoint") }
    }

    enum CodingKeys: String, CodingKey { case selectedProvider, selectedModel, localEndpoint }

    init() {}

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedProvider = try c.decodeIfPresent(STTProvider.self, forKey: .selectedProvider) ?? .appleOnDevice
        selectedModel    = try c.decodeIfPresent(String.self, forKey: .selectedModel) ?? ""
        localEndpoint    = try c.decodeIfPresent(String.self, forKey: .localEndpoint) ?? "http://localhost:8178"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(selectedProvider, forKey: .selectedProvider)
        try c.encode(selectedModel,    forKey: .selectedModel)
        try c.encode(localEndpoint,    forKey: .localEndpoint)
    }

    var effectiveModel: String {
        selectedModel.isEmpty ? (selectedProvider.availableModels.first ?? "") : selectedModel
    }
}

// MARK: - TranscriptionEngine

/// On-device speech recognition using SFSpeechRecognizer.
/// The mic buffer is fed directly from the AVAudioEngine tap without Main Actor hops
/// to ensure continuous, gapless audio delivery to the recognizer.
@MainActor
final class TranscriptionEngine: ObservableObject {
    private static let log = Logger(subsystem: "GhostMind", category: "Transcription")

    @Published var segments: [TranscriptSegment] = []
    @Published var partialText: String = ""
    @Published var isListening = false
    @Published var permissionGranted = false

    let sttConfig = STTConfiguration()
    private var isRestarting = false
    @Published var detectedLanguage: String = "en-US"
    @Published var autoTranslateToEnglish: Bool = false
    @Published var isTranslating: Bool = false
    @Published var providerStatusMessage: String?
    private let sttStore: KeyValueStore = UserDefaultsStore(prefix: "ghostmind.stt.")
    private let whisperEngine = WhisperEngine()

    private let maxLiveSegments = 500 // Keep UI snappy
    private let googleEngine = GoogleSTTEngine()
    private var isProcessingExternal = false

    // Silence-based auto-chunking
    private var silenceTimer: Timer?
    private let silenceThreshold: TimeInterval = 1.6

    // Thread-safe container for real-time recognition
    private final class RecognitionContainer: @unchecked Sendable {
        private let lock = NSLock()
        private var _request: SFSpeechAudioBufferRecognitionRequest?
        var request: SFSpeechAudioBufferRecognitionRequest? {
            get { lock.lock(); defer { lock.unlock() }; return _request }
            set { lock.lock(); defer { lock.unlock() }; _request = newValue }
        }
    }
    private let recognitionContainer = RecognitionContainer()
    private var micTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    // Combine Publishers
    private let segmentPublisher = PassthroughSubject<TranscriptSegment, Never>()
    var segmentsStream: AnyPublisher<TranscriptSegment, Never> { segmentPublisher.eraseToAnyPublisher() }

    private let translationPublisher = PassthroughSubject<TranscriptSegment, Never>()
    var translationStream: AnyPublisher<TranscriptSegment, Never> { translationPublisher.eraseToAnyPublisher() }

    // MARK: - Permissions

    @MainActor
    func requestPermissions() async {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        permissionGranted = (status == .authorized)
    }

    // MARK: - Start / Stop

    @MainActor
    func start(locale: Locale = .init(identifier: "en-US")) {
        guard permissionGranted else {
            // Request permission now if not done yet
            Task { await requestPermissions(); start(locale: locale) }
            return
        }
        providerStatusMessage = nil
        if sttConfig.selectedProvider == .appleOnDevice {
            recognizer = SFSpeechRecognizer(locale: locale)

            if let recognizer, !recognizer.isAvailable {
                Self.log.error("Recognizer for \(locale.identifier) is currently unavailable (e.g. model needs download).")
            }

            recognizer?.defaultTaskHint = .dictation
            Self.log.info("Starting Apple On-Device STT (locale: \(locale.identifier))")
            startMicRecognition()
        } else {
            Self.log.info("Starting external STT provider: \(self.sttConfig.selectedProvider.rawValue)")
            // External providers are fed via handleAudioSegment(_:)
            micTask?.cancel()
            micTask = nil
            recognitionContainer.request?.endAudio()
            recognitionContainer.request = nil
            recognizer = nil
            if sttConfig.selectedProvider == .localWhisper {
                Task { @MainActor in await whisperEngine.checkAvailability(minIntervalSeconds: 0) }
            }
        }
        isListening = true
    }

    @MainActor
    func stop() {
        micTask?.finish()
        recognitionContainer.request?.endAudio()
        recognitionContainer.request = nil
        isListening = false
        providerStatusMessage = nil
    }

    nonisolated func feedMicBuffer(_ buffer: AVAudioPCMBuffer) {
        // We only append if using Apple on-device. This is safe to call from any thread.
        recognitionContainer.request?.append(buffer)
    }

    // MARK: - External provider path (segment-based)

    @MainActor
    func handleAudioSegment(_ segment: AudioSegment) async {
        guard isListening else { return }
        guard segment.source == .microphone else { return }
        guard sttConfig.selectedProvider != .appleOnDevice else { return }
        guard !isProcessingExternal else { return }

        let provider = sttConfig.selectedProvider
        let model = sttConfig.effectiveModel
        let lang = detectedLanguage.isEmpty ? "en-US" : detectedLanguage

        isProcessingExternal = true
        defer { isProcessingExternal = false }

        Self.log.debug("Processing segment for \(provider.rawValue) (data: \(segment.data.count) bytes)")

        do {
            let text: String
            switch provider {
            case .localWhisper:
                whisperEngine.serverURL = URL(string: sttConfig.localEndpoint) ?? whisperEngine.serverURL
                if !whisperEngine.isAvailable {
                    await whisperEngine.checkAvailability(minIntervalSeconds: 5)
                }
                guard whisperEngine.isAvailable else {
                    providerStatusMessage = "Local Whisper not reachable at \(sttConfig.localEndpoint)"
                    return
                }
                let r = await whisperEngine.transcribe(
                    audioData: segment.data,
                    sampleRate: UInt32(segment.sampleRate),
                    channels: UInt16(segment.channelCount),
                    language: "auto"
                )
                text = r?.text ?? ""
            case .googleSTT:
                let apiKey = sttStore.string(forKey: "api_key.\(provider.id)") ?? ""
                text = try await googleEngine.transcribeLinear16(
                    pcmData: segment.data,
                    sampleRateHertz: Int(segment.sampleRate),
                    languageCode: lang,
                    apiKey: apiKey
                )
            default:
                // For now, other cloud providers are configurable in UI but not yet implemented.
                providerStatusMessage = "\(provider.rawValue) STT is not implemented yet."
                return
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.log.info("\(provider.rawValue) text: \(trimmed)")
            guard !trimmed.isEmpty else { return }
            finalize(text: trimmed, speaker: .you)
            providerStatusMessage = "Transcribed via \(provider.rawValue)\(model.isEmpty ? "" : " · \(model)")"

        } catch {
            providerStatusMessage = "STT error: \(error.localizedDescription)"
        }
    }

    // MARK: - Private

    @MainActor
    private func startMicRecognition() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        self.recognitionContainer.request = req
        micTask = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }

            // Handle results inside a Task to get back to MainActor properly
            Task { @MainActor in
                if let result = result {
                    let text = result.bestTranscription.formattedString
                    self.resetSilenceTimer(for: text)

                    if result.isFinal {
                        Self.log.info("Apple STT Final Result: \(text)")
                        self.partialText = ""
                        self.finalize(text: text, speaker: .you)
                    } else {
                        self.partialText = "🎤 \(text)"
                    }
                }

                if let error = error {
                    Self.log.error("Apple STT Task error: \(error.localizedDescription)")
                    let code = (error as NSError).code
                    if [1110, 203, 301, 1101].contains(code) {
                        guard !self.isRestarting else { return }
                        self.isRestarting = true

                        self.micTask?.cancel()
                        self.micTask = nil
                        self.recognitionContainer.request?.endAudio()
                        self.recognitionContainer.request = nil

                        try? await Task.sleep(nanoseconds: 500_000_000)
                        self.isRestarting = false
                        if self.isListening { self.startMicRecognition() }
                    }
                }
            }
        }
    }

    private func finalize(text: String, speaker: TranscriptSegment.Speaker) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if autoTranslateToEnglish {
            // translation is async but finalize is sync; use a Task to handle it
            Task {
                await translateAndAppend(text: trimmed, speaker: speaker)
            }
        } else {
            appendSegment(text: trimmed, speaker: speaker)
        }
    }

    private func translateAndAppend(text: String, speaker: TranscriptSegment.Speaker) async {
        let segment = TranscriptSegment(id: UUID(), speaker: speaker, text: text, timestamp: Date(), isFinal: true)
        translationPublisher.send(segment)
    }

    func appendSegment(text: String, speaker: TranscriptSegment.Speaker) {
        let segment = TranscriptSegment(id: UUID(), speaker: speaker, text: text, timestamp: Date(), isFinal: true)

        // Prune live display if too many segments
        if segments.count >= maxLiveSegments {
            segments.removeFirst()
        }

        segments.append(segment)
        segmentPublisher.send(segment)
    }

    private func resetSilenceTimer(for text: String) {
        silenceTimer?.invalidate()
        guard !text.isEmpty else { return }

        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // If we have silence for X seconds, finalize the current partial text manually
                if !self.partialText.isEmpty {
                    let clean = self.partialText.replacingOccurrences(of: "🎤 ", with: "")
                    if !clean.isEmpty {
                        Self.log.info("Silence detected. Auto-finalizing segment.")
                        self.finalize(text: clean, speaker: .you)
                        self.partialText = ""

                        // Restart the STT task to ensure we start fresh on the next word
                        // (Prevents Apple from repeating the old text in the next partial result)
                        self.micTask?.cancel()
                        self.micTask = nil
                        self.recognitionContainer.request?.endAudio()
                        self.recognitionContainer.request = nil
                        if self.isListening { self.startMicRecognition() }
                    }
                }
            }
        }
    }
}

extension NSNotification.Name {
    static let audioTranslationNeeded = NSNotification.Name("audioTranslationNeeded")
}
