import Foundation

enum Constants {
    enum UserDefaults {
        static let selectedProvider = "selectedProvider"
        static let selectedModel = "selectedModel"
        static let interviewMode = "interviewMode"
        static let showTranscript = "showTranscript"
        static let opacity = "opacity"
        static let transcriptWidth = "transcriptWidth"
        
        static let sttSelectedProvider = "stt_selected_provider"
        static let sttSelectedModel = "stt_selected_model"
        static let sttLocalEndpoint = "stt_local_endpoint"
    }
    
    enum Notification {
        static let instantAssist = NSNotification.Name("GhostMind.instantAssist")
        static let toggleTranscript = NSNotification.Name("GhostMind.toggleTranscript")
        static let readScreen = NSNotification.Name("GhostMind.readScreen")
        static let collapseStateChanged = NSNotification.Name("GhostMind.collapseStateChanged")
        static let audioTranslationNeeded = NSNotification.Name("GhostMind.audioTranslationNeeded")
        static let newTranscriptSegment = NSNotification.Name("GhostMind.newTranscriptSegment")
        static let escapePressed = NSNotification.Name("GhostMind.escapePressed")
    }
}
