import SwiftUI

// MARK: - Session History View

struct SessionHistoryView: View {
    @EnvironmentObject var state: AppState
    @State private var searchText = ""
    @State private var selectedSession: MeetingSession?
    @State private var selectedTag: MeetingSession.SessionTag?
    @State private var showDeleteConfirm = false
    @State private var sessionToDelete: MeetingSession?

    var filteredSessions: [MeetingSession] {
        state.sessionManager.savedSessions.filter { session in
            let matchesSearch = searchText.isEmpty
                || session.title.localizedCaseInsensitiveContains(searchText)
                || session.transcript.contains { $0.text.localizedCaseInsensitiveContains(searchText) }
            let matchesTag = selectedTag == nil || session.tags.contains(selectedTag!)
            return matchesSearch && matchesTag
        }
    }

    var body: some View {
        NavigationSplitView {
            // ── Sidebar: session list ───────────────────────────────────────
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search sessions...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(10)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
                .padding(.top, 12)

                // Tag filter
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        TagChip(label: "All", isSelected: selectedTag == nil) {
                            selectedTag = nil
                        }
                        ForEach(MeetingSession.SessionTag.allCases, id: \.rawValue) { tag in
                            TagChip(label: tag.rawValue, isSelected: selectedTag == tag) {
                                selectedTag = selectedTag == tag ? nil : tag
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                Divider().opacity(0.1)

                if filteredSessions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text(searchText.isEmpty ? "No saved sessions yet" : "No results found")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filteredSessions, selection: $selectedSession) { session in
                        SessionRow(session: session)
                            .tag(session)
                            .contextMenu {
                                Button("Export as Markdown") {
                                    state.sessionManager.exportToFile(session: session, format: .markdown)
                                }
                                Button("Export as JSON") {
                                    state.sessionManager.exportToFile(session: session, format: .json)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    sessionToDelete = session
                                    showDeleteConfirm = true
                                }
                            }
                    }
                    .listStyle(.sidebar)
                }
            }
            .navigationTitle("Session History")
            .toolbar {
                ToolbarItem {
                    Text("\(filteredSessions.count) sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        } detail: {
            // ── Detail: session viewer ──────────────────────────────────────
            if let session = selectedSession {
                SessionDetailView(session: session)
                    .environmentObject(state)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Select a session to view")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .confirmationDialog(
            "Delete this session?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let s = sessionToDelete {
                    state.sessionManager.savedSessions.removeAll { $0.id == s.id }
                    if selectedSession?.id == s.id { selectedSession = nil }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: MeetingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(durationText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if !session.tags.isEmpty {
                    ForEach(session.tags, id: \.rawValue) { tag in
                        Text(tag.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.purple.opacity(0.2), in: Capsule())
                            .foregroundStyle(.purple)
                    }
                }
            }
            Text("\(session.transcript.count) transcript lines · \(session.chatMessages.count / 2) AI exchanges")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    var durationText: String {
        let mins = Int(session.duration / 60)
        let secs = Int(session.duration.truncatingRemainder(dividingBy: 60))
        return mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    }
}

// MARK: - Session Detail View

struct SessionDetailView: View {
    @EnvironmentObject var state: AppState
    let session: MeetingSession
    @State private var activeTab: DetailTab = .transcript

    enum DetailTab: String, CaseIterable {
        case transcript = "Transcript"
        case aiLog = "AI Log"
        case export = "Export"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.system(size: 20, weight: .bold))
                    HStack(spacing: 16) {
                        Label(session.startedAt.formatted(date: .long, time: .shortened), systemImage: "calendar")
                        Label(SessionRow(session: session).durationText, systemImage: "timer")
                        Label("\(session.transcript.count) lines", systemImage: "text.bubble")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                // Quick export buttons
                HStack(spacing: 8) {
                    Button {
                        state.sessionManager.exportToFile(session: session, format: .markdown)
                    } label: {
                        Label("Markdown", systemImage: "doc.text")
                    }
                    Button {
                        state.sessionManager.exportToFile(session: session, format: .json)
                    } label: {
                        Label("JSON", systemImage: "curlybraces")
                    }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
            .padding(20)

            Divider()

            // Tabs
            Picker("", selection: $activeTab) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            // Content
            switch activeTab {
            case .transcript:
                TranscriptDetailView(segments: session.transcript)
            case .aiLog:
                AILogDetailView(messages: session.chatMessages)
            case .export:
                ExportPreviewView(session: session)
                    .environmentObject(state)
            }
        }
    }
}

// MARK: - Transcript Detail

struct TranscriptDetailView: View {
    let segments: [TranscriptSegment]
    @State private var searchText = ""

    var filtered: [TranscriptSegment] {
        searchText.isEmpty ? segments : segments.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search transcript...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { segment in
                        HStack(alignment: .top, spacing: 12) {
                            // Time
                            Text(segment.timestamp.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 65, alignment: .trailing)

                            // Speaker badge
                            Text(segment.speaker.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(speakerColor(segment.speaker))
                                .frame(width: 80, alignment: .trailing)

                            // Text
                            Text(segment.text)
                                .font(.system(size: 13))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 7)

                        Divider().padding(.leading, 180).opacity(0.06)
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }

    func speakerColor(_ speaker: TranscriptSegment.Speaker) -> Color {
        switch speaker {
        case .you: return .green
        case .interviewer: return .blue
        case .participant: return .orange
        case .unknown: return .gray
        }
    }
}

// MARK: - AI Log Detail

struct AILogDetailView: View {
    let messages: [ChatMessage]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(messages) { message in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: message.role == .user ? "person.circle.fill" : "brain.fill")
                            .foregroundStyle(message.role == .user ? .purple : .blue)
                            .font(.system(size: 18))

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(message.role == .user ? "You" : "GhostMind AI")
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Text(message.content)
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 20)

                    if message.role == .assistant {
                        Divider().padding(.horizontal, 20).opacity(0.08)
                    }
                }
            }
            .padding(.vertical, 16)
        }
    }
}

// MARK: - Export Preview

struct ExportPreviewView: View {
    @EnvironmentObject var state: AppState
    let session: MeetingSession
    @State private var format: SessionManager.ExportFormat = .markdown
    @State private var previewText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Format", selection: $format) {
                    Text("Markdown").tag(SessionManager.ExportFormat.markdown)
                    Text("Plain Text").tag(SessionManager.ExportFormat.plainText)
                    Text("JSON").tag(SessionManager.ExportFormat.json)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(previewText, forType: .string)
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .controlSize(.small)

                Button {
                    state.sessionManager.exportToFile(session: session, format: format)
                } label: {
                    Label("Save File...", systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            ScrollView {
                Text(previewText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .background(.black.opacity(0.2))
        }
        .onAppear { updatePreview() }
        .onChange(of: format) { _ in updatePreview() }
    }

    private func updatePreview() {
        switch format {
        case .markdown:
            previewText = state.sessionManager.exportMarkdown(session: session)
        case .plainText:
            previewText = state.sessionManager.exportMarkdown(session: session)
                .replacingOccurrences(of: "# ", with: "")
                .replacingOccurrences(of: "## ", with: "")
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "> ", with: "")
                .replacingOccurrences(of: "---", with: "─────")
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            previewText = (try? String(data: encoder.encode(session), encoding: .utf8)) ?? ""
        }
    }
}

// MARK: - Tag Chip

struct TagChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? .white : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    isSelected ? AnyShapeStyle(Color.purple.opacity(0.7)) : AnyShapeStyle(Color.white.opacity(hovered ? 0.1 : 0.06)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovered)
    }
}
