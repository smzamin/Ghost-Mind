import XCTest
@testable import GhostMind

// MARK: - AI Provider Tests

final class AIProviderTests: XCTestCase {

    func testAllProvidersHaveBaseURL() {
        for provider in AIProvider.allCases {
            if provider != .custom && provider != .ollama {
                XCTAssertFalse(provider.baseURL.isEmpty, "\(provider.rawValue) has no base URL")
                XCTAssertTrue(provider.baseURL.hasPrefix("https://"), "\(provider.rawValue) URL should use HTTPS")
            }
        }
    }

    func testAllProvidersHaveDefaultModel() {
        for provider in AIProvider.allCases {
            XCTAssertFalse(provider.defaultModel.isEmpty, "\(provider.rawValue) has no default model")
        }
    }

    func testAllActionsHaveSystemPrompts() {
        for action in AIAction.allCases {
            XCTAssertFalse(action.systemPrompt.isEmpty, "\(action.rawValue) has no system prompt")
        }
    }
}

// MARK: - Keychain Tests

final class KeychainTests: XCTestCase {

    func testSaveAndLoad() {
        let key = "test_key_\(UUID().uuidString)"
        let value = "sk-test-\(UUID().uuidString)"

        KeychainManager.save(key: key, value: value)
        let loaded = KeychainManager.load(key: key)
        XCTAssertEqual(loaded, value)

        // Cleanup
        KeychainManager.delete(key: key)
        XCTAssertNil(KeychainManager.load(key: key))
    }

    func testOverwriteExistingKey() {
        let key = "test_overwrite_\(UUID().uuidString)"
        KeychainManager.save(key: key, value: "old_value")
        KeychainManager.save(key: key, value: "new_value")
        XCTAssertEqual(KeychainManager.load(key: key), "new_value")
        KeychainManager.delete(key: key)
    }
}

// MARK: - Session Tests

final class SessionManagerTests: XCTestCase {

    @MainActor
    func testSessionStartAndEnd() {
        let manager = SessionManager()
        manager.startSession(title: "Test Session")

        XCTAssertNotNil(manager.currentSession)
        XCTAssertEqual(manager.currentSession?.title, "Test Session")
        XCTAssertTrue(manager.isRecording)

        let segment = TranscriptSegment(
            id: UUID(), speaker: .interviewer, text: "Tell me about yourself.",
            timestamp: Date(), isFinal: true
        )
        manager.addTranscriptSegment(segment)
        XCTAssertEqual(manager.currentSession?.transcript.count, 1)

        manager.endSession()
        XCTAssertFalse(manager.isRecording)
        XCTAssertNotNil(manager.currentSession?.endedAt)
    }

    @MainActor
    func testMarkdownExport() {
        let manager = SessionManager()
        manager.startSession(title: "Export Test")
        let segment = TranscriptSegment(
            id: UUID(), speaker: .you, text: "Hello world",
            timestamp: Date(), isFinal: true
        )
        manager.addTranscriptSegment(segment)
        manager.endSession()

        let session = manager.savedSessions.first!
        let md = manager.exportMarkdown(session: session)

        XCTAssertTrue(md.contains("# Export Test"))
        XCTAssertTrue(md.contains("Hello world"))
        XCTAssertTrue(md.contains("[You]"))
    }
}

// MARK: - AI Client Tests

final class AIClientTests: XCTestCase {

    @MainActor
    func testDefaultProviderIsOpenAI() {
        let client = AIClient()
        XCTAssertEqual(client.selectedProvider, .openAI)
    }

    @MainActor
    func testAPIKeyStorageRoundtrip() {
        let client = AIClient()
        let testKey = "sk-test-\(UUID().uuidString)"

        client.setAPIKey(testKey, for: .openAI)
        XCTAssertEqual(client.apiKey(for: .openAI), testKey)

        // Cleanup
        KeychainManager.delete(key: AIProvider.openAI.rawValue)
    }

    @MainActor
    func testActionSystemPromptsAreDifferent() {
        let prompts = AIAction.allCases.map { $0.systemPrompt }
        let uniquePrompts = Set(prompts)
        XCTAssertEqual(prompts.count, uniquePrompts.count, "All actions must have unique system prompts")
    }
}
