import SwiftUI

// MARK: - Quick Action Bar

struct QuickActionBar: View {
    @EnvironmentObject var state: AppState

    struct Action {
        let label: String
        let icon: String
        let color: Color
        let aiAction: AIAction
    }

    let actions: [Action] = [
        Action(label: "Assist",              icon: "rocket",                color: .purple,  aiAction: .assist),
        Action(label: "What should I say?",  icon: "bubble.left.fill",      color: .blue,    aiAction: .whatToSay),
        Action(label: "Follow-ups",          icon: "arrow.triangle.branch", color: .teal,    aiAction: .followUp),
        Action(label: "Recap",               icon: "clock.arrow.circlepath",color: .orange,  aiAction: .recap),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(actions, id: \.label) { action in
                QuickActionButton(
                    label: action.label,
                    icon: action.icon,
                    color: action.color
                ) {
                    let prompt: String
                    switch action.aiAction {
                    case .assist:    prompt = state.selectedText.isEmpty ? "What is happening now?" : state.selectedText
                    case .whatToSay: prompt = state.selectedText.isEmpty ? "What should I say next?" : "How should I respond to: \(state.selectedText)"
                    case .followUp:  prompt = "Given this conversation, what follow-up questions will come next?"
                    case .recap:     prompt = "Please summarize the conversation so far."
                    }
                    Task {
                        await state.aiClient.query(
                            prompt: prompt,
                            action: action.aiAction,
                            transcript: state.transcriptionEngine.segments,
                            contextDocuments: [state.activeContext].filter { !$0.isEmpty }
                        )
                    }
                }
            }

            // Read Screen — OCR the display and send to AI
            ReadScreenButton()
                .environmentObject(state)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.2))
    }
}

// MARK: - Quick Action Button

struct QuickActionButton: View {
    let label: String
    let icon: String
    let color: Color
    let action: () -> Void
    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) {
                pressed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                pressed = false
            }
            action()
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .foregroundStyle(hovered ? .white : color.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                hovered
                    ? color.opacity(0.25)
                    : color.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        hovered ? color.opacity(0.4) : color.opacity(0.15),
                        lineWidth: 1
                    )
            )
            .scaleEffect(pressed ? 0.95 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovered)
    }
}

// MARK: - Read Screen Button

struct ReadScreenButton: View {
    @EnvironmentObject var state: AppState
    @State private var isScanning = false
    @State private var hovered = false

    var body: some View {
        Button {
            isScanning = true
            Task {
                let result = await state.screenReader.captureOnce()
                isScanning = false
                if let text = result?.text, !text.isEmpty {
                    // Inject screen content as context
                    let prompt = "I can see the following content on screen:\n\n\(text)\n\nPlease help me with this."
                    await state.aiClient.query(
                        prompt: prompt,
                        action: .assist,
                        transcript: state.transcriptionEngine.segments,
                        contextDocuments: [state.activeContext].filter { !$0.isEmpty }
                    )
                }
            }
        } label: {
            HStack(spacing: 6) {
                if isScanning {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.cyan)
                } else {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(isScanning ? "Reading..." : "Read Screen")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .foregroundStyle(hovered ? .white : Color.cyan.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                hovered ? Color.cyan.opacity(0.25) : Color.cyan.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        hovered ? Color.cyan.opacity(0.4) : Color.cyan.opacity(0.15),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isScanning)
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovered)
        .help("OCR the current screen and send to AI (⌘⇧S)")
    }
}
