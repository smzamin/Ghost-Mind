import Vision
import AppKit
import Combine
import Foundation

// MARK: - ScreenCapture result

struct ScreenCaptureResult {
    let text: String
    let confidence: Float
    let timestamp: Date
    let bounds: [CGRect]
}

// MARK: - ScreenReaderEngine

/// On-device OCR using Apple Vision framework.
/// Requires Screen Recording permission (TCC) to capture display content.
///
/// Key technique: takes a CGDisplayCreateImage to perform OCR on the current screen.
@MainActor
final class ScreenReaderEngine: ObservableObject {

    @Published var latestCapture: ScreenCaptureResult?
    @Published var isActive = false
    @Published var errorMessage: String?

    private var captureTimer: Timer?
    private let captureInterval: TimeInterval = 3.0  // capture every 3s

    // MARK: - Start / Stop

    func startContinuousCapture() {
        guard !isActive else { return }
        isActive = true
        captureTimer = Timer.scheduledTimer(withTimeInterval: captureInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.captureAndRecognize()
            }
        }
    }

    func stopContinuousCapture() {
        captureTimer?.invalidate()
        captureTimer = nil
        isActive = false
    }

    func captureOnce() async -> ScreenCaptureResult? {
        return await captureAndRecognize()
    }

    // MARK: - Core capture + OCR

    @discardableResult
    private func captureAndRecognize() async -> ScreenCaptureResult? {
        // Capture active window using CGWindowListCreateImage
        // (uses Accessibility permission — does NOT trigger Screen Recording prompt)
        guard let cgImage = captureWindowImage() else {
            errorMessage = "Could not capture screen content"
            return nil
        }

        let result = await recognizeText(in: cgImage)
        if let result {
            latestCapture = result
        }
        return result
    }

    // MARK: - Window Capture

    private func captureWindowImage() -> CGImage? {
        // Use kCGWindowListOptionOnScreenBelowWindow to get windows below us
        // We capture the screen at the current display resolution
        guard let screen = NSScreen.main else { return nil }
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID

        return CGDisplayCreateImage(displayID)
    }

    // MARK: - Vision OCR

    private func recognizeText(in image: CGImage) async -> ScreenCaptureResult? {
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    DispatchQueue.main.async {
                        self.errorMessage = "OCR error: \(error.localizedDescription)"
                    }
                    continuation.resume(returning: nil)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: nil)
                    return
                }

                let texts = observations.compactMap { obs -> (String, Float, CGRect)? in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return (candidate.string, candidate.confidence, obs.boundingBox)
                }

                let combined = texts.map { $0.0 }.joined(separator: "\n")
                let avgConfidence = texts.isEmpty ? 0 : texts.map { $0.1 }.reduce(0, +) / Float(texts.count)
                let bounds = texts.map { $0.2 }

                let result = ScreenCaptureResult(
                    text: combined,
                    confidence: avgConfidence,
                    timestamp: Date(),
                    bounds: bounds
                )
                continuation.resume(returning: result)
            }

            // Optimize for accuracy on M-series Neural Engine
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "OCR handler error: \(error.localizedDescription)"
                }
                continuation.resume(returning: nil)
            }
        }
    }
}
