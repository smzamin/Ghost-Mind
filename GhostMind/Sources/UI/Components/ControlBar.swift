import SwiftUI

// MARK: - Control Bar

struct ControlBar: View {
    @EnvironmentObject var state: AppState
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 8) {
            // App icon + name
            HStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(
                        LinearGradient(colors: [.purple, .indigo], startPoint: .top, endPoint: .bottom)
                    )
                    .font(.system(size: 18, weight: .semibold))
                Text("GhostMind")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            Spacer()

            // Live indicator
            SessionIndicator(sessionManager: state.sessionManager)

            // Queue badge (only when items pending)
            QueueBadge(queueManager: state.queueManager)

            // Settings
            IconButton(icon: "gear", tooltip: "Settings") { showSettings = true }

            // Transcript toggle
            IconButton(
                icon: state.showTranscript ? "text.bubble.fill" : "text.bubble",
                tooltip: "Toggle Transcript (⌘⇧T)",
                tint: state.showTranscript ? .purple : .white.opacity(0.45)
            ) { withAnimation { state.showTranscript.toggle() } }

            // Collapse
            IconButton(
                icon: state.isCollapsed ? "arrow.up.left.and.arrow.down.right" : "minus.circle",
                tooltip: state.isCollapsed ? "Expand" : "Collapse"
            ) { state.isCollapsed.toggle() }

            // Start/Stop (reactive via @ObservedObject)
            StartStopButton(sessionManager: state.sessionManager)
                .environmentObject(state)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Session Indicator

struct SessionIndicator: View {
    @ObservedObject var sessionManager: SessionManager
    @State private var blink = false

    var body: some View {
        if sessionManager.isRecording {
            HStack(spacing: 4) {
                Circle().fill(.red).frame(width: 6, height: 6).opacity(blink ? 1 : 0.3)
                Text("LIVE").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.red)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.red.opacity(0.12), in: Capsule())
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { blink.toggle() } }
        }
    }
}

// MARK: - Queue Badge

struct QueueBadge: View {
    @ObservedObject var queueManager: RequestQueueManager

    var body: some View {
        if queueManager.pendingCount > 0 || queueManager.hasFailed {
            HStack(spacing: 4) {
                Image(systemName: queueManager.hasFailed ? "exclamationmark.triangle.fill" : "clock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(queueManager.hasFailed ? .orange : .yellow)
                Text(queueManager.pendingCount > 0 ? "\(queueManager.pendingCount)" : "!")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(queueManager.hasFailed ? .orange : .yellow)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(
                queueManager.hasFailed ? Color.orange.opacity(0.15) : Color.yellow.opacity(0.12),
                in: Capsule()
            )
        }
    }
}

// MARK: - Provider + Model Badge (no default model — user must select)

struct ProviderModelBadge: View {
    @ObservedObject var aiClient: AIClient
    @State private var showPicker = false

    var displayText: String {
        if aiClient.selectedModel.isEmpty {
            return aiClient.selectedProvider == .openAI ? "Select Model" : aiClient.selectedProvider.rawValue
        }
        return "\(aiClient.selectedProvider.shortName) · \(aiClient.selectedModel)"
    }

    var body: some View {
        Button { showPicker.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: aiClient.selectedProvider.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(displayText)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(aiClient.selectedModel.isEmpty ? .orange.opacity(0.9) : .white.opacity(0.9))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                aiClient.selectedModel.isEmpty
                    ? Color.orange.opacity(0.12)
                    : Color.white.opacity(0.08),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    aiClient.selectedModel.isEmpty ? Color.orange.opacity(0.25) : Color.white.opacity(0.12),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            ProviderModelPicker(aiClient: aiClient)
        }
        .help(aiClient.selectedModel.isEmpty ? "Select AI provider and model" : "Change provider or model")
    }
}

// MARK: - Provider + Model Picker Popover

struct ProviderModelPicker: View {
    @ObservedObject var aiClient: AIClient
    @State private var customModel: String = ""

    // Per-provider available models
    var modelsForProvider: [String] {
        switch aiClient.selectedProvider {
        case .openAI:      return ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-3.5-turbo", "o1", "o1-mini"]
        case .gemini:      return ["gemini-2.0-flash", "gemini-1.5-pro", "gemini-1.5-flash", "gemini-2.0-flash-lite"]
        case .anthropic:   return ["claude-opus-4-5", "claude-sonnet-4-5", "claude-3-5-haiku-20241022", "claude-3-5-sonnet-20241022"]
        case .groq:        return ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "mixtral-8x7b-32768", "gemma2-9b-it"]
        case .openRouter:  return ["openai/gpt-4o", "anthropic/claude-3.5-sonnet", "google/gemini-pro-1.5", "meta-llama/llama-3.1-70b-instruct"]
        case .nvidia:      return ["meta/llama-3.1-70b-instruct", "mistralai/mixtral-8x7b-instruct-v0.1"]
        case .ollama:      return ["llama3.2", "llama3.1", "mistral", "codellama", "qwen2.5-coder"]
        case .custom:      return []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Provider")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)

            Divider()

            // Provider list
            ForEach(AIProvider.allCases) { provider in
                Button {
                    aiClient.selectedProvider = provider
                    // Reset model when changing provider — no default
                    aiClient.selectedModel = ""
                    customModel = ""
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: provider.icon)
                            .foregroundStyle(aiClient.selectedProvider == provider ? .purple : .secondary)
                            .frame(width: 18)
                        Text(provider.rawValue)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                        Spacer()
                        if aiClient.selectedProvider == provider {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.purple)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .background(aiClient.selectedProvider == provider ? Color.purple.opacity(0.1) : .clear)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Model selection for selected provider
            VStack(alignment: .leading, spacing: 8) {
                Text("Model")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                if !modelsForProvider.isEmpty {
                    ForEach(modelsForProvider, id: \.self) { model in
                        Button {
                            aiClient.selectedModel = model
                        } label: {
                            HStack {
                                Text(model)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if aiClient.selectedModel == model {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.purple)
                                        .font(.system(size: 13))
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(
                                aiClient.selectedModel == model ? Color.purple.opacity(0.1) : .clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Custom model input
                HStack {
                    TextField("Custom model name...", text: $customModel)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    Button("Use") {
                        if !customModel.isEmpty {
                            aiClient.selectedModel = customModel
                        }
                    }
                    .disabled(customModel.isEmpty)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }
            .padding(14)
        }
        .frame(width: 280)
        .onAppear { customModel = modelsForProvider.contains(aiClient.selectedModel) ? "" : aiClient.selectedModel }
    }
}

// MARK: - Start / Stop Button

struct StartStopButton: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var sessionManager: SessionManager

    var body: some View {
        Button {
            Task {
                if sessionManager.isRecording {
                    state.stopSession()
                } else {
                    await state.startSession()
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: sessionManager.isRecording ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(sessionManager.isRecording ? "Stop" : "Start")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                sessionManager.isRecording
                    ? AnyShapeStyle(Color.red.opacity(0.85))
                    : AnyShapeStyle(LinearGradient(colors: [.purple, .indigo], startPoint: .leading, endPoint: .trailing)),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Icon Button

struct IconButton: View {
    let icon: String
    var tooltip: String = ""
    var tint: Color = .white.opacity(0.55)
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(hovered ? .white : tint)
                .frame(width: 28, height: 28)
                .background(hovered ? Color.white.opacity(0.1) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovered)
    }
}
