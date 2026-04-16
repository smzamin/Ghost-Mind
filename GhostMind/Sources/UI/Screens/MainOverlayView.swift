import SwiftUI
import AppKit
import Combine

// MARK: - Context Document (with parsed sections)

struct ContextDocument: Identifiable, Codable {
    let id: UUID
    var name: String
    var rawContent: String
    var sections: [ContextSection]
    var isActive: Bool

    init(id: UUID = UUID(), name: String, rawContent: String) {
        self.id = id
        self.name = name
        self.rawContent = rawContent
        self.isActive = true
        self.sections = [] 
        // Parsing is now handled asynchronously by AppState
    }

    /// Parse markdown headings into named sections.
    /// Only sections WITH a heading are returned — headingless content is ignored per user spec.
    static func parseSections(from content: String) async -> [ContextSection] {
        return await Task.detached(priority: .userInitiated) {
            parseSectionsSync(from: content)
        }.value
    }

    static func parseSectionsSync(from content: String) -> [ContextSection] {
        var sections: [ContextSection] = []
        var currentHeading: String? = nil
        var currentLines: [String] = []

        for line in content.components(separatedBy: "\n") {
            if let heading = extractHeading(from: line) {
                if let h = currentHeading, !currentLines.isEmpty {
                    sections.append(ContextSection(
                        heading: h,
                        content: currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
                currentHeading = heading
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        if let h = currentHeading, !currentLines.isEmpty {
            sections.append(ContextSection(
                heading: h,
                content: currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return sections
    }

    private static func extractHeading(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        // Strip leading # and spaces
        return trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
    }

    /// Build the context string injected into AI prompts — only active sections with headings
    var contextForAI: String {
        guard isActive else { return "" }
        return sections.filter { !$0.content.isEmpty }
            .map { "### \($0.heading)\n\($0.content)" }
            .joined(separator: "\n\n")
    }
}

struct ContextSection: Identifiable, Codable {
    let id: UUID
    let heading: String
    let content: String
    init(id: UUID = UUID(), heading: String, content: String) {
        self.id = id; self.heading = heading; self.content = content
    }
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    let audioManager        = AudioCaptureManager()
    let transcriptionEngine = TranscriptionEngine()
    let aiClient            = AIClient()
    let sessionManager      = SessionManager()
    let screenReader        = ScreenReaderEngine()
    let keyManager          = ProviderKeyManager()
    let queueManager        = RequestQueueManager()

    @Published var showTranscript: Bool = true {
        didSet { UserDefaults.standard.set(showTranscript, forKey: Constants.UserDefaults.showTranscript) }
    }
    @Published var isCollapsed    = false
    @Published var opacity: Double = 1.0 {
        didSet { UserDefaults.standard.set(opacity, forKey: Constants.UserDefaults.opacity) }
    }
    @Published var interviewMode: InterviewMode = .technical {
        didSet {
            UserDefaults.standard.set(interviewMode.rawValue, forKey: Constants.UserDefaults.interviewMode)
            aiClient.activeMode = interviewMode.rawValue
        }
    }
    @Published var contextDocuments: [ContextDocument] = []
    @Published var selectedText: String = ""
    @Published var isStealth: Bool = false
    @Published var showHistory: Bool = false
    @Published var transcriptWidth: CGFloat = 380 {
        didSet { UserDefaults.standard.set(transcriptWidth, forKey: Constants.UserDefaults.transcriptWidth) }
    }

    enum InterviewMode: String, CaseIterable {
        case technical = "Technical"
        case behavioral = "Behavioral"
        case systemDesign = "System Design"
        case hr = "HR / Culture"
        case salesCall = "Sales Call"
        case meeting = "General Meeting"
    }

    /// All active context sections as a single AI-ready string
    var activeContext: String {
        contextDocuments.compactMap { $0.contextForAI }.filter { !$0.isEmpty }.joined(separator: "\n\n---\n\n")
    }

    init() {
        // Load initial state
        self.showTranscript = UserDefaults.standard.bool(forKey: Constants.UserDefaults.showTranscript)
        self.opacity = UserDefaults.standard.double(forKey: Constants.UserDefaults.opacity) == 0 ? 1.0 : UserDefaults.standard.double(forKey: Constants.UserDefaults.opacity)
        self.transcriptWidth = UserDefaults.standard.object(forKey: Constants.UserDefaults.transcriptWidth) as? CGFloat ?? 380
        if let modeStr = UserDefaults.standard.string(forKey: Constants.UserDefaults.interviewMode),
           let mode = InterviewMode(rawValue: modeStr) {
            self.interviewMode = mode
        }

        // ── Wire key rotation manager into AI client ──────────────────────────
        aiClient.keyManager = keyManager

        aiClient.onMessageAdded = { [weak self] msg in
            self?.sessionManager.addChatMessage(msg)
        }

        // ── Wire queue manager ────────────────────────────────────────
        queueManager.aiClient = aiClient
        queueManager.onComplete = { [weak self] _, response in
            Task { @MainActor in
                guard let self else { return }
                let msg = ChatMessage(id: UUID(), role: .assistant, content: response, timestamp: Date())
                self.aiClient.messages.append(msg)
                self.sessionManager.addChatMessage(msg)
            }
        }

        // ── CRITICAL: Wire mic buffer → STT (no Task hop — direct thread call) ──
        // feedMicBuffer is nonisolated so it can be called right from the tap thread
        audioManager.onMicBuffer = { [weak transcriptionEngine] buffer in
            transcriptionEngine?.feedMicBuffer(buffer)
        }

        // ── Segment-based STT providers (local/cloud) ─────────────────────────
        audioManager.onAudioSegment = { [weak self] segment in
            Task { @MainActor in
                await self?.transcriptionEngine.handleAudioSegment(segment)
            }
        }

        // ── Real-time Translation Handler ───────────────────────────────────
        transcriptionEngine.translationStream
            .receive(on: DispatchQueue.main)
            .sink { [weak self] segment in
                guard let self else { return }
                Task {
                    let translatedText = await self.translateToEnglish(segment.text)
                    self.transcriptionEngine.appendSegment(text: translatedText, speaker: segment.speaker)
                }
            }
            .store(in: &cancellables)

        // ── Wire transcript → session ─────────────────────────────────────────
        transcriptionEngine.segmentsStream
            .receive(on: DispatchQueue.main)
            .sink { [weak self] segment in
                self?.sessionManager.addTranscriptSegment(segment)
            }
            .store(in: &cancellables)

        // ── Global shortcut observers ─────────────────────────────────────────
        NotificationCenter.default.addObserver(forName: Constants.Notification.instantAssist, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let prompt = self.transcriptionEngine.segments.last(where: { $0.speaker == .interviewer })?.text
                    ?? "What is happening in the meeting right now?"
                await self.aiClient.query(
                    prompt: prompt, action: .assist,
                    transcript: self.transcriptionEngine.segments,
                    contextDocuments: [self.activeContext].filter { !$0.isEmpty }
                )
            }
        }

        NotificationCenter.default.addObserver(forName: Constants.Notification.toggleTranscript, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showTranscript.toggle() }
        }

        NotificationCenter.default.addObserver(forName: Constants.Notification.readScreen, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let result = await self.screenReader.captureOnce(), !result.text.isEmpty {
                    await self.aiClient.query(
                        prompt: "I see this on screen:\n\n\(result.text)\n\nHelp me with this.",
                        action: .assist,
                        transcript: self.transcriptionEngine.segments,
                        contextDocuments: [self.activeContext].filter { !$0.isEmpty }
                    )
                }
            }
        }
        // NOTE: NO collapseStateChanged observer here — that lives only in StealthWindowController
    }

    func startSession() async {
        await transcriptionEngine.requestPermissions()
        await audioManager.startCapture()
        transcriptionEngine.start(locale: Locale(identifier: transcriptionEngine.detectedLanguage))
        sessionManager.startSession()
    }

    func stopSession() {
        audioManager.stopCapture()
        transcriptionEngine.stop()
        sessionManager.endSession()
    }

    private func translateToEnglish(_ text: String) async -> String {
        let prompt = "Translate the following audio transcript to English. Only return the translated text. If it is already in English, return it as is:\n\n\"\(text)\""
        let result = await aiClient.queryForBackground(prompt: prompt)
        return result ?? text
    }
    
    private var cancellables = Set<AnyCancellable>()
}

// MARK: - MainOverlayView

struct MainOverlayView: View {
    @StateObject private var state = AppState()
    @State private var showSettings = false
    @State private var dragStartingWidth: CGFloat = 380

    var body: some View {
        ZStack(alignment: .top) {
            // ── Background ────────────────────────────────────────────────────
            Color.black
                .opacity(1.0)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(spacing: 0) {
                ControlBar(showSettings: $showSettings)
                    .environmentObject(state)

                if !state.isCollapsed {
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)

                    HStack(spacing: 0) {
                        if state.showTranscript {
                            TranscriptPanel(
                                transcriptionEngine: state.transcriptionEngine,
                                audioManager: state.audioManager
                            )
                                .environmentObject(state)
                                .frame(width: state.transcriptWidth)
                                .transition(.move(edge: .leading).combined(with: .opacity))

                            // ── Draggable Divider ──────────────────────────────
                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .frame(width: 4)
                                .padding(.horizontal, 4)
                                .contentShape(Rectangle())
                                .cursor(.resizeLeftRight)
                                .highPriorityGesture(
                                    DragGesture()
                                        .onChanged { value in
                                            // Capture start width on first frame of drag
                                            if value.translation.width == value.location.x - value.startLocation.x {
                                                // (Approximation for 'first frame if needed, but easier to just use a local state)
                                            }
                                            let newWidth = dragStartingWidth + value.translation.width
                                            state.transcriptWidth = max(380, min(680, newWidth))
                                        }
                                        .onEnded { _ in
                                            // Persist to disk ONLY on release for performance
                                            dragStartingWidth = state.transcriptWidth
                                            UserDefaults.standard.set(state.transcriptWidth, forKey: "transcriptWidth")
                                        }
                                )
                                .onAppear {
                                    dragStartingWidth = state.transcriptWidth
                                }
                        }
                        AIChatPanel(aiClient: state.aiClient, queueManager: state.queueManager)
                            .environmentObject(state)
                    }
                    .frame(minHeight: 400)

                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)

                    QuickActionBar()
                        .environmentObject(state)

                    Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)

                    InputBar()
                        .environmentObject(state)
                }
            }
        }
        .frame(
            minWidth:  state.isCollapsed ? 300 : 820,
            maxWidth:  state.isCollapsed ? 300 : .infinity,
            minHeight: state.isCollapsed ? 50  : 540,
            maxHeight: state.isCollapsed ? 50  : .infinity
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(state.isStealth ? 0.02 : 0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(state.isStealth ? 0 : 0.7), radius: 30, y: 12)
        .opacity(state.opacity)
        .animation(.easeInOut(duration: 0.22), value: state.isCollapsed)
        .animation(.easeInOut(duration: 0.2), value: state.showTranscript)
        // Post notification for NSWindow resize — StealthWindowController handles this
        .onChange(of: state.isCollapsed) { collapsed in
            // Dispatch async so SwiftUI layout finishes before window resize
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Constants.Notification.collapseStateChanged, object: collapsed)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(state)
        }
        .sheet(isPresented: $state.showHistory) {
            SessionHistoryView()
                .environmentObject(state)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let err = state.aiClient.errorMessage {
                    ErrorBannerView(errorMessage: err, onDismiss: { state.aiClient.errorMessage = nil })
                }
                if let err = state.audioManager.errorMessage {
                    ErrorBannerView(errorMessage: err, onDismiss: { state.audioManager.errorMessage = nil })
                }
            }
            .padding(.top, 52)
        }
    }
}

// MARK: - Error Banner (Reusable View)

struct ErrorBannerView: View {
    let errorMessage: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(errorMessage)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.red.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.red.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 14)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.spring(), value: errorMessage)
    }
}
