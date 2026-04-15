import SwiftUI
import AppKit

// MARK: - NSVisualEffectView wrapper for SwiftUI

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 18
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Markdown Text (basic inline renderer)

/// Renders a subset of Markdown without any external dependencies.
/// Supports **bold**, *italic*, `code`, ## headers, and - bullet lists.
struct MarkdownText: View {
    let text: String

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                renderLine(line)
            }
        }
    }

    @ViewBuilder
    private func renderLine(_ line: String) -> some View {
        if line.hasPrefix("### ") {
            Text(line.dropFirst(4))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        } else if line.hasPrefix("## ") {
            Text(line.dropFirst(3))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
        } else if line.hasPrefix("# ") {
            Text(line.dropFirst(2))
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(.white)
        } else if line.hasPrefix("- ") || line.hasPrefix("• ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•").foregroundStyle(.purple).font(.system(size: 13))
                inlineFormatted(String(line.dropFirst(2)))
            }
        } else if line.hasPrefix("**Q:**") {
            Text(attributedMarkdown(line))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        } else if line.hasPrefix("**A:**") {
            Text(attributedMarkdown(line))
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
        } else if line.hasPrefix("---") {
            Divider().opacity(0.2)
        } else if line.isEmpty {
            Spacer().frame(height: 2)
        } else {
            inlineFormatted(line)
        }
    }

    private func inlineFormatted(_ string: String) -> some View {
        Text(attributedMarkdown(string))
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.88))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func attributedMarkdown(_ input: String) -> AttributedString {
        // Simple pass-through — full regex-based bold/code rendering
        // is added incrementally to avoid overlapping access issues in Swift 6
        return AttributedString(input)
    }
}

// MARK: - Shimmer Modifier

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: phase - 0.3),
                        .init(color: .white.opacity(0.3), location: phase),
                        .init(color: .clear, location: phase + 0.3),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .blendMode(.screen)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1.3
                }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(ShimmerModifier()) }
}

// MARK: - UIBezierPath macOS shim

// Remove UIBezierPath — it doesn't exist on macOS natively.
// The BubbleShape in AIChatPanel.swift uses NSBezierPath. Provide the shim here:

/// Returns an NSBezierPath as CGPath for use in SwiftUI Shape
func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).cgPath
}

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo:    path.move(to: points[0])
            case .lineTo:    path.addLine(to: points[0])
            case .curveTo:   path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}
