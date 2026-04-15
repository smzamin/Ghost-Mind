import Speech
import AVFoundation
import Foundation

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

    @Published var segments: [TranscriptSegment] = []
    @Published var partialText: String = ""
    @Published var isListening = false
    @Published var permissionGranted = false
    
    let sttConfig = STTConfiguration()
    private var isRestarting = false
    @Published var detectedLanguage: String = "en-US"
    @Published var providerStatusMessage: String?
    private let sttStore: KeyValueStore = UserDefaultsStore(prefix: "ghostmind.stt.")
    private let whisperEngine = WhisperEngine()
    private let googleEngine = GoogleSTTEngine()
    private var isProcessingExternal = false


    // The recognition request — accessed from any thread (SFSpeech is thread-safe for append)
    private var micRequest: SFSpeechAudioBufferRecognitionRequest?
    private var micTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    var onNewSegment: ((TranscriptSegment) -> Void)?

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
            recognizer?.defaultTaskHint = .dictation
            startMicRecognition()
        } else {
            // External providers are fed via handleAudioSegment(_:)
            micTask?.cancel()
            micTask = nil
            micRequest?.endAudio()
            micRequest = nil
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
        micRequest?.endAudio()
        micRequest = nil
        isListening = false
        providerStatusMessage = nil
    }

    // MARK: - Feed Audio (called from audio tap — any thread, no actor hop needed)
    //
    // SFSpeechAudioBufferRecognitionRequest.append() is thread-safe per Apple docs.
    // We call it directly without a Task dispatch to avoid timing gaps.

    func feedMicBuffer(_ buffer: AVAudioPCMBuffer) {
        // Only Apple on-device uses streaming audio buffers directly.
        if sttConfig.selectedProvider == .appleOnDevice {
            micRequest?.append(buffer)
        }
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
        if recognizer?.supportsOnDeviceRecognition == true {
            req.requiresOnDeviceRecognition = true
        }
        self.micRequest = req

        micTask = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.partialText = ""
                        self.finalize(text: text, speaker: .you)
                    } else {
                        self.partialText = "🎤 \(text)"
                    }
                }
                if let error {
                    let code = (error as NSError).code
                    // Auto-restart on time limit (1110), service disconnected (1101/203/301)
                    if code == 1110 || code == 203 || code == 301 || code == 1101 {
                        guard !self.isRestarting else { return }
                        self.isRestarting = true
                        
                        self.micTask?.cancel()
                        self.micTask = nil
                        self.micRequest?.endAudio()
                        self.micRequest = nil
                        
                        // Add larger delay to let audio session reset preventing 1101 infinite loops
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.isRestarting = false
                            if self.isListening { self.startMicRecognition() }
                        }
                    }
                }
            }
        }
    }

    private func finalize(text: String, speaker: TranscriptSegment.Speaker) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let segment = TranscriptSegment(id: UUID(), speaker: speaker, text: trimmed, timestamp: Date(), isFinal: true)
        segments.append(segment)
        onNewSegment?(segment)
        NotificationCenter.default.post(name: .newTranscriptSegment, object: segment)
    }
}
