import Foundation
import Combine

// MARK: - Chat Message

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date
    var isStreaming: Bool = false

    enum Role: String, Codable {
        case user, assistant, system
    }
}

enum AIError: Error, LocalizedError {
    case timeout
    case keysExhausted(String)
    case rateLimit(String)
    case apiError(String)
    case networkError(Error)
    case missingAPIKey
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .timeout:      return "Request timed out after \(Int(AIClient.defaultTimeout))s"
        case .keysExhausted(let provider): return "All keys for \(provider) are exhausted or cooled down."
        case .rateLimit(let provider): return "Rate limit reached for \(provider). Try again later."
        case .apiError(let msg): return msg
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .missingAPIKey: return "API Key is missing for this provider."
        case .invalidResponse: return "Received an invalid or empty response from the AI."
        }
    }
}

// MARK: - AIClient
//
// Key-rotation flow:
//   1. tryProvider(primary)  → loops through all available keys round-robin
//      - 429 / quota error   → mark key, pick next key, retry same provider
//      - Other error         → propagate immediately (auth / parse / url)
//   2. All primary keys exhausted → tryProvider(fallback)
//   3. All fallback keys exhausted → show error banner

@MainActor
final class AIClient: ObservableObject {
    private let store: KeyValueStore

    @Published var isLoading = false
    @Published var messages: [ChatMessage] = []

    @PersistRaw(key: Constants.UserDefaults.selectedProvider, defaultValue: AIProvider.openAI.rawValue)
    private var persistedProvider: String
    @Published var selectedProvider: AIProvider = .openAI {
        didSet { persistedProvider = selectedProvider.rawValue }
    }

    @PersistRaw(key: Constants.UserDefaults.selectedModel, defaultValue: "")
    private var persistedModel: String
    @Published var selectedModel: String = "" {
        didSet { persistedModel = selectedModel }
    }

    @PersistRaw(key: Constants.UserDefaults.interviewMode, defaultValue: "Technical")
    private var persistedMode: String
    @Published var activeMode: String = "Technical" {
        didSet { persistedMode = activeMode }
    }

    @Published var errorMessage: String?
    @Published var latencyMs: Double = 0
    @Published var rotationLog: [String] = []

    var keyManager: ProviderKeyManager?
    var requestTimeout: TimeInterval = 45
    var onMessageAdded: ((ChatMessage) -> Void)?

    init(store: KeyValueStore = UserDefaultsStore(prefix: "ghostmind.ai.")) {
        self.store = store
        self.selectedProvider = AIProvider(rawValue: persistedProvider) ?? .openAI
        self.selectedModel = persistedModel
        self.activeMode = persistedMode
    }

    // MARK: - Query (public entry point — updates isLoading for main chat UI)

    func query(
        prompt: String,
        action: AIAction,
        transcript: [TranscriptSegment],
        contextDocuments: [String] = []
    ) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        let userMsg = ChatMessage(id: UUID(), role: .user, content: prompt, timestamp: Date())
        messages.append(userMsg)
        onMessageAdded?(userMsg)
        let start = Date()

        do {
            let response: String? = try await withTimeout(seconds: requestTimeout) { [weak self] in
                guard let self else { return nil }
                return try await self.tryProvider(self.selectedProvider, action: action, prompt: prompt, transcript: transcript, context: contextDocuments)
            }

            if let response = response {
                latencyMs = Date().timeIntervalSince(start) * 1000
                let assistantMsg = ChatMessage(id: UUID(), role: .assistant, content: response, timestamp: Date())
                messages.append(assistantMsg)
                onMessageAdded?(assistantMsg)
            } else {
                throw AIError.invalidResponse
            }
        } catch {
            errorMessage = error.localizedDescription
            log("✘ Error: \(error.localizedDescription)")
            isLoading = false
        }
        isLoading = false
    }

    static let defaultTimeout: TimeInterval = 45

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T?) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AIError.timeout
            }
            let result = try await group.next()
            group.cancelAll()
            return result ?? nil
        }
    }

    // MARK: - Queue entry point (does NOT touch isLoading — managed by RequestQueueManager)

    func queryForQueue(
        prompt: String,
        action: AIAction,
        transcript: [TranscriptSegment],
        contextDocuments: [String]
    ) async throws -> String {
        if let r = try await tryProvider(selectedProvider, action: action, prompt: prompt, transcript: transcript, context: contextDocuments) {
            return r
        }
        throw AIError.keysExhausted(selectedProvider.rawValue)
    }

    // MARK: - Background entry point (Silent, no UI updates)

    func queryForBackground(prompt: String) async -> String? {
        return try? await tryProvider(selectedProvider, action: .translate, prompt: prompt, transcript: [], context: [])
    }

    // MARK: - Provider-level Retry Loop

    private func tryProvider(
        _ provider: AIProvider,
        action: AIAction,
        prompt: String,
        transcript: [TranscriptSegment],
        context: [String]
    ) async throws -> String? {

        let km = keyManager
        let model = km?.effectiveModel(for: provider, clientModel: selectedModel) ?? effectiveModel(provider)
        let baseURL = km?.effectiveBaseURL(for: provider) ?? provider.baseURL

        for _ in 0..<3 { // Max 3 keys per provider attempt
            guard let keyEntry = km?.nextAvailableKey(for: provider) else {
                log("[\(provider.shortName)] ✘ No active keys found.")
                throw AIError.keysExhausted(provider.rawValue)
            }

            log("[\(provider.shortName)] ➜ Trying Key: \(keyEntry.label.isEmpty ? "Key" : keyEntry.label) (\(model))")
            
            do {
                let r = try await sendRequest(
                    action: action,
                    userPrompt: prompt,
                    transcript: transcript,
                    contextDocuments: context,
                    provider: provider,
                    apiKey: keyEntry.key,
                    model: model,
                    baseURLOverride: baseURL
                )
                if !r.isEmpty { return r }
            } catch {
                let errorMsg = error.localizedDescription
                if isQuotaOrRateError(errorMsg) {
                    log("[\(provider.shortName)] ⚠ Quota/Rate limit with key '\(keyEntry.label)'. Retrying with next key...")
                    // Optionally mark the key as cooled down if keyManager supported it
                    continue 
                } else {
                    log("[\(provider.shortName)] ✘ Terminal Error: \(errorMsg)")
                    throw error // Propagate auth/context-length/etc. errors immediately
                }
            }
        }

        throw AIError.keysExhausted(provider.rawValue)
    }

    private func effectiveModel(_ provider: AIProvider) -> String {
        selectedModel.isEmpty ? provider.defaultModel : selectedModel
    }

    private func isQuotaOrRateError(_ msg: String) -> Bool {
        let m = msg.lowercased()
        let keywords = ["429", "quota", "rate_limit", "rate limit", "too many requests", "insufficient_quota", "resource_exhausted"]
        return keywords.contains(where: { m.contains($0) })
    }

    private func log(_ msg: String) {
        let line = "[\(Date().formatted(.dateTime.hour().minute().second()))] \(msg)"
        rotationLog.append(line)
        if rotationLog.count > 50 { rotationLog.removeFirst(rotationLog.count - 50) }
    }

    // MARK: - HTTP Request

    private func sendRequest(
        action: AIAction,
        userPrompt: String,
        transcript: [TranscriptSegment],
        contextDocuments: [String],
        provider: AIProvider,
        apiKey: String,
        model: String,
        baseURLOverride: String
    ) async throws -> String {
        let transcriptText = transcript.suffix(40)
            .map { "[\($0.speaker.rawValue)]: \($0.text)" }
            .joined(separator: "\n")

        let compressedTranscript = ContextCompressor.compress(transcriptText)

        let contextText = contextDocuments.isEmpty ? "" :
            "\n\n## Context Documents:\n" + contextDocuments.joined(separator: "\n---\n")

        let compressedContext = ContextCompressor.compress(contextText)

        let systemContent = action.systemPrompt + compressedContext
        let userContent = """
        [System Configuration — Active Mode: \(activeMode)]
        Please ensure all responses, tone, and guidance adhere strictly to the rules of the \(activeMode) scenario.

        ## Live Transcript (last 40 lines):
        \(compressedTranscript.isEmpty ? "(No transcript yet)" : compressedTranscript)

        ## User Query:
        \(userPrompt)
        """

        let baseURL = baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else { throw AIError.missingAPIKey }

        let url: URL
        switch provider {
        case .gemini:
            url = URL(string: "\(baseURL)/models/\(model):generateContent?key=\(apiKey)")!
        case .ollama:
            url = URL(string: "\(baseURL)/chat")!
        default:
            url = URL(string: "\(baseURL)/chat/completions")!
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        switch provider {
        case .anthropic:
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openRouter:
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("GhostMind/1.0", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("GhostMind", forHTTPHeaderField: "X-Title")
        case .gemini, .ollama: break
        default:
            if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        }

        let startOfMessages = messages.dropLast().suffix(100)

        let encoder = JSONEncoder()
        switch provider {
        case .anthropic:
            var apiMessages: [AnthropicRequest.Message] = startOfMessages.map {
                .init(role: $0.role == .user ? "user" : "assistant", content: ContextCompressor.compress($0.content))
            }
            apiMessages.append(.init(role: "user", content: userContent))
            let body = AnthropicRequest(model: model, system: systemContent, messages: apiMessages)
            req.httpBody = try encoder.encode(body)

        case .gemini:
            // Gemini version — join history into contents
            var contents: [GeminiRequest.Content] = startOfMessages.map {
                .init(role: $0.role == .user ? "user" : "model", parts: [.init(text: ContextCompressor.compress($0.content))])
            }
            contents.append(.init(role: "user", parts: [.init(text: systemContent + "\n\n" + userContent)]))
            let body = GeminiRequest(contents: contents)
            req.httpBody = try encoder.encode(body)

        default:
            var apiMessages: [OpenAIRequest.Message] = [
                .init(role: "system", content: systemContent)
            ]
            for msg in startOfMessages {
                let compressed = ContextCompressor.compress(msg.content)
                apiMessages.append(.init(role: msg.role == .user ? "user" : "assistant", content: compressed))
            }
            apiMessages.append(.init(role: "user", content: userContent))

            let body = OpenAIRequest(model: model, messages: apiMessages)
            req.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard (200...299).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            throw AIError.apiError("[\(statusCode)] \(body)")
        }

        let decoder = JSONDecoder()
        switch provider {
        case .anthropic:
            return try decoder.decode(AnthropicResponse.self, from: data).content.first?.text ?? ""
        case .gemini:
            return try decoder.decode(GeminiResponse.self, from: data).candidates.first?.content.parts.first?.text ?? ""
        default:
            return try decoder.decode(OpenAIResponse.self, from: data).choices.first?.message.content ?? ""
        }
    }

    struct OpenAIRequest: Encodable {
        let model: String
        let messages: [Message]
        let max_tokens: Int = 2048
        let temperature: Double = 0.7
        struct Message: Encodable { let role: String; let content: String }
    }
    struct OpenAIResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }
    struct AnthropicRequest: Encodable {
        let model: String
        let max_tokens: Int = 2048
        let system: String
        let messages: [Message]
        struct Message: Encodable { let role: String; let content: String }
    }
    struct AnthropicResponse: Decodable {
        struct Content: Decodable { let text: String }
        let content: [Content]
    }
    struct GeminiRequest: Encodable {
        struct Content: Encodable {
            let role: String
            struct Part: Encodable { let text: String }
            let parts: [Part]
        }
        let contents: [Content]
    }
    struct GeminiResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String }
                let parts: [Part]
            }
            let content: Content
        }
        let candidates: [Candidate]
    }
}

// MARK: - Context Compressor

struct ContextCompressor {

    static func compress(_ text: String) -> String {
        // 1. Separate code blocks (they must be preserved exactly)
        let blocks = separateCodeBlocks(text)

        var compressedBlocks: [String] = []
        for block in blocks {
            if block.hasPrefix("```") || block.hasPrefix("`") {
                // Preserve code
                compressedBlocks.append(block)
            } else {
                // Compress prose
                compressedBlocks.append(compressProse(block))
            }
        }

        return compressedBlocks.joined()
    }

    // MARK: - Private

    private static func separateCodeBlocks(_ text: String) -> [String] {
        var results: [String] = []
        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = nil

        var lastPos = text.startIndex

        while !scanner.isAtEnd {
            let start = scanner.currentIndex

            // Look for ``` or `
            if scanCodeBlock(scanner, delimiter: "```") || scanCodeBlock(scanner, delimiter: "`") {
                let prose = String(text[lastPos..<start])
                if !prose.isEmpty { results.append(prose) }

                let code = String(text[start..<scanner.currentIndex])
                results.append(code)
                lastPos = scanner.currentIndex
            } else {
                _ = scanner.scanCharacter()
            }
        }

        let finalProse = String(text[lastPos...])
        if !finalProse.isEmpty { results.append(finalProse) }

        return results
    }

    private static func scanCodeBlock(_ scanner: Scanner, delimiter: String) -> Bool {
        guard scanner.string[scanner.currentIndex...].hasPrefix(delimiter) else { return false }

        let start = scanner.currentIndex
        // Skip opening delimiter
        for _ in 0..<delimiter.count { _ = scanner.scanCharacter() }

        // Find closing delimiter
        while !scanner.isAtEnd {
            if scanner.string[scanner.currentIndex...].hasPrefix(delimiter) {
                for _ in 0..<delimiter.count { _ = scanner.scanCharacter() }
                return true
            }
            _ = scanner.scanCharacter()
        }

        // If no closing delimiter, treat as prose from start
        scanner.currentIndex = start
        return false
    }

    private static func compressProse(_ text: String) -> String {
        var result = text

        // --- REMOVE ARTICLES ---
        let articles = [" a ", " an ", " the ", " A ", " An ", " The "]
        for art in articles {
            result = result.replacingOccurrences(of: art, with: " ")
        }
        // Handle start of string articles
        if result.hasPrefix("A ") || result.hasPrefix("An ") || result.hasPrefix("The ") {
             result = result.components(separatedBy: " ").dropFirst().joined(separator: " ")
        }

        // --- REMOVE FILLERS & PLEASANTRIES ---
        let fillers = [
            "just", "really", "basically", "actually", "simply", "essentially", "generally",
            "sure", "certainly", "of course", "happy to", "I'd recommend",
            "it might be worth", "you could consider", "it would be good to",
            "however", "furthermore", "additionally", "in addition"
        ]

        for filler in fillers {
            let pattern = "\\b\(filler)\\b[,\\.]?"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "")
            }
        }

        // --- REDUNDANT PHRASING ---
        let replacements = [
            "in order to": "to",
            "make sure to": "ensure",
            "the reason is because": "because",
            "utilize": "use",
            "extensive": "big",
            "implement a solution for": "fix",
            "You should": "",
            "you should": "",
            "remember to": "",
            "Make sure to": "Ensure"
        ]

        for (pattern, sub) in replacements {
            result = result.replacingOccurrences(of: pattern, with: sub, options: .caseInsensitive)
        }

        // --- CLEANUP ---
        // Remove double spaces
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
