import Foundation

struct SubtitleCue: Identifiable, Equatable {
    let id = UUID()
    let start: Double
    let end: Double
    let text: String
}

enum SRTParser {
    static func parse(_ raw: String) -> [SubtitleCue] {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard lines.count >= 2 else { return nil }
            let timeIndex = lines.firstIndex(where: { $0.contains("-->") })
            guard let timeIndex else { return nil }
            let parts = lines[timeIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = timestamp(parts[0]),
                  let end = timestamp(parts[1]), end >= start else { return nil }
            let text = lines.dropFirst(timeIndex + 1).joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return SubtitleCue(start: start, end: end, text: text)
        }.sorted { $0.start < $1.start }
    }

    private static func timestamp(_ value: String) -> Double? {
        let clean = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: ",")
        let pieces = clean.split(separator: ":")
        guard pieces.count == 3,
              let h = Double(pieces[0]),
              let m = Double(pieces[1]) else { return nil }
        let secParts = pieces[2].split(separator: ",")
        guard let s = Double(secParts[0]) else { return nil }
        let ms = secParts.count > 1 ? Double(String(secParts[1]).prefix(3)) ?? 0 : 0
        return h * 3600 + m * 60 + s + ms / 1000
    }
}
