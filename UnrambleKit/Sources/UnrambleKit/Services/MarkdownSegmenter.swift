import Foundation

/// Splits markdown-ish agent text into readable segments.
///
/// Recognizes fenced code blocks, headings, list items, and block quotes;
/// everything else becomes prose. The goal is segmentation for speech
/// shaping, not markdown fidelity: unknown constructs degrade to prose
/// instead of failing.
public enum MarkdownSegmenter {

    public static func segments(from markdown: String) -> [ReadableContent.Segment] {
        var segments: [ReadableContent.Segment] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
        var insideFence = false

        func flushProse() {
            let text = proseLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            proseLines = []
            if !text.isEmpty {
                segments.append(.init(kind: .prose, text: text))
            }
        }

        func flushCode() {
            let text = codeLines.joined(separator: "\n")
            codeLines = []
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.init(kind: .code, text: text))
            }
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if insideFence {
                    flushCode()
                } else {
                    flushProse()
                }
                insideFence.toggle()
                continue
            }

            if insideFence {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                // Keep blank lines as paragraph boundaries instead of
                // folding adjacent prose paragraphs into one segment.
                flushProse()
                continue
            }

            if let heading = headingText(of: trimmed) {
                flushProse()
                segments.append(.init(kind: .heading, text: heading))
            } else if let item = listItemText(of: trimmed) {
                flushProse()
                segments.append(.init(kind: .listItem, text: item))
            } else if trimmed.hasPrefix(">") {
                flushProse()
                let text = String(trimmed.dropFirst())
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    segments.append(.init(kind: .quote, text: text))
                }
            } else {
                proseLines.append(line)
            }
        }

        // An unterminated fence still yields its collected code.
        if insideFence {
            flushCode()
        } else {
            flushProse()
        }
        return segments
    }

    private static func headingText(of line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let marker = line.prefix(while: { $0 == "#" })
        guard marker.count <= 6 else { return nil }
        let rest = line.dropFirst(marker.count)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func listItemText(of line: String) -> String? {
        for bullet in ["- ", "* ", "+ "] {
            if line.hasPrefix(bullet) {
                let text = line.dropFirst(bullet.count)
                    .trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : text
            }
        }
        var digits = 0
        for character in line {
            if character.isNumber {
                digits += 1
            } else if digits > 0, character == "." || character == ")" {
                let text = line.dropFirst(digits + 1)
                guard text.first == " " else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            } else {
                return nil
            }
        }
        return nil
    }
}
