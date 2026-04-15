import Foundation
import Combine
import os.log

// MARK: - Queue Item

struct QueueItem: Identifiable, Equatable {
    let id: UUID
    let prompt: String
    let action: AIAction
    var status: Status
    let createdAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var error: String?
    var retryCount: Int = 0

    enum Status: String, Equatable {
        case pending    = "Pending"
        case processing = "Processing"
        case streaming  = "Streaming"
        case completed  = "Completed"
        case failed     = "Failed"
        case deadLetter = "Dead Letter"   // exhausted all retries
    }

    var statusIcon: String {
        switch status {
        case .pending:    return "clock"
        case .processing: return "arrow.triangle.2.circlepath"
        case .streaming:  return "waveform"
        case .completed:  return "checkmark.circle.fill"
        case .failed:     return "exclamationmark.triangle.fill"
        case .deadLetter: return "xmark.octagon.fill"
        }
    }

    var statusColor: String {   // named color — Color not available in non-SwiftUI files
        switch status {
        case .pending:    return "yellow"
        case .processing: return "blue"
        case .streaming:  return "purple"
        case .completed:  return "green"
        case .failed:     return "orange"
        case .deadLetter: return "red"
        }
    }

    var age: String {
        let s = Int(Date().timeIntervalSince(createdAt))
        if s < 60 { return "\(s)s ago" }
        return "\(s / 60)m ago"
    }

    static let maxRetries = 2
}

// MARK: - Request Queue Manager

@MainActor
final class RequestQueueManager: ObservableObject {
    private static let log = Logger(subsystem: "GhostMind", category: "Queue")

    @Published var items: [QueueItem] = []
    @Published var isProcessing = false

    // Badge count = pending + processing
    var pendingCount: Int { items.filter { $0.status == .pending || $0.status == .processing }.count }
    var hasFailed: Bool   { items.contains { $0.status == .failed || $0.status == .deadLetter } }

    // Weak ref to AI client — set by AppState
    weak var aiClient: AIClient?
    var onComplete: ((QueueItem, String) -> Void)?   // called when a job succeeds
    var onDeadLetter: ((QueueItem) -> Void)?          // called when job exhausts retries

    private var currentTask: Task<Void, Never>?

    // MARK: - Enqueue

    func enqueue(prompt: String, action: AIAction, transcript: [TranscriptSegment], context: [String]) {
        let item = QueueItem(id: UUID(), prompt: prompt, action: action,
                             status: .pending, createdAt: Date())
        items.insert(item, at: 0)   // newest first
        Self.log.info("Enqueued: \(item.id) — \(action.rawValue)")

        // Start processing loop if not already running
        if !isProcessing {
            processNext(transcript: transcript, context: context)
        }
    }

    // MARK: - Retry

    func retry(item: QueueItem, transcript: [TranscriptSegment], context: [String]) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].status = .pending
        items[idx].error  = nil
        Self.log.info("Retry enqueued: \(item.id)")
        if !isProcessing { processNext(transcript: transcript, context: context) }
    }

    func retryAll(transcript: [TranscriptSegment], context: [String]) {
        for i in items.indices where items[i].status == .failed {
            items[i].status = .pending
            items[i].error  = nil
        }
        if !isProcessing { processNext(transcript: transcript, context: context) }
    }

    func clearCompleted() {
        items.removeAll { $0.status == .completed || $0.status == .deadLetter }
    }

    // MARK: - Process Loop

    private func processNext(transcript: [TranscriptSegment], context: [String]) {
        guard !isProcessing,
              let nextIdx = items.indices.reversed().first(where: { items[$0].status == .pending }),
              let client = aiClient else { return }

        isProcessing = true
        var item = items[nextIdx]
        item.status    = .processing
        item.startedAt = Date()
        items[nextIdx] = item
        Self.log.info("Processing: \(item.id)")

        currentTask = Task {
            defer { isProcessing = false }

            // 45-second hard timeout
            let result: Result<String, Error> = await withTimeout(seconds: 45) {
                // Update status to streaming once request fires
                await MainActor.run {
                    if let i = self.items.firstIndex(where: { $0.id == item.id }) {
                        self.items[i].status = .streaming
                    }
                }
                return try await client.queryForQueue(
                    prompt: item.prompt,
                    action: item.action,
                    transcript: transcript,
                    contextDocuments: context
                )
            }

            let idx = self.items.firstIndex(where: { $0.id == item.id })
            guard let idx else { return }

            switch result {
            case .success(let response):
                self.items[idx].status      = .completed
                self.items[idx].completedAt = Date()
                Self.log.info("Completed: \(item.id) in \(Int(Date().timeIntervalSince(item.startedAt ?? Date())))s")
                self.onComplete?(self.items[idx], response)

            case .failure(let err):
                let retries = self.items[idx].retryCount
                if retries < QueueItem.maxRetries {
                    self.items[idx].retryCount += 1
                    self.items[idx].status = .failed
                    self.items[idx].error  = err.localizedDescription
                    Self.log.warning("Failed (attempt \(retries + 1)): \(err.localizedDescription)")
                } else {
                    self.items[idx].status = .deadLetter
                    self.items[idx].error  = "Exhausted \(QueueItem.maxRetries + 1) attempts: \(err.localizedDescription)"
                    Self.log.error("Dead letter: \(item.id)")
                    self.onDeadLetter?(self.items[idx])
                }
            }

            // Continue processing remaining pending items
            self.processNext(transcript: transcript, context: context)
        }
    }

    // MARK: - Timeout helper

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async -> Result<T, Error> {
        await withTaskGroup(of: Result<T, Error>.self) { group in
            group.addTask {
                do {
                    let val = try await operation()
                    return .success(val)
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .failure(AIError.timeout)
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }
}
