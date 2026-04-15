import SwiftUI

// MARK: - Transcript Panel

struct TranscriptPanel: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var transcriptionEngine: TranscriptionEngine
    @ObservedObject var audioManager: AudioCaptureManager

    init() {
        // Placeholder — real values injected from environmentObject in body
        _transcriptionEngine = ObservedObject(wrappedValue: TranscriptionEngine())
        _audioManager        = ObservedObject(wrappedValue: AudioCaptureManager())
    }

    // Use state's engines directly for proper @ObservedObject reactivity
    var segments: [TranscriptSegment] { state.transcriptionEngine.segments }
    var partial:  String              { state.transcriptionEngine.partialText }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ────────────────────────────────────────────────────────
            HStack(spacing: 10) {
                Label("Transcript", systemImage: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))

                Spacer()

                // Level meters
                AudioLevelMeter(level: state.audioManager.micLevel,    color: .green, icon: "mic.fill")
                AudioLevelMeter(level: state.audioManager.systemLevel, color: .blue,  icon: "speaker.wave.2.fill")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            // ── STT Status bar ────────────────────────────────────────────────
            STTStatusBar(
                audioManager: state.audioManager,
                transcriptionEngine: state.transcriptionEngine
            )

            Divider().opacity(0.1)

            // ── Transcript rows ───────────────────────────────────────────────
            if segments.isEmpty && partial.isEmpty {
                TranscriptEmptyState(audioManager: state.audioManager)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(segments) { seg in
                                TranscriptRow(segment: seg)
                                    .id(seg.id)
                                    .onTapGesture { state.selectedText = seg.text }
                            }

                            // Partial text (live in-progress)
                            if !partial.isEmpty {
                                Text(partial)
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .italic()
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 4)
                                    .id("partial")
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .onChange(of: segments.count) { _ in
                        withAnimation { proxy.scrollTo(segments.last?.id) }
                    }
                    .onChange(of: partial) { _ in
                        withAnimation { proxy.scrollTo("partial", anchor: .bottom) }
                    }
                }
            }
        }
    }
}

// MARK: - STT Status Bar

struct STTStatusBar: View {
    @ObservedObject var audioManager: AudioCaptureManager
    @ObservedObject var transcriptionEngine: TranscriptionEngine

    var statusText: String {
        switch audioManager.captureStatus {
        case .idle:        return "Idle"
        case .starting:    return "Starting…"
        case .capturing:
            if transcriptionEngine.isListening { return "Listening" }
            return "Audio OK · STT inactive"
        case .error(let m): return m
        }
    }

    var statusColor: Color {
        switch audioManager.captureStatus {
        case .idle:       return .secondary
        case .starting:   return .yellow
        case .capturing:  return transcriptionEngine.isListening ? .green : .yellow
        case .error:      return .red
        }
    }

    var statusIcon: String {
        switch audioManager.captureStatus {
        case .idle:       return "mic.slash"
        case .starting:   return "arrow.triangle.2.circlepath"
        case .capturing:  return transcriptionEngine.isListening ? "mic.fill" : "mic"
        case .error:      return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: statusIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(statusColor)
            Text(statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(statusColor)
                .lineLimit(1)
            Spacer()
            if !transcriptionEngine.permissionGranted && audioManager.isCapturing {
                Text("No STT permission")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(statusColor.opacity(0.06))
    }
}

// MARK: - Transcript Empty State

struct TranscriptEmptyState: View {
    @ObservedObject var audioManager: AudioCaptureManager

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: audioManager.isCapturing ? "waveform.badge.magnifyingglass" : "mic.slash")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.2))
            if audioManager.isCapturing {
                Text("Listening for speech…")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                Text("Speak clearly near the microphone")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.25))
            } else {
                Text("Press Start to begin")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Transcript Row

struct TranscriptRow: View {
    let segment: TranscriptSegment
    @EnvironmentObject var state: AppState
    @State private var hovered = false
    @State private var copied = false

    var speakerColor: Color {
        switch segment.speaker {
        case .you:         return .green
        case .interviewer: return .blue
        case .participant: return .orange
        case .unknown:     return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(speakerColor).frame(width: 6, height: 6)
                Text(segment.speaker.rawValue)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(speakerColor)
                Spacer()
                Text(segment.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
            
            Text(segment.text)
                .font(.system(size: 12.5, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                
            // Quick Actions (only visible on hover)
            if hovered {
                HStack(spacing: 8) {
                    TranscriptHoverAction(icon: "sparkles", title: "Ask AI") {
                        state.selectedText = segment.text
                    }
                    TranscriptHoverAction(icon: "bubble.left.and.exclamationmark.bubble.right", title: "What to say") {
                        state.selectedText = "What should I say to this:\n\n\"\(segment.text)\""
                    }
                    TranscriptHoverAction(icon: "text.alignleft", title: "Summarize") {
                        state.selectedText = "Summarize this:\n\n\"\(segment.text)\""
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(segment.text, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(copied ? .green : .white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(hovered ? Color.white.opacity(0.06) : .clear)
        .overlay(
            Rectangle()
                .fill(speakerColor.opacity(hovered ? 0.3 : 0))
                .frame(width: 2),
            alignment: .leading
        )
        .contentShape(Rectangle())
        .onHover { isHovered in withAnimation(.easeInOut(duration: 0.15)) { hovered = isHovered } }
        .onTapGesture {
            state.selectedText = segment.text
        }
    }
}

// MARK: - Transcript Hover Action

struct TranscriptHoverAction: View {
    let icon: String
    let title: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Audio Level Meter

struct AudioLevelMeter: View {
    let level: Float
    let color: Color
    let icon: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(color.opacity(0.7))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08)).frame(height: 3)
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(geo.size.width * CGFloat(level), 2), height: 3)
                }
            }
            .frame(width: 32, height: 6)
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}
