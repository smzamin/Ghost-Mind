@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import Combine
import Foundation
import os.log

// MARK: - Audio Segment

struct AudioSegment {
    enum Source { case microphone, systemAudio }
    let data: Data
    let source: Source
    let timestamp: Date
    let sampleRate: Double
    let channelCount: Int
}

// MARK: - AudioCaptureManager

/// Captures both microphone (user's voice) and system audio (remote speakers).
/// Audio buffers are kept in-memory only — never written to disk.
/// onMicBuffer fires DIRECTLY from the AVAudioEngine tap thread — NO Task hop —
/// so SFSpeechAudioBufferRecognitionRequest.append() gets gapless real-time buffers.

@MainActor
final class AudioCaptureManager: NSObject, ObservableObject {

    private static let log = Logger(subsystem: "GhostMind", category: "AudioCapture")

    // MARK: Published state
    @Published var isCapturing   = false
    @Published var micLevel:    Float = 0
    @Published var systemLevel: Float = 0
    @Published var errorMessage: String?
    @Published var captureStatus: CaptureStatus = .idle

    enum CaptureStatus: Equatable {
        case idle
        case starting
        case capturing
        case error(String)
    }

    // MARK: Audio engine
    private let audioEngine = AVAudioEngine()
    private var micNode: AVAudioInputNode { audioEngine.inputNode }
    private var micFormat: AVAudioFormat?

    // MARK: SCKit (system audio)
    private var scStream: SCStream?
    private var scStreamOutput: SCKAudioOutput?
    private var scVideoSink: SCKVideoSink?

    // MARK: Callbacks
    var onAudioSegment: ((AudioSegment) -> Void)?

    // ── CRITICAL: called DIRECTLY on the AVAudioEngine tap thread (no @MainActor hop) ──
    // SFSpeechAudioBufferRecognitionRequest.append() is thread-safe per Apple docs.
    // Wrapping in Task { @MainActor in } created timing gaps that broke STT.
    var onMicBuffer: ((AVAudioPCMBuffer) -> Void)?

    // MARK: Buffer accumulation state (Thread-safe)
    private let bufferQueue = DispatchQueue(label: "com.ghostmind.audio.buffers")
    
    // Internal state moved to a class to allow non-isolated access via synchronization
    private class AccumulatorState: @unchecked Sendable {
        var micBuffer = Data()
        var sysBuffer = Data()
        var micBufferStart = Date()
        var sysBufferStart = Date()
    }
    nonisolated private let accState = AccumulatorState()
    
    private var lastMicLevelUpdate = Date.distantPast
    private var lastSysLevelUpdate = Date.distantPast
    private let bufferDuration: TimeInterval = 0.5

    // MARK: Permission check
    static func hasMicrophonePermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func hasScreenRecordingPermission() -> Bool {
        // CGPreflightScreenCaptureAccess is the standard check for all supported macOS versions
        return CGPreflightScreenCaptureAccess()
    }

    // MARK: - Start / Stop

    func startCapture() async {
        guard !isCapturing else { return }
        captureStatus = .starting
        Self.log.info("Starting audio capture")

        // Ensure microphone permission
        if !Self.hasMicrophonePermission() {
            let granted = await Self.requestMicrophonePermission()
            if !granted {
                let msg = "Microphone access denied. Open System Settings → Privacy → Microphone."
                errorMessage = msg
                captureStatus = .error(msg)
                Self.log.error("Microphone permission denied")
                return
            }
        }

        do {
            try startMicCapture()
            Self.log.info("Mic capture started successfully")

            // System audio is best-effort — don't fail session if denied
            if !Self.hasScreenRecordingPermission() {
                 Self.log.warning("Screen Recording permission not granted. System audio will be unavailable.")
                 // Trigger prompt if possible by calling SCKit
                 _ = try? await SCShareableContent.current
            }

            do {
                try await startSystemAudioCapture()
                Self.log.info("System audio capture started")
            } catch {
                let msg = error.localizedDescription
                Self.log.warning("System audio unavailable: \(msg)")
                if msg.contains("denied") || msg.contains("TCC") {
                    errorMessage = "System audio requires Screen Recording permission. Please enable it in System Settings."
                }
            }

            isCapturing = true
            captureStatus = .capturing
        } catch {
            let msg = "Mic capture failed: \(error.localizedDescription)"
            errorMessage = msg
            captureStatus = .error(msg)
            Self.log.error("startCapture failed: \(error.localizedDescription)")
        }
    }

    func stopCapture() {
        Self.log.info("Stopping audio capture")
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        Task { try? await scStream?.stopCapture() }
        scStream = nil
        scStreamOutput = nil
        scVideoSink = nil
        isCapturing = false
        captureStatus = .idle
        micLevel = 0
        systemLevel = 0
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicCapture() throws {
        // Always remove existing tap first to avoid "already installed" crash
        audioEngine.inputNode.removeTap(onBus: 0)

        let inputNode = audioEngine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        micFormat = format

        // Validate format — prevent crash on virtual devices with 0-channel formats
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AudioError.invalidFormat("Input format has \(format.channelCount) channels @ \(format.sampleRate)Hz")
        }

        Self.log.info("Installing mic tap: \(format.channelCount)ch @ \(format.sampleRate)Hz")

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }

            // ── Level meter (throttled to 20Hz) ──
            let now = Date()
            if now.timeIntervalSince(self.lastMicLevelUpdate) > 0.05 {
                let lvl = self.rmsLevel(buffer: buffer)
                DispatchQueue.main.async {
                    self.micLevel = lvl
                    self.lastMicLevelUpdate = now
                }
            }

            // ── DIRECT callback to STT — NO Task hop ──
            self.onMicBuffer?(buffer)

            // ── Whisper/segment accumulation (Off-main-thread) ──
            if let data = self.pcmToData(buffer) {
                self.bufferQueue.async {
                    self.accumulateMic(data: data)
                }
            }
        }

        // Prepare before start to catch format/device errors early
        audioEngine.prepare()
        try audioEngine.start()
    }

    // MARK: - System Audio (ScreenCaptureKit)

    private func startSystemAudioCapture() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw AudioError.noDisplay
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 44100
        config.channelCount = 2
        config.excludesCurrentProcessAudio = false
        config.width  = 2
        config.height = 2

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let output = SCKAudioOutput { [weak self] data in
            guard let self else { return }
            
            // Level meter throttled
            let now = Date()
            if now.timeIntervalSince(self.lastSysLevelUpdate) > 0.1 {
                let lvl = Float(data.count) / 131072.0 // heuristic
                DispatchQueue.main.async {
                    self.systemLevel = min(lvl, 1.0)
                    self.lastSysLevelUpdate = now
                }
            }
            
            self.bufferQueue.async {
                self.accumulateSys(data: data)
            }
        }

        scStreamOutput = output
        scVideoSink = SCKVideoSink()
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        // Avoid noisy logs about dropped video frames by attaching a no-op video output.
        if let scVideoSink {
            try stream.addStreamOutput(scVideoSink, type: .screen, sampleHandlerQueue: .global(qos: .utility))
        }
        try await stream.startCapture()
        scStream = stream
    }

    // MARK: - Buffer Accumulation (Thread-safe on bufferQueue)

    nonisolated private func accumulateMic(data: Data) {
        bufferQueue.async {
            let now = Date()
            var segmentToEmit: AudioSegment?
            
            // Local sync block for the shared state
            objc_sync_enter(self.accState)
            self.accState.micBuffer.append(data)
            if now.timeIntervalSince(self.accState.micBufferStart) >= self.bufferDuration {
                segmentToEmit = AudioSegment(
                    data: self.accState.micBuffer,
                    source: .microphone,
                    timestamp: self.accState.micBufferStart,
                    sampleRate: 48000, // standard for most Mac mics
                    channelCount: 1
                )
                self.accState.micBuffer = Data()
                self.accState.micBufferStart = now
            }
            objc_sync_exit(self.accState)
            
            if let segment = segmentToEmit {
                DispatchQueue.main.async {
                    // Back to main actor for the final callback
                    MainActor.assumeIsolated {
                        self.onAudioSegment?(segment)
                    }
                }
            }
        }
    }

    nonisolated private func accumulateSys(data: Data) {
        bufferQueue.async {
            let now = Date()
            var segmentToEmit: AudioSegment?
            
            objc_sync_enter(self.accState)
            self.accState.sysBuffer.append(data)
            if now.timeIntervalSince(self.accState.sysBufferStart) >= self.bufferDuration {
                segmentToEmit = AudioSegment(
                    data: self.accState.sysBuffer,
                    source: .systemAudio,
                    timestamp: self.accState.sysBufferStart,
                    sampleRate: 44100,
                    channelCount: 2
                )
                self.accState.sysBuffer = Data()
                self.accState.sysBufferStart = now
            }
            objc_sync_exit(self.accState)
            
            if let segment = segmentToEmit {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.onAudioSegment?(segment)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func rmsLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        let ptr = channelData[0]
        var sum: Float = 0
        for i in 0..<count { sum += ptr[i] * ptr[i] }
        return min(sqrt(sum / Float(count)) * 12, 1.0)
    }

    private func pcmToData(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return nil }
        // Convert Float32 PCM (-1..1) to signed 16-bit little-endian PCM (LINEAR16)
        var out = Data(count: count * 2)
        out.withUnsafeMutableBytes { ptr in
            guard let i16 = ptr.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<count {
                let clamped = max(-1.0, min(1.0, channelData[0][i]))
                i16[i] = Int16(clamped * Float(Int16.max))
            }
        }
        return out
    }
}

// MARK: - Audio Errors

enum AudioError: LocalizedError {
    case invalidFormat(String)
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let s): return "Invalid audio format: \(s)"
        case .noDisplay:            return "No display available for system audio capture."
        }
    }
}

// MARK: - SCKit Helpers

extension AudioCaptureManager: @preconcurrency SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Self.log.error("SCStream stopped with error: \(error.localizedDescription)")
        DispatchQueue.main.async {
            self.errorMessage = "System audio stopped: \(error.localizedDescription)"
        }
    }
}

final class SCKAudioOutput: NSObject, SCStreamOutput {
    private let handler: (Data) -> Void
    init(handler: @escaping (Data) -> Void) { self.handler = handler }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        // Use a pre-allocated buffer if possible, but for now simple copy
        let len = CMBlockBufferGetDataLength(dataBuffer)
        var data = Data(count: len)
        data.withUnsafeMutableBytes { ptr in
            _ = CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: len, destination: ptr.baseAddress!)
        }
        handler(data)
    }
}

final class SCKVideoSink: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // no-op, just to keep the stream happy
    }
}
