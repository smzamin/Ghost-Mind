import SwiftUI

struct SessionHistoryView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var selectedSession: MeetingSession?
    @State private var isSummarizing = false
    @State private var summaryText: String?

    var body: some View {
        NavigationSplitView {
            List(state.sessionManager.savedSessions, selection: $selectedSession) { session in
                SessionRow(session: session)
                    .tag(session)
                    .contextMenu {
                        Button(role: .destructive) {
                            state.sessionManager.deleteSession(session)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        } detail: {
            if let session = selectedSession {
                SessionDetailView(session: session, isSummarizing: $isSummarizing, summaryText: $summaryText)
            } else {
                VStack {
                    Spacer()
                    Text("Select a session to view details")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: 800, minHeight: 600)
    }
}

struct SessionRow: View {
    let session: MeetingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .font(.system(size: 13, weight: .semibold))
            HStack {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                Text("\(Int(session.duration / 60)) min")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct SessionDetailView: View {
    let session: MeetingSession
    @Binding var isSummarizing: Bool
    @Binding var summaryText: String?
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.title).font(.title2).bold()
                    Text(session.startedAt.formatted()).font(.subheadline).foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            Task {
                                isSummarizing = true
                                summaryText = await state.sessionManager.summarizeSession(session, aiClient: state.aiClient)
                                isSummarizing = false
                            }
                        } label: {
                            Label("Summarize", systemImage: "sparkles")
                        }
                        .disabled(isSummarizing)
                        .buttonStyle(.bordered)

                        Menu {
                            Button("Markdown (.md)") { state.sessionManager.exportToFile(session: session, format: .markdown) }
                            Button("Plain Text (.txt)") { state.sessionManager.exportToFile(session: session, format: .plainText) }
                            Button("JSON (.json)") { state.sessionManager.exportToFile(session: session, format: .json) }
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .fixedSize()
                    }
                }
                Spacer()
            }
            .padding(24)
            .background(Color.white.opacity(0.02))

            Divider()

            if isSummarizing {
                ProgressView("Analyzing session...").padding()
            } else if let summary = summaryText {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Summary").font(.headline)
                        Text(summary)
                            .textSelection(.enabled)
                            .padding()
                            .background(Color.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

                        Button("Clear Summary") { summaryText = nil }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding()
                }
            }

            // Tabs for Transcript / Chat
            TabView {
                // Transcript Tab
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(session.transcript) { seg in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(seg.speaker.rawValue) (\(seg.timestamp.formatted(date: .omitted, time: .shortened)))")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.purple.opacity(0.8))

                                Text(seg.text)
                                    .font(.system(size: 13))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                            .frame(width: 410, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 0)
                }
                .tabItem { Label("Transcript", systemImage: "waveform") }

                // Chat Tab
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(session.chatMessages) { msg in
                            SessionChatBubble(message: msg)
                        }
                    .frame(width: 410, alignment: .leading)
                    }
                    .padding(.horizontal, 0)
                }
                .tabItem { Label("AI Chat", systemImage: "bubble.left.and.bubble.right") }
            }
        }
        .onChange(of: session.id) { _ in
            summaryText = nil // Reset summary when switching sessions
        }
    }
}

struct SessionChatBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            Text(message.role == .user ? "You" : "Assistant")
                .font(.caption).bold().foregroundStyle(.secondary)

            MarkdownText(text: message.content)
                .padding(14)
                .background(
                    message.role == .user
                    ? Color.purple.opacity(0.85)
                    : Color.gray.opacity(0.85)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            message.role == .user ? Color.white : Color.cyan.opacity(0.2),
                            lineWidth: 1
                        )
                )
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(.horizontal, 16)
    }
}
