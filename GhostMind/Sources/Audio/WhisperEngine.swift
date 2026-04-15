import Foundation
import AVFoundation

// MARK: - WhisperEngine
//
// HTTP bridge to a locally-running whisper-server (whisper.cpp).
// Provides a fallback STT when SFSpeechRecognizer is unavailable or
// when the user wants multi-language support beyond English.
//
// Setup:
//   git clone https://github.com/ggerganov/whisper.cpp
//   cd whisper.cpp && make -j server
//   ./server -m models/ggml-base.en.bin -p 8178
//
// The server exposes POST /inference with multipart/form-data audio.

@MainActor
final class WhisperEngine: ObservableObject {

    @Published var isAvailable = false
    @Published var lastResult: WhisperResult?
    @Published var errorMessage: String?

    /// Base URL of the local whisper.cpp server
    var serverURL: URL = URL(string: "http://localhost:8178")!
    private var lastAvailabilityCheck: Date?

    // MARK: - Availability

    func checkAvailability(minIntervalSeconds: TimeInterval = 5) async {
        if let last = lastAvailabilityCheck, Date().timeIntervalSince(last) < minIntervalSeconds {
            return
        }
        lastAvailabilityCheck = Date()
        do {
            let url = serverURL.appendingPathComponent("health")
            let (_, response) = try await URLSession.shared.data(from: url)
            isAvailable = (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            isAvailable = false
        }
    }

    // MARK: - Transcribe Audio Buffer

    func transcribe(audioData: Data, sampleRate: UInt32, channels: UInt16, language: String = "auto") async -> WhisperResult? {
        guard isAvailable else { return nil }

        do {
            let url = serverURL.appendingPathComponent("inference")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30

            let boundary = "GhostMind-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            // Build multipart body
            var body = Data()

            // Language field
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(language)\r\n".data(using: .utf8)!)

            // Audio file field — WAV format expected by whisper.cpp server
            let wavData = pcmToWAV(pcmData: audioData, sampleRate: sampleRate, channels: channels)
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
            body.append(wavData)
            body.append("\r\n".data(using: .utf8)!)
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)

            request.httpBody = body

            let (data, _) = try await URLSession.shared.data(for: request)
            let result = try JSONDecoder().decode(WhisperServerResponse.self, from: data)

            let whisperResult = WhisperResult(
                text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                language: result.language ?? language,
                segments: result.segments ?? []
            )
            lastResult = whisperResult
            return whisperResult

        } catch {
            errorMessage = "Whisper error: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Transcribe File URL

    func transcribeFile(at url: URL, language: String = "auto") async -> WhisperResult? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Best-effort defaults for file input
        return await transcribe(audioData: data, sampleRate: 16000, channels: 1, language: language)
    }

    // MARK: - PCM → WAV conversion

    /// Wraps raw 16-bit PCM data in a minimal WAV container
    /// (whisper.cpp server requires WAV or MP3 input)
    private func pcmToWAV(pcmData: Data, sampleRate: UInt32, channels: UInt16) -> Data {
        var wav = Data()

        let byteRate = sampleRate * UInt32(channels) * 2
        let blockAlign = channels * 2
        let dataSize = UInt32(pcmData.count)
        let chunkSize = 36 + dataSize

        func write<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            wav.append(Data(bytes: &v, count: MemoryLayout<T>.size))
        }

        // RIFF header
        wav.append("RIFF".data(using: .ascii)!)
        write(chunkSize)
        wav.append("WAVE".data(using: .ascii)!)

        // fmt chunk
        wav.append("fmt ".data(using: .ascii)!)
        write(UInt32(16))        // chunk size
        write(UInt16(1))         // PCM format
        write(channels)
        write(sampleRate)
        write(byteRate)
        write(blockAlign)
        write(UInt16(16))        // bits per sample

        // data chunk
        wav.append("data".data(using: .ascii)!)
        write(dataSize)
        wav.append(pcmData)

        return wav
    }
}

// MARK: - Response Models

struct WhisperServerResponse: Codable {
    let text: String
    let language: String?
    let segments: [WhisperSegment]?
}

struct WhisperSegment: Codable {
    let id: Int
    let start: Double
    let end: Double
    let text: String
}

struct WhisperResult {
    let text: String
    let language: String
    let segments: [WhisperSegment]
}
