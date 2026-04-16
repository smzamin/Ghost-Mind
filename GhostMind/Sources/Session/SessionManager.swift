import Foundation
import Combine
import AppKit

// MARK: - Session

struct MeetingSession: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    let startedAt: Date
    var endedAt: Date?
    var transcript: [TranscriptSegment]
    var chatMessages: [ChatMessage]
    var tags: [SessionTag]
    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    // Hashable via id only
    static func == (lhs: MeetingSession, rhs: MeetingSession) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    enum SessionTag: String, CaseIterable, Codable {
        case interview = "Interview"
        case meeting = "Meeting"
        case lecture = "Lecture"
        case salesCall = "Sales Call"
        case custom = "Custom"
    }
}

// MARK: - SessionManager

@MainActor
final class SessionManager: ObservableObject {

    @Published var currentSession: MeetingSession?
    @Published var savedSessions: [MeetingSession] = []
    @Published var isRecording = false

    private let storageURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("GhostMind/Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        loadSessions()
    }

    // MARK: - Session Lifecycle

    func startSession(title: String = "Session \(Date().formatted(date: .abbreviated, time: .shortened))") {
        currentSession = MeetingSession(
            id: UUID(),
            title: title,
            startedAt: Date(),
            endedAt: nil,
            transcript: [],
            chatMessages: [],
            tags: []
        )
        isRecording = true
    }

    func addTranscriptSegment(_ segment: TranscriptSegment) {
        currentSession?.transcript.append(segment)
    }

    func addChatMessage(_ message: ChatMessage) {
        currentSession?.chatMessages.append(message)
    }

    func endSession() {
        guard var session = currentSession else { return }
        session.endedAt = Date()
        currentSession = session
        isRecording = false
        save(session: session)
    }

    func deleteSession(_ session: MeetingSession) {
        let url = storageURL.appendingPathComponent("\(session.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        savedSessions.removeAll(where: { $0.id == session.id })
    }

    func summarizeSession(_ session: MeetingSession, aiClient: AIClient) async -> String? {
        let prompt = "Please summarize this meeting session. Focus on key takeaways and action items.\n\n" + exportMarkdown(session: session)
        return await aiClient.queryForBackground(prompt: prompt)
    }

    // MARK: - Export

    func exportMarkdown(session: MeetingSession) -> String {
        var md = "# \(session.title)\n\n"
        md += "**Date:** \(session.startedAt.formatted())\n"
        md += "**Duration:** \(Int(session.duration / 60)) min\n\n"
        md += "---\n\n## Transcript\n\n"
        for seg in session.transcript {
            let time = seg.timestamp.formatted(date: .omitted, time: .shortened)
            md += "**[\(time)] [\(seg.speaker.rawValue)]** \(seg.text)\n\n"
        }
        md += "---\n\n## AI Assistance Log\n\n"
        for msg in session.chatMessages {
            md += msg.role == .user ? "> **You:** \(msg.content)\n\n" : "\(msg.content)\n\n---\n\n"
        }
        return md
    }

    func exportToFile(session: MeetingSession, format: ExportFormat) {
        let content: String
        let ext: String
        switch format {
        case .markdown:
            content = exportMarkdown(session: session)
            ext = "md"
        case .plainText:
            content = exportMarkdown(session: session)
                .replacingOccurrences(of: "#", with: "")
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "> ", with: "")
            ext = "txt"
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            content = (try? String(data: encoder.encode(session), encoding: .utf8)) ?? ""
            ext = "json"
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.title).\(ext)"
        panel.allowedContentTypes = [.init(filenameExtension: ext)!]
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    enum ExportFormat { case markdown, plainText, json }

    // MARK: - Persistence

    private func save(session: MeetingSession) {
        let url = storageURL.appendingPathComponent("\(session.id.uuidString).json")
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(session) {
            try? data.write(to: url)
        }
        savedSessions.insert(session, at: 0)
    }

    private func loadSessions() {
        let decoder = JSONDecoder()
        let files = (try? FileManager.default.contentsOfDirectory(at: storageURL, includingPropertiesForKeys: nil)) ?? []
        savedSessions = files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(MeetingSession.self, from: data)
        }.sorted { $0.startedAt > $1.startedAt }
    }
}
