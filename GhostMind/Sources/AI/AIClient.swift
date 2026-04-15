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

    @Published var isLoading    = false
    @Published var messages:    [ChatMessage] = []
    @Published var selectedProvider: AIProvider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "selectedProvider") ?? "") ?? .openAI {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: "selectedProvider") }
    }
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedModel") ?? "" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }
    @Published var activeMode: String = UserDefaults.standard.string(forKey: "interviewMode") ?? "Technical"
    @Published var errorMessage: String?
    @Published var latencyMs:    Double = 0
    @Published var rotationLog:  [String] = []            // audit trail for debugging

    var keyManager: ProviderKeyManager?               // injected by AppState
    var requestTimeout: TimeInterval = 45             // seconds

    init(store: KeyValueStore = UserDefaultsStore(prefix: "ghostmind.ai.")) {
        self.store = store
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

        messages.append(ChatMessage(id: UUID(), role: .user, content: prompt, timestamp: Date()))
        let start = Date()

        // Hard timeout via task race
        let result = await withTaskGroup(of: String?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                return await self.tryProvider(self.selectedProvider, action: action, prompt: prompt, transcript: transcript, context: contextDocuments)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(self.requestTimeout * 1_000_000_000))
                return nil
            }
            let r = await group.next()
            group.cancelAll()
            return r ?? nil
        }

        if let response = result {
            latencyMs = Date().timeIntervalSince(start) * 1000
            messages.append(ChatMessage(id: UUID(), role: .assistant, content: response, timestamp: Date()))
        } else {
            errorMessage = "Request timed out or API keys exhausted for \(selectedProvider.shortName). Check Settings → AI API Keys."
        }

        isLoading = false
    }

    // MARK: - Queue entry point (does NOT touch isLoading — managed by RequestQueueManager)

    func queryForQueue(
        prompt: String,
        action: AIAction,
        transcript: [TranscriptSegment],
        contextDocuments: [String]
    ) async throws -> String {
        if let r = await tryProvider(selectedProvider, action: action, prompt: prompt, transcript: transcript, context: contextDocuments) {
            return r
        }
        throw AIError.apiError("API keys exhausted for \(selectedProvider.shortName)")
    }

    // MARK: - Provider-level Retry Loop

    private func tryProvider(
        _ provider: AIProvider,
        action: AIAction,
        prompt: String,
        transcript: [TranscriptSegment],
        context: [String]
    ) async -> String? {

        let km = keyManager
        let model = km?.effectiveModel(for: provider, clientModel: selectedModel) ?? effectiveModel(provider)
        let baseURL = km?.effectiveBaseURL(for: provider) ?? provider.baseURL

        // Determine how many keys to try
        let keyCount = km?.availableKeys(for: provider).count ?? 0

        for attempt in 0..<max(keyCount, 1) {
            // Get the next available key from the rotation pool
            var apiKeyValue = ""
            var keyEntry: ProviderKeyManager.KeyEntry? = nil

            guard let km, let entry = km.nextAvailableKey(for: provider) else {
                log("[\(provider.shortName)] No available keys (attempt \(attempt + 1))")
                break
            }
            keyEntry = entry
            apiKeyValue = entry.key

            do {
                let result = try await sendRequest(
                    action: action,
                    userPrompt: prompt,
                    transcript: transcript,
                    contextDocuments: context,
                    provider: provider,
                    apiKey: apiKeyValue,
                    model: model,
                    baseURLOverride: baseURL
                )
                log("[\(provider.shortName)] ✓ key #\(attempt + 1)")
                return result

            } catch AIError.apiError(let msg) where isQuotaOrRateError(msg) {
                let label = keyEntry?.label.isEmpty == false ? keyEntry!.label : "key #\(attempt + 1)"
                log("[\(provider.shortName)] ⚠️ \(label) quota/rate limit — rotating")
                if let entry = keyEntry {
                    km.markKeyFailed(id: entry.id, for: provider, isQuotaExceeded: true)
                }
                // Continue loop — pick next key

            } catch {
                log("[\(provider.shortName)] ✗ non-quota error: \(error.localizedDescription)")
                errorMessage = "[\(provider.shortName)] \(error.localizedDescription)"
                return nil  // Don't retry on non-quota errors
            }
        }

        return nil  // All keys for this provider exhausted
    }

    private func effectiveModel(_ provider: AIProvider) -> String {
        selectedModel.isEmpty ? provider.defaultModel : selectedModel
    }

    private func isQuotaOrRateError(_ msg: String) -> Bool {
        let m = msg.lowercased()
        return m.contains("429")
            || m.contains("quota")
            || m.contains("rate_limit")
            || m.contains("rate limit")
            || m.contains("too many requests")
            || m.contains("insufficient_quota")
            || m.contains("resource_exhausted")
    }

    private func log(_ msg: String) {
        let line = "[\(Date().formatted(.dateTime.hour().minute().second()))] \(msg)"
        rotationLog.insert(line, at: 0)
        if rotationLog.count > 50 { rotationLog = Array(rotationLog.prefix(50)) }
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

        let contextText = contextDocuments.isEmpty ? "" :
            "\n\n## Context Documents:\n" + contextDocuments.joined(separator: "\n---\n")

        let systemContent = action.systemPrompt + contextText
        let userContent = """
        [System Configuration — Active Mode: \(activeMode)]
        Please ensure all responses, tone, and guidance adhere strictly to the rules of the \(activeMode) scenario.

        ## Live Transcript (last 40 lines):
        \(transcriptText.isEmpty ? "(No transcript yet)" : transcriptText)

        ## User Query:
        \(userPrompt)
        """

        // Build URL
        let baseURL = baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else { throw AIError.missingAPIKey }

        let endpoint: String
        switch provider {
        case .gemini:
            endpoint = "\(baseURL)/models/\(model):generateContent?key=\(apiKey)"
        case .ollama:
            endpoint = "\(baseURL)/chat"
        default:
            endpoint = "\(baseURL)/chat/completions"
        }

        guard let url = URL(string: endpoint) else { throw AIError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Auth headers
        switch provider {
        case .anthropic:
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            break // Key is in URL query param
        case .openRouter:
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("GhostMind/1.0", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("GhostMind", forHTTPHeaderField: "X-Title")
        case .ollama:
            break // No auth
        default:
            if !apiKey.isEmpty {
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }

        // Body
        req.httpBody = try JSONSerialization.data(withJSONObject: buildBody(
            provider: provider, model: model, system: systemContent, user: userContent
        ))

        let (data, response) = try await URLSession.shared.data(for: req)

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            throw AIError.apiError("[\(statusCode)] \(body)")
        }

        return try parseResponse(data: data, provider: provider)
    }

    // MARK: - Body Builder

    private func buildBody(provider: AIProvider, model: String, system: String, user: String) -> [String: Any] {
        switch provider {
        case .anthropic:
            return ["model": model, "max_tokens": 2048, "system": system,
                    "messages": [["role": "user", "content": user]]]
        case .gemini:
            return ["contents": [["role": "user", "parts": [["text": system + "\n\n" + user]]]],
                    "generationConfig": ["maxOutputTokens": 2048, "temperature": 0.7]]
        case .ollama:
            return ["model": model, "stream": false,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        default:
            return ["model": model, "max_tokens": 2048, "temperature": 0.7,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        }
    }

    // MARK: - Response Parser

    private func parseResponse(data: Data, provider: AIProvider) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch provider {
        case .gemini:
            guard let candidates = json?["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String else { throw AIError.parseError }
            return text
        case .anthropic:
            guard let content = json?["content"] as? [[String: Any]],
                  let text = content.first?["text"] as? String else { throw AIError.parseError }
            return text
        default:
            guard let choices = json?["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else { throw AIError.parseError }
            return content
        }
    }
}

// MARK: - AI Errors

enum AIError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case apiError(String)
    case parseError
    case timeout

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No API key configured. Add one in Settings → AI API Keys."
        case .invalidURL:    return "Invalid API endpoint URL."
        case .apiError(let m): return m
        case .parseError:    return "Could not parse AI response."
        case .timeout:       return "Request timed out."
        }
    }
}
