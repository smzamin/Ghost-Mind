import Foundation
import AppKit

// MARK: - Full Markdown Renderer (NSRegularExpression-based)
// Replaces the stub in ViewModifiers.swift

extension String {

    /// Parse this string as Markdown and return an NSAttributedString
    /// suitable for display in a SwiftUI Text view (via AttributedString).
    func asMarkdownAttributed(baseSize: CGFloat = 13) -> AttributedString {
        let result = AttributedString(self)

        // Build a mutable attributed string via AppKit, then convert
        let ns = NSMutableAttributedString(string: self)

        let baseFont = NSFont.systemFont(ofSize: baseSize)
        let boldFont = NSFont.boldSystemFont(ofSize: baseSize)
        let italicFont = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic), size: baseSize) ?? baseFont
        let codeFont  = NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular)
        let h1Font    = NSFont.boldSystemFont(ofSize: baseSize + 4)
        let h2Font    = NSFont.boldSystemFont(ofSize: baseSize + 2)
        let h3Font    = NSFont.boldSystemFont(ofSize: baseSize + 1)

        let fullRange = NSRange(location: 0, length: ns.length)
        ns.addAttribute(.font, value: baseFont, range: fullRange)
        ns.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.88), range: fullRange)

        // ── Block-level processing (line by line) ───────────────────────────
        let lines = self.components(separatedBy: "\n")
        var offset = 0
        for line in lines {
            let lineRange = NSRange(location: offset, length: line.utf16.count)

            if line.hasPrefix("### ") {
                ns.addAttribute(.font, value: h3Font, range: lineRange)
            } else if line.hasPrefix("## ") {
                ns.addAttribute(.font, value: h2Font, range: lineRange)
            } else if line.hasPrefix("# ") {
                ns.addAttribute(.font, value: h1Font, range: lineRange)
            } else if line.hasPrefix("---") {
                // Horizontal rule: replace with em-dash line
                ns.addAttribute(.foregroundColor, value: NSColor.white.withAlphaComponent(0.15), range: lineRange)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                // Bullet point: prefix with •
            } else if line.hasPrefix("> ") {
                // Blockquote
                ns.addAttribute(.foregroundColor, value: NSColor.systemPurple.withAlphaComponent(0.85), range: lineRange)
            }

            offset += line.utf16.count + 1  // +1 for newline
        }

        // ── Inline processing ───────────────────────────────────────────────
        applyRegex(to: ns, pattern: #"\*\*(.+?)\*\*"#) { match, ns in
            ns.addAttribute(.font, value: boldFont, range: match.range(at: 0))
        }
        applyRegex(to: ns, pattern: #"\*(.+?)\*"#) { match, ns in
            ns.addAttribute(.font, value: italicFont, range: match.range(at: 0))
        }
        applyRegex(to: ns, pattern: #"`([^`]+)`"#) { match, ns in
            ns.addAttribute(.font, value: codeFont, range: match.range(at: 0))
            ns.addAttribute(.backgroundColor, value: NSColor.white.withAlphaComponent(0.08), range: match.range(at: 0))
        }

        // Convert NSAttributedString → AttributedString (Swift)
        if let converted = try? AttributedString(ns, including: \.appKit) {
            return converted
        }
        return result
    }

    // MARK: - Helper

    private func applyRegex(
        to ns: NSMutableAttributedString,
        pattern: String,
        apply: (NSTextCheckingResult, NSMutableAttributedString) -> Void
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return }
        let matches = regex.matches(in: ns.string, range: NSRange(location: 0, length: ns.length))
        // Apply in reverse so ranges stay valid
        for match in matches.reversed() {
            apply(match, ns)
        }
    }
}
