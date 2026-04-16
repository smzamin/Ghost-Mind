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
        static let instantAssist = NSNotification.Name("instantAssist")
        static let toggleTranscript = NSNotification.Name("toggleTranscript")
        static let readScreen = NSNotification.Name("readScreen")
        static let collapseStateChanged = NSNotification.Name("collapseStateChanged")
        static let audioTranslationNeeded = NSNotification.Name("audioTranslationNeeded")
        static let newTranscriptSegment = NSNotification.Name("newTranscriptSegment")
    }
}
