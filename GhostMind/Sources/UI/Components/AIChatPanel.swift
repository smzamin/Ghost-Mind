import SwiftUI
import AppKit

// MARK: - AI Chat Panel

struct AIChatPanel: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var aiClient: AIClient
    @ObservedObject var queueManager: RequestQueueManager

    init(aiClient: AIClient, queueManager: RequestQueueManager) {
        self.aiClient = aiClient
        self.queueManager = queueManager
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Response status banner ──────────────────────────────────────────
            ResponseStatusBar(aiClient: aiClient, queueManager: queueManager)

            // ── Messages ────────────────────────────────────────────────────────
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if aiClient.messages.isEmpty && !aiClient.isLoading {
                            EmptyStateView()
                        } else {
                            ForEach(aiClient.messages) { msg in
                                ChatBubble(message: msg).id(msg.id)
                            }
                        }

                        // Typing indicator only while loading
                        if aiClient.isLoading {
                            ThinkingBubble().id("thinking")
                        }
                    }
                    .padding(16)
                }
                .textSelection(.enabled)
                .onChange(of: aiClient.messages.count) { _ in
                    withAnimation { proxy.scrollTo(aiClient.messages.last?.id, anchor: .bottom) }
                }
                .onChange(of: aiClient.isLoading) { loading in
                    if loading { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
                }
            }

            // ── Queue panel (shown when there are items) ─────────────────────
            if !queueManager.items.isEmpty {
                Divider().opacity(0.15)
                QueuePanel(queueManager: queueManager)
                    .environmentObject(state)
                    .frame(maxHeight: 160)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // ── Stats bar ───────────────────────────────────────────────────
            if !state.aiClient.messages.isEmpty {
                StatsBar().environmentObject(state)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: state.queueManager.items.isEmpty)
    }
}

// MARK: - Response Status Bar

struct ResponseStatusBar: View {
    @ObservedObject var aiClient: AIClient
    @ObservedObject var queueManager: RequestQueueManager

    var statusText: String {
        if aiClient.isLoading               { return "Thinking..." }
        if queueManager.pendingCount > 0    { return "\(queueManager.pendingCount) queued" }
        if queueManager.hasFailed           { return "Some requests failed" }
        return ""
    }

    var statusIcon: String {
        if aiClient.isLoading            { return "arrow.triangle.2.circlepath" }
        if queueManager.pendingCount > 0 { return "clock.fill" }
        if queueManager.hasFailed        { return "exclamationmark.triangle.fill" }
        return ""
    }

    var statusColor: Color {
        if aiClient.isLoading            { return .purple }
        if queueManager.pendingCount > 0 { return .yellow }
        if queueManager.hasFailed        { return .orange }
        return .clear
    }

    var body: some View {
        if !statusText.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)
                Spacer()

                if queueManager.hasFailed {
                    Button("Retry Failed") {
                        // Retry handled in QueuePanel
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(statusColor.opacity(0.08))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Queue Panel

struct QueuePanel: View {
    @ObservedObject var queueManager: RequestQueueManager
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Label("Request Queue", systemImage: "list.bullet.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                if queueManager.hasFailed {
                    Button("Retry All") {
                        queueManager.retryAll(
                            transcript: state.transcriptionEngine.segments,
                            context: [state.activeContext].filter { !$0.isEmpty }
                        )
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                }
                Button("Clear Done") { queueManager.clearCompleted() }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(queueManager.items) { item in
                        QueueItemRow(item: item, queueManager: queueManager)
                            .environmentObject(state)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
        .background(Color.white.opacity(0.03))
    }
}

// MARK: - Queue Item Row

struct QueueItemRow: View {
    let item: QueueItem
    @ObservedObject var queueManager: RequestQueueManager
    @EnvironmentObject var state: AppState

    var statusColor: Color {
        switch item.status {
        case .pending:    return .yellow
        case .processing: return .blue
        case .streaming:  return .purple
        case .completed:  return .green
        case .failed:     return .orange
        case .deadLetter: return .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.statusIcon)
                .font(.system(size: 11))
                .foregroundStyle(statusColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.prompt)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    Text(item.status.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(statusColor)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(item.age)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let err = item.error {
                        Text("· \(err)")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            Spacer()

            if item.status == .failed {
                Button {
                    queueManager.retry(
                        item: item,
                        transcript: state.transcriptionEngine.segments,
                        context: [state.activeContext].filter { !$0.isEmpty }
                    )
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    @EnvironmentObject var state: AppState
    let message: ChatMessage
    @State private var copied  = false
    @State private var hovered = false

    var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Group {
                    if isUser {
                        Text(message.content)
                            .font(.system(size: 13.5, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                LinearGradient(colors: [.purple, .indigo],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                    } else {
                        MarkdownText(text: message.content)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.1), lineWidth: 1))
                    }
                }

                HStack(spacing: 8) {
                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.25))
                    if !isUser {
                        Button {
                            state.selectedText = "Regarding this response: \"\(message.content)\"\n\n"
                        } label: {
                            Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 4)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        } label: {
                            Label(copied ? "Copied!" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundStyle(copied ? .green : .white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !isUser { Spacer(minLength: 60) }
        }
        .opacity(hovered ? 1 : 0.95)
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovered)
    }
}

// MARK: - Thinking Bubble

struct ThinkingBubble: View {
    @State private var animating = false

    var body: some View {
        HStack(alignment: .top) {
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(.purple.opacity(0.8))
                        .frame(width: 6, height: 6)
                        .offset(y: animating ? -4 : 0)
                        .animation(
                            .easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15),
                            value: animating
                        )
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .onAppear { animating = true }
            Spacer()
        }
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 40)).foregroundStyle(.purple.opacity(0.5))
            Text("GhostMind is ready")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            Text("Start a session for live transcription, or type a question.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.35)).multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

// MARK: - Stats Bar

struct StatsBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 16) {
            if state.aiClient.latencyMs > 0 {
                Label("\(Int(state.aiClient.latencyMs))ms", systemImage: "timer")
            }
            Label("\(state.aiClient.messages.filter { $0.role == .user }.count) queries", systemImage: "arrow.left.arrow.right")
            Label(state.aiClient.selectedProvider.rawValue, systemImage: state.aiClient.selectedProvider.icon)
            Spacer()
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.3))
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(.black.opacity(0.2))
    }
}
