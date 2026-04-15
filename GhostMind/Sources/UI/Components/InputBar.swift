import SwiftUI

// MARK: - Input Bar

struct InputBar: View {
    @EnvironmentObject var state: AppState
    @State private var inputText = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Interview mode chip
            InterviewModeChip()
                .environmentObject(state)

            // Text field
            ZStack(alignment: .leading) {
                if inputText.isEmpty {
                    Text("Ask about your screen or conversation, or ⌘↵ for Assist")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.3))
                        .lineLimit(1)
                }
                TextField("", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .focused($fieldFocused)
                    .onSubmit { sendMessage() }
            }

            // Send
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(
                        inputText.isEmpty
                            ? AnyShapeStyle(Color.white.opacity(0.15))
                            : AnyShapeStyle(LinearGradient(colors: [.purple, .indigo], startPoint: .top, endPoint: .bottom))
                    )
            }
            .buttonStyle(.plain)
            .disabled(inputText.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.04))
        // Wire transcript selection directly to input field
        .onChange(of: state.selectedText) { text in
            if !text.isEmpty {
                inputText = text
                fieldFocused = true
                
                // Clear selected text after injecting, because now it lives inside the editable input field
                state.selectedText = ""
            }
        }
    }

    private func sendMessage() {
        guard !inputText.isEmpty else { return }
        let prompt = inputText
        inputText = ""
        Task {
            await state.aiClient.query(
                prompt: prompt,
                action: .assist,
                transcript: state.transcriptionEngine.segments,
                contextDocuments: [state.activeContext].filter { !$0.isEmpty }
            )
        }
    }
}


// MARK: - Interview Mode Chip

struct InterviewModeChip: View {
    @EnvironmentObject var state: AppState
    @State private var showPicker = false

    var modeColor: Color {
        switch state.interviewMode {
        case .technical:    return .blue
        case .behavioral:   return .teal
        case .systemDesign: return .purple
        case .hr:           return .pink
        case .salesCall:    return .orange
        case .meeting:      return .gray
        }
    }

    var body: some View {
        Button { showPicker.toggle() } label: {
            HStack(spacing: 4) {
                Circle().fill(modeColor).frame(width: 6, height: 6)
                Text(state.interviewMode.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.white.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Interview Mode")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .top], 12)

                ForEach(AppState.InterviewMode.allCases, id: \.rawValue) { mode in
                    Button {
                        state.interviewMode = mode
                        showPicker = false
                    } label: {
                        HStack {
                            Text(mode.rawValue).font(.system(size: 13))
                            Spacer()
                            if state.interviewMode == mode {
                                Image(systemName: "checkmark").foregroundStyle(.purple)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 10)
            .frame(width: 200)
        }
    }
}
