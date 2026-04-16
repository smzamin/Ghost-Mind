import XCTest
@testable import GhostMind

final class AIClientTests: XCTestCase {
    
    func testOpenAIResponseDecoding() throws {
        let json = """
        {
          "choices": [
            {
              "message": {
                "content": "Hello world"
              }
            }
          ]
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let response = try decoder.decode(AIClient.OpenAIResponse.self, from: json)
        XCTAssertEqual(response.choices.first?.message.content, "Hello world")
    }
    
    func testAnthropicResponseDecoding() throws {
        let json = """
        {
          "content": [
            {
              "text": "Hello Anthropic"
            }
          ]
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let response = try decoder.decode(AIClient.AnthropicResponse.self, from: json)
        XCTAssertEqual(response.content.first?.text, "Hello Anthropic")
    }
    
    func testGeminiResponseDecoding() throws {
        let json = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  { "text": "Hello Gemini" }
                ]
              }
            }
          ]
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let response = try decoder.decode(AIClient.GeminiResponse.self, from: json)
        XCTAssertEqual(response.candidates.first?.content.parts.first?.text, "Hello Gemini")
    }
}
