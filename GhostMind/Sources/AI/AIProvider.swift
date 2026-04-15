import Foundation

// MARK: - AI Provider

enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case openAI = "OpenAI"
    case gemini = "Google Gemini"
    case anthropic = "Anthropic Claude"
    case groq = "Groq"
    case openRouter = "OpenRouter"
    case nvidia = "NVIDIA NIM"
    case ollama = "Ollama (Local)"
    case custom = "Custom Endpoint"

    var id: String { rawValue }

    var baseURL: String {
        switch self {
        case .openAI:     return "https://api.openai.com/v1"
        case .gemini:     return "https://generativelanguage.googleapis.com/v1beta"
        case .anthropic:  return "https://api.anthropic.com/v1"
        case .groq:       return "https://api.groq.com/openai/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .nvidia:     return "https://integrate.api.nvidia.com/v1"
        case .ollama:     return "http://localhost:11434/api"
        case .custom:     return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI:     return "gpt-4o"
        case .gemini:     return "gemini-1.5-pro"
        case .anthropic:  return "claude-3-5-sonnet-20241022"
        case .groq:       return "llama-3.1-70b-versatile"
        case .openRouter: return "openai/gpt-4o"
        case .nvidia:     return "meta/llama-3.1-70b-instruct"
        case .ollama:     return "llama3.2"
        case .custom:     return "gpt-4o"
        }
    }

    var icon: String {
        switch self {
        case .openAI:     return "sparkles"
        case .gemini:     return "star.circle"
        case .anthropic:  return "brain"
        case .groq:       return "bolt.fill"
        case .openRouter: return "arrow.triangle.branch"
        case .nvidia:     return "cpu.fill"
        case .ollama:     return "house.fill"
        case .custom:     return "network"
        }
    }

    var shortName: String {
        switch self {
        case .openAI:     return "GPT"
        case .gemini:     return "Gemini"
        case .anthropic:  return "Claude"
        case .groq:       return "Groq"
        case .openRouter: return "OR"
        case .nvidia:     return "NVIDIA"
        case .ollama:     return "Ollama"
        case .custom:     return "Custom"
        }
    }
}

// MARK: - AI Action

enum AIAction: String, CaseIterable {
    case assist = "Assist"
    case whatToSay = "What should I say?"
    case followUp = "Follow-up questions"
    case recap = "Recap"

    var systemPrompt: String {
        switch self {
        case .assist:
            return """
            You are GhostMind, a real-time AI meeting and interview assistant. \
            Given the conversation context or selected text, provide a concise, high-quality answer. \
            Format your response using markdown with clear headers and bullet points. \
            Be direct and scannable.
            """
        case .whatToSay:
            return """
            You are a communication coach. Given the conversation or question, \
            craft a natural, professional spoken response the user can say aloud. \
            Keep it conversational, confident, and under 120 words unless the topic requires more. \
            Do NOT use markdown headers — write as natural speech.
            """
        case .followUp:
            return """
            You are an expert interviewer/meeting facilitator. \
            Given the current conversation context, predict the 3-5 most likely follow-up questions \
            the other party will ask, and provide a strong prepared answer for each. \
            Format: **Q:** [question]\n**A:** [answer]
            """
        case .recap:
            return """
            You are a meeting scribe. Summarize the conversation so far in concise bullet points. \
            Group by topic. Highlight key decisions, action items, and open questions. \
            Use markdown.
            """
        }
    }
}
