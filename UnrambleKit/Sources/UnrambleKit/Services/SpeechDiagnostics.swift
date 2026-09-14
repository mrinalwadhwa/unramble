import Foundation

/// Describe text boundaries for debug logs without recording selected words.
enum SpeechDiagnostics {
    static func textStructure(_ text: String) -> String {
        var lf = 0
        var cr = 0
        var lineSeparators = 0
        var paragraphSeparators = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A: lf += 1
            case 0x0D: cr += 1
            case 0x2028: lineSeparators += 1
            case 0x2029: paragraphSeparators += 1
            default: break
            }
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let blankLines = lines.dropFirst().dropLast().filter {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        }.count
        return "chars=\(text.count) lf=\(lf) cr=\(cr) "
            + "unicodeLS=\(lineSeparators) unicodePS=\(paragraphSeparators) "
            + "blankLines=\(blankLines)"
    }
}
