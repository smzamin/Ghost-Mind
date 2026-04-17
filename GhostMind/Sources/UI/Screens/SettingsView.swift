import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var selectedTab: SettingsTab = .apiKeys

    enum SettingsTab: String, CaseIterable {
        case apiKeys  = "AI API Keys"
        case voice    = "Voice / STT"
        case context  = "Context"
        case history  = "History"
        case privacy  = "Privacy"
        case about    = "About"

        var icon: String {
            switch self {
            case .apiKeys:  return "key.fill"
            case .voice:    return "waveform.badge.mic"
            case .context:  return "doc.richtext.fill"
            case .history:  return "clock.arrow.circlepath"
            case .privacy:  return "lock.shield.fill"
            case .about:    return "info.circle.fill"
            }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .font(.system(size: 13))
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .frame(minWidth: 185, maxWidth: 185)
        } detail: {
            ScrollView {
                Group {
                    switch selectedTab {
                    case .apiKeys: APIKeysSettingsView(aiClient: state.aiClient).environmentObject(state)
                    case .voice:   VoiceSTTSettingsView(transcriptionEngine: state.transcriptionEngine).environmentObject(state)
                    case .context: ContextDocumentsView().environmentObject(state)
                    case .history: SessionHistoryView().environmentObject(state)
                    case .privacy: PrivacySettingsView()
                    case .about:   AboutView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(20)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 800, minHeight: 540)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(action: { dismiss() }) {
                    Label("Close", systemImage: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }
}

// MARK: - AI API Keys Settings

struct APIKeysSettingsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var aiClient: AIClient
    @State private var expandedProvider: AIProvider? = AIProvider.allCases.first
    @State private var showRotationLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Provider API Keys")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Multiple keys per provider · automatic round-robin rotation · quota cooldown")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showRotationLog.toggle()
                } label: {
                    Label("Rotation Log", systemImage: "list.bullet.rectangle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Rotation log sheet
            if showRotationLog {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Key Rotation Log")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("Clear") {
                            aiClient.rotationLog.removeAll()
                        }
                        .controlSize(.small)
                        Button { showRotationLog = false } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            if aiClient.rotationLog.isEmpty {
                                Text("No rotations yet — start a session and ask a question.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .padding(8)
                            } else {
                                ForEach(state.aiClient.rotationLog, id: \.self) { line in
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .frame(maxHeight: 140)
                    .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(14)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Active provider + model + opacity (multi-line)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Active Provider")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Select which provider GhostMind uses for responses. Provider-specific keys/models are configured below.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Picker("", selection: $aiClient.selectedProvider) {
                        ForEach(AIProvider.allCases) { p in
                            Label(p.rawValue, systemImage: p.icon).tag(p)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240, alignment: .leading)

                    Spacer()

                    HStack(spacing: 8) {
                        Text("Opacity")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Slider(value: $state.opacity, in: 0.3...1.0, step: 0.05)
                            .frame(width: 140)
                        Text("\(Int(state.opacity * 100))%")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Model Override")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Global default (optional)", text: $aiClient.selectedModel)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.1), lineWidth: 1))
                        .frame(maxWidth: 420, alignment: .leading)
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            // Provider cards
            ForEach(AIProvider.allCases) { provider in
                ProviderKeyCard(
                    provider: provider,
                    keyManager: state.keyManager,
                    isExpanded: expandedProvider == provider,
                    onToggle: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                            expandedProvider = expandedProvider == provider ? nil : provider
                        }
                    }
                )
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: showRotationLog)
    }
}

// MARK: - Provider Key Card

struct ProviderKeyCard: View {
    let provider: AIProvider
    @ObservedObject var keyManager: ProviderKeyManager
    let isExpanded: Bool
    let onToggle: () -> Void

    var config: ProviderKeyManager.ProviderConfig { keyManager.config(for: provider) }

    var activeCount: Int  { config.keys.filter { $0.isAvailable }.count }
    var totalCount:  Int  { config.keys.filter { !$0.key.isEmpty }.count }

    var statusBadge: (text: String, color: Color) {
        if totalCount == 0 { return ("No keys", .secondary) }
        if activeCount == 0 { return ("All cooled down", .orange) }
        return ("\(activeCount)/\(totalCount) active", .green)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row (always visible)
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    Image(systemName: provider.icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isExpanded ? .purple : .secondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.rawValue)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("Default model: \(provider.defaultModel)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    // Active key count badge
                    Text(statusBadge.text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(statusBadge.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(statusBadge.color.opacity(0.12), in: Capsule())

                    // Reset all cooled keys
                    if activeCount < totalCount && totalCount > 0 {
                        Button {
                            keyManager.resetAllKeys(for: provider)
                        } label: {
                            Image(systemName: "arrow.clockwise.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("Reset all cooldowns for \(provider.rawValue)")
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded body
            if isExpanded {
                Divider().opacity(0.3)

                VStack(alignment: .leading, spacing: 14) {

                    // Custom model field
                    HStack(spacing: 10) {
                        Text("Model")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)

                        TextField("Leave blank to use default (\(provider.defaultModel))", text: Binding(
                            get: { keyManager.customModel(for: provider) },
                            set: { keyManager.setCustomModel($0, for: provider) }
                        ))
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    }

                    if provider == .custom {
                        HStack(spacing: 10) {
                            Text("Base URL")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .leading)

                            TextField("https://example.com/v1", text: Binding(
                                get: { keyManager.customBaseURL(for: provider) },
                                set: { keyManager.setCustomBaseURL($0, for: provider) }
                            ))
                            .font(.system(size: 13, design: .monospaced))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.1), lineWidth: 1))
                        }
                    }

                    // Keys list
                    VStack(spacing: 8) {
                        ForEach(config.keys) { entry in
                            KeyEntryRow(
                                entry: entry,
                                provider: provider,
                                keyManager: keyManager
                            )
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.96).combined(with: .opacity),
                                removal:   .scale(scale: 0.96).combined(with: .opacity)
                            ))
                        }
                    }
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: config.keys.count)

                    // Add Key button
                    Button {
                        withAnimation { keyManager.addKey(to: provider) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.purple)
                            Text("Add API Key")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.purple)
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.purple.opacity(0.2), lineWidth: 1, antialiased: true)
                        )
                    }
                    .buttonStyle(.plain)

                    if config.keys.isEmpty {
                        Text("No keys yet. Click '+' above to add your first API key.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(16)
            }
        }
        .background(Color.white.opacity(isExpanded ? 0.06 : 0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isExpanded ? Color.purple.opacity(0.25) : Color.white.opacity(0.07),
                    lineWidth: 1
                )
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isExpanded)
    }
}

// MARK: - Key Entry Row

struct KeyEntryRow: View {
    let entry: ProviderKeyManager.KeyEntry
    let provider: AIProvider
    @ObservedObject var keyManager: ProviderKeyManager

    @State private var localKey: String = ""
    @State private var revealed = false
    @State private var justSaved = false

    var status: ProviderKeyManager.KeyStatus { entry.status }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Status dot
                Image(systemName: status.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(status.color)

                // Label / index
                Text(entry.label.isEmpty ? "Key \(keyIndex)" : entry.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                // Status tag
                Text(status.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(status.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(status.color.opacity(0.12), in: Capsule())

                // Reset cooldown button (only when cooled down)
                if case .cooldown = status {
                    Button {
                        keyManager.resetKey(id: entry.id, for: provider)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Reset cooldown")
                }

                // Enable/Disable toggle
                Button {
                    keyManager.toggleKey(id: entry.id, for: provider)
                } label: {
                    Image(systemName: entry.isEnabled ? "pause.circle" : "play.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(entry.isEnabled ? Color.secondary : Color.green)
                }
                .buttonStyle(.plain)
                .help(entry.isEnabled ? "Disable key" : "Enable key")

                // Delete
                Button {
                    withAnimation { keyManager.removeKey(id: entry.id, from: provider) }
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Remove key")
            }

            // Key input row
            HStack(spacing: 6) {
                Group {
                    if revealed {
                        TextField("Paste API key here...", text: $localKey)
                    } else {
                        SecureField("Paste API key here...", text: $localKey)
                    }
                }
                .font(.system(size: 13, design: .monospaced))
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(
                    entry.isEnabled
                        ? Color.white.opacity(0.07)
                        : Color.white.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            justSaved ? Color.green.opacity(0.5) : Color.white.opacity(0.1),
                            lineWidth: 1
                        )
                )
                .onChange(of: localKey) { newVal in
                    keyManager.updateKey(id: entry.id, for: provider, newKey: newVal)
                    // Brief green flash to confirm save
                    justSaved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justSaved = false }
                }
                .opacity(entry.isEnabled ? 1 : 0.5)

                // Reveal/hide
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .onAppear { localKey = entry.key }
    }

    private var keyIndex: Int {
        let keys = keyManager.config(for: provider).keys
        return (keys.firstIndex(where: { $0.id == entry.id }) ?? 0) + 1
    }
}


// MARK: - Voice / STT Settings

struct VoiceSTTSettingsView: View {
    @ObservedObject var transcriptionEngine: TranscriptionEngine
    @ObservedObject var sttConfig: STTConfiguration
    private let store: KeyValueStore = UserDefaultsStore(prefix: "ghostmind.stt.")
    @State private var feedback: (text: String, isError: Bool)?

    init(transcriptionEngine: TranscriptionEngine) {
        self.transcriptionEngine = transcriptionEngine
        self.sttConfig = transcriptionEngine.sttConfig
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeader(
                title: "Voice Recognition (STT)",
                subtitle: "Separate from AI providers — controls speech-to-text transcription engine"
            )

            // Provider selection
            VStack(spacing: 0) {
                ForEach(STTProvider.allCases) { provider in
                    Button {
                        sttConfig.selectedProvider = provider
                        sttConfig.selectedModel = ""
                        feedback = nil
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: provider.icon)
                                .foregroundStyle(sttConfig.selectedProvider == provider ? .purple : .secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.rawValue)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text(STTProvider.specs[provider]?.helpText ?? "")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if sttConfig.selectedProvider == provider {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.purple)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .background(
                            sttConfig.selectedProvider == provider
                                ? Color.purple.opacity(0.08) : .clear
                        )
                    }
                    .buttonStyle(.plain)
                    if provider != STTProvider.allCases.last { Divider() }
                }
            }
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            let currentProvider = sttConfig.selectedProvider

            if let msg = transcriptionEngine.providerStatusMessage, !msg.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: msg.lowercased().contains("error") ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(msg.lowercased().contains("error") ? .orange : .secondary)
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }

            // Model selection
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Model", subtitle: "Leave blank to use provider default")
                if !currentProvider.availableModels.isEmpty {
                    Picker("", selection: $sttConfig.selectedModel) {
                        Text("Select model...").tag("")
                        ForEach(currentProvider.availableModels, id: \.self) { m in
                            Text(m).font(.system(.body, design: .monospaced)).tag(m)
                        }
                    }
                    .labelsHidden()
                } else {
                    TextField("Model name", text: $sttConfig.selectedModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            // API key for STT provider
            if currentProvider.apiKeyRequired {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "API Key for \(currentProvider.rawValue)", subtitle: "Stored locally on this Mac")
                    STTAPIKeyRow(provider: currentProvider, store: store) { ok in
                        feedback = ok ? ("Saved", false) : ("Invalid key", true)
                    }
                }
                .padding(16)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }

            // Local endpoint for whisper.cpp
            if currentProvider.endpointRequired {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Local Endpoint", subtitle: "whisper.cpp server address")
                    TextField("http://localhost:8178", text: $sttConfig.localEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                    Text("Start with: ./server -m models/ggml-base.en.bin -p 8178")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }

            if let feedback {
                HStack(spacing: 8) {
                    Image(systemName: feedback.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(feedback.isError ? .red : .green)
                    Text(feedback.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background((feedback.isError ? Color.red : Color.green).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - STT API Key Row

struct STTAPIKeyRow: View {
    let provider: STTProvider
    @State private var keyText: String = ""
    @State private var revealed = false
    let store: KeyValueStore
    let onValidate: (Bool) -> Void

    private var storageKey: String { "api_key.\(provider.id)" }

    var body: some View {
        HStack {
            Group {
                if revealed {
                    TextField("Enter API key", text: $keyText)
                } else {
                    SecureField("Enter API key", text: $keyText)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .onChange(of: keyText) { v in
                let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                store.set(trimmed.isEmpty ? nil : trimmed, forKey: storageKey)
                onValidate(Self.isValidKey(trimmed))
            }
            Button { revealed.toggle() } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .onAppear { keyText = store.string(forKey: storageKey) ?? "" }
    }

    private static func isValidKey(_ key: String) -> Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10
    }
}

// MARK: - Context Documents View

struct ContextDocumentsView: View {
    @EnvironmentObject var state: AppState
    @State private var showFilePicker = false
    @State private var showManualAdd = false
    @State private var manualName = ""
    @State private var manualContent = ""
    @State private var expandedDoc: UUID? = nil
    @State private var editingDoc: ContextDocument? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header + actions
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Context Documents")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Import .md files or paste content. Only sections with headings (# Title) are used as context.\nSections without headings are ignored.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Import .md file", systemImage: "doc.badge.plus")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fileImporter(
                        isPresented: $showFilePicker,
                        allowedContentTypes: [.text, .plainText, UTType(filenameExtension: "md") ?? .text],
                        allowsMultipleSelection: true
                    ) { result in
                        handleFileImport(result)
                    }

                    Button {
                        showManualAdd = true
                    } label: {
                        Label("Add Manually", systemImage: "square.and.pencil")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            // Active context summary
            if !state.activeContext.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(state.contextDocuments.filter { $0.isActive }.count) document(s) active · \(state.activeContext.count) chars of context")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            // Document list
            if state.contextDocuments.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No documents added yet")
                        .foregroundStyle(.secondary)
                    Text("Import a .md file or add content manually.\nOnly sections with markdown headings will be used.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(40)
            } else {
                ForEach(state.contextDocuments) { doc in
                    ContextDocumentCard(
                        doc: binding(for: doc),
                        isExpanded: expandedDoc == doc.id,
                        onToggleExpand: {
                            withAnimation { expandedDoc = expandedDoc == doc.id ? nil : doc.id }
                        },
                        onEdit: {
                            editingDoc = doc
                        },
                        onDelete: {
                            state.contextDocuments.removeAll { $0.id == doc.id }
                        }
                    )
                }
            }
        }
        .sheet(isPresented: $showManualAdd) {
            DocumentEditorSheet(
                title: "Add Context Document",
                name: $manualName,
                content: $manualContent,
                onSave: {
                    var doc = ContextDocument(name: manualName, rawContent: manualContent)
                    doc.sections = ContextDocument.parseSectionsSync(from: manualContent)
                    state.contextDocuments.append(doc)
                    manualName = ""; manualContent = ""
                    showManualAdd = false
                },
                onCancel: { showManualAdd = false }
            )
        }
        .sheet(item: $editingDoc) { doc in
            var name = doc.name
            var content = doc.rawContent
            DocumentEditorSheet(
                title: "Edit Context Document",
                name: Binding(get: { name }, set: { name = $0 }),
                content: Binding(get: { content }, set: { content = $0 }),
                onSave: {
                    if let idx = state.contextDocuments.firstIndex(where: { $0.id == doc.id }) {
                        var updated = doc
                        updated.name = name
                        updated.rawContent = content
                        updated.sections = ContextDocument.parseSectionsSync(from: content)
                        state.contextDocuments[idx] = updated
                    }
                    editingDoc = nil
                },
                onCancel: { editingDoc = nil }
            )
        }
    }

    private func binding(for doc: ContextDocument) -> Binding<ContextDocument> {
        Binding(
            get: { state.contextDocuments.first(where: { $0.id == doc.id }) ?? doc },
            set: { newVal in
                if let idx = state.contextDocuments.firstIndex(where: { $0.id == doc.id }) {
                    state.contextDocuments[idx] = newVal
                }
            }
        )
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                if let content = try? String(contentsOf: url, encoding: .utf8) {
                    let name = url.deletingPathExtension().lastPathComponent
                    Task { @MainActor in
                        var doc = ContextDocument(name: name, rawContent: content)
                        doc.sections = await ContextDocument.parseSections(from: content)
                        state.contextDocuments.append(doc)
                    }
                }
            }
        case .failure(let err):
            print("File import error: \(err)")
        }
    }
}

// MARK: - Context Document Card

struct ContextDocumentCard: View {
    @Binding var doc: ContextDocument
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 10) {
                // Active toggle
                Toggle("", isOn: $doc.isActive)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help(doc.isActive ? "Active — included in AI context" : "Inactive — excluded from AI context")

                Image(systemName: "doc.richtext")
                    .foregroundStyle(doc.isActive ? .purple : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(doc.isActive ? .white : .secondary)
                    Text("\(doc.sections.count) section(s) · \(doc.rawContent.count) chars")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Section badge
                if !doc.sections.isEmpty {
                    ForEach(doc.sections.prefix(3)) { section in
                        Text(section.heading)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.purple.opacity(0.15), in: Capsule())
                            .foregroundStyle(.purple.opacity(0.9))
                            .lineLimit(1)
                    }
                    if doc.sections.count > 3 {
                        Text("+\(doc.sections.count - 3)")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                } else {
                    Label("No headings — ignored", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 13))
                        .foregroundStyle(.purple.opacity(0.8))
                }
                .buttonStyle(.plain)

                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(12)

            // Expanded: show sections
            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if doc.sections.isEmpty {
                        Text("No headings found. Add ## Section Title headings to your document to activate context.")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                            .padding(12)
                    } else {
                        ForEach(doc.sections) { section in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("# \(section.heading)")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.purple)
                                Text(section.content)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .lineLimit(4)
                                    .truncationMode(.tail)
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(
            doc.isActive ? Color.purple.opacity(0.2) : Color.white.opacity(0.06),
            lineWidth: 1
        ))
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }
}

// MARK: - Document Editor Sheet

struct DocumentEditorSheet: View {
    let title: String
    @Binding var name: String
    @Binding var content: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var parsedSectionCount: Int { ContextDocument.parseSectionsSync(from: content).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))

            TextField("Document name (e.g. My Resume, Job Description)", text: $name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Content (Markdown supported)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if parsedSectionCount > 0 {
                        Label("\(parsedSectionCount) section(s) detected", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(.green)
                    } else if !content.isEmpty {
                        Label("No headings — add ## Section to activate", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
                TextEditor(text: $content)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))

                Text("Tip: Use ## Section Heading to create context sections. Headingless content is ignored by AI.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.escape)
                Button("Save Changes", action: onSave)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(name.isEmpty || content.isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 440)
    }
}

// MARK: - Privacy Settings

struct PrivacySettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Privacy Guarantees", subtitle: "How GhostMind protects your data")
            ForEach([
                (AnyView(Image(systemName: "lock.shield.fill")), Color.green, "All audio is processed on-device via Apple Neural Engine. Zero cloud upload."),
                (AnyView(Image(systemName: "key.fill")), Color.blue, "API keys are stored locally on this Mac. No sync, no remote storage."),
                (AnyView(Image(systemName: "eye.slash.fill")), Color.orange, "No telemetry, analytics, or tracking of any kind."),
                (AnyView(Image(systemName: "eye.trianglebadge.exclamationmark.fill")), Color.purple, "This window is excluded from all screen capture APIs (sharingType = .none).")
            ], id: \.2) { icon, color, text in
                HStack(alignment: .top, spacing: 12) {
                    icon
                        .foregroundStyle(color)
                        .frame(width: 22)
                    Text(text)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(LinearGradient(colors: [.purple, .indigo], startPoint: .top, endPoint: .bottom))
            VStack(spacing: 6) {
                Text("GhostMind").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Stealth AI Meeting & Interview Assistant")
                    .foregroundStyle(.secondary)
                Text("Version 1.0.0 · Apple Silicon (M-series)")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                FeatureRow(icon: "eye.slash.fill", text: "Invisible to Zoom, OBS, Teams, ProctorU, Hubstaff")
                FeatureRow(icon: "waveform", text: "On-device STT — Apple Neural Engine or Whisper.cpp")
                FeatureRow(icon: "brain", text: "8 AI providers with auto-fallback")
                FeatureRow(icon: "lock.shield.fill", text: "Keys stored locally · zero telemetry")
                FeatureRow(icon: "doc.richtext", text: "Markdown context docs with section-level injection")
            }
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
    }
}

struct FeatureRow: View {
    let icon: String; let text: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.purple).frame(width: 20)
            Text(text).font(.system(size: 13))
        }
    }
}

// MARK: - Reusable helpers

struct SectionHeader: View {
    let title: String
    var subtitle: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
            content
        }
    }
}
