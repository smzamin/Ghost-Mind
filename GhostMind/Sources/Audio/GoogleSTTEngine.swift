import Foundation

// MARK: - GoogleSTTEngine
//
// Minimal REST client for Google Speech-to-Text v1.
// Uses API key auth (key=...) and synchronous recognize (not streaming).

struct GoogleSTTEngine {
    struct RequestBody: Encodable {
        struct Config: Encodable {
            let encoding: String
            let sampleRateHertz: Int
            let languageCode: String
        }
        struct Audio: Encodable {
            let content: String
        }
        let config: Config
        let audio: Audio
    }

    struct ResponseBody: Decodable {
        struct Result: Decodable {
            struct Alternative: Decodable { let transcript: String? }
            let alternatives: [Alternative]?
        }
        let results: [Result]?
    }

    func transcribeLinear16(
        pcmData: Data,
        sampleRateHertz: Int,
        languageCode: String,
        apiKey: String
    ) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GoogleSTTError.missingAPIKey }

        guard let url = URL(string: "https://speech.googleapis.com/v1/speech:recognize?key=\(key)") else {
            throw GoogleSTTError.invalidURL
        }

        let body = RequestBody(
            config: .init(encoding: "LINEAR16", sampleRateHertz: sampleRateHertz, languageCode: languageCode),
            audio: .init(content: pcmData.base64EncodedString())
        )

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            throw GoogleSTTError.apiError("[\(status)] \(body)")
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        let transcript = decoded.results?
            .compactMap { $0.alternatives?.first?.transcript }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return transcript
    }
}

enum GoogleSTTError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Missing Google STT API key."
        case .invalidURL: return "Invalid Google STT URL."
        case .apiError(let m): return m
        }
    }
}

