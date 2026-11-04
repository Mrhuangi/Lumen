import Foundation

// MARK: - 字幕条目

struct SubtitleCue: Equatable, Codable {
    var start: Double   // 秒
    var end: Double     // 秒
    var text: String
}

// MARK: - 字幕解析与文本清洗（外挂字幕文件 + MKV 内封文本清洗共用）

enum SubtitleParser {

    /// 解析字幕文件内容（按扩展名/内容自动识别 SRT / ASS / SSA / WebVTT）
    static func parse(data: Data, fileExtension ext: String) -> [SubtitleCue] {
        guard let text = decodeText(data) else { return [] }
        let lower = ext.lowercased()
        if lower == "ass" || lower == "ssa" || text.contains("[Events]") {
            return parseASS(text)
        }
        if lower == "vtt" || text.hasPrefix("WEBVTT") {
            return parseVTT(text)
        }
        return parseSRT(text)
    }

    /// 兼容 UTF-8 / GB18030（国内字幕组的老 SRT 常是 GBK 编码）
    static func decodeText(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(
            CFStringConvertIANACharSetNameToEncoding("GB18030" as CFString))
        return String(data: data, encoding: String.Encoding(rawValue: gb18030))
    }

    // MARK: SRT

    static func parseSRT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            guard let arrowIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = parseTimeRange(lines[arrowIndex])
            guard let (start, end) = times else { continue }
            let body = lines[(arrowIndex + 1)...].joined(separator: "\n")
            let cleaned = stripTags(body).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                cues.append(SubtitleCue(start: start, end: end, text: cleaned))
            }
        }
        return cues.sorted { $0.start < $1.start }
    }

    // MARK: WebVTT

    static func parseVTT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for block in normalized.components(separatedBy: "\n\n") {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("WEBVTT")
                || trimmed.hasPrefix("NOTE") || trimmed.hasPrefix("STYLE")
                || trimmed.hasPrefix("REGION") { continue }
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let arrowIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            guard let (start, end) = parseTimeRange(lines[arrowIndex]) else { continue }
            let body = lines[(arrowIndex + 1)...].joined(separator: "\n")
            let cleaned = stripTags(body).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                cues.append(SubtitleCue(start: start, end: end, text: cleaned))
            }
        }
        return cues.sorted { $0.start < $1.start }
    }

    // MARK: ASS / SSA

    static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var formatFields: [String] = []
        var inEvents = false
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("[") {
                inEvents = line.lowercased().hasPrefix("[events]")
                continue
            }
            guard inEvents else { continue }
            if line.hasPrefix("Format:") {
                formatFields = line.dropFirst("Format:".count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard line.hasPrefix("Dialogue:") else { continue }
            let fields = formatFields.isEmpty
                ? ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
                : formatFields
            let parts = splitDialogue(line.dropFirst("Dialogue:".count).trimmingCharacters(in: .whitespaces),
                                      fieldCount: fields.count)
            guard parts.count == fields.count,
                  let si = fields.firstIndex(of: "start"),
                  let ei = fields.firstIndex(of: "end"),
                  let ti = fields.firstIndex(of: "text"),
                  let start = parseASSTime(parts[si]),
                  let end = parseASSTime(parts[ei]) else { continue }
            let cleaned = cleanASSText(parts[ti])
            if !cleaned.isEmpty {
                cues.append(SubtitleCue(start: start, end: end, text: cleaned))
            }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// Dialogue 行按字段数切分：最后一个字段（Text）保留其中所有逗号
    private static func splitDialogue(_ body: String, fieldCount: Int) -> [String] {
        var parts: [String] = []
        var rest = body
        for _ in 0..<(fieldCount - 1) {
            guard let comma = rest.firstIndex(of: ",") else { return parts }
            parts.append(String(rest[..<comma]))
            rest = String(rest[rest.index(after: comma)...])
        }
        parts.append(rest)
        return parts
    }

    // MARK: 时间

    /// "00:00:01,000 --> 00:00:03,500 ..."（SRT 逗号 / VTT 点号，可带 cue 设置）
    private static func parseTimeRange(_ line: String) -> (Double, Double)? {
        let sides = line.components(separatedBy: "-->")
        guard sides.count == 2,
              let start = parseClock(sides[0].trimmingCharacters(in: .whitespaces)),
              let endToken = sides[1].trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first,
              let end = parseClock(String(endToken)) else { return nil }
        return (start, end)
    }

    private static func parseClock(_ token: String) -> Double? {
        let t = token.replacingOccurrences(of: ",", with: ".")
        let parts = t.split(separator: ":").map(String.init)
        if parts.count == 3,
           let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) {
            return h * 3600 + m * 60 + s
        }
        if parts.count == 2,
           let m = Double(parts[0]), let s = Double(parts[1]) {
            return m * 60 + s
        }
        return nil
    }

    /// ASS 时间 "0:00:01.23"（百分之一秒）
    private static func parseASSTime(_ token: String) -> Double? {
        parseClock(token.trimmingCharacters(in: .whitespaces))
    }

    // MARK: 文本清洗

    /// 去掉 SRT/VTT 的尖括号标签（<i>、<font ...>、<00:00:01.000> 等）
    static func stripTags(_ text: String) -> String {
        var out = ""
        var inTag = false
        for ch in text {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        return out.replacingOccurrences(of: "&nbsp;", with: " ")
    }

    /// ASS 文本清洗：去掉 {...} 特效块，\N 换行，\h 空格
    static func cleanASSText(_ text: String) -> String {
        var out = ""
        var inBlock = false
        for ch in text {
            if ch == "{" { inBlock = true; continue }
            if ch == "}" { inBlock = false; continue }
            if !inBlock { out.append(ch) }
        }
        out = out.replacingOccurrences(of: "\\N", with: "\n")
        out = out.replacingOccurrences(of: "\\n", with: "\n")
        out = out.replacingOccurrences(of: "\\h", with: " ")
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// MKV 里 S_TEXT/ASS 的块：开头是 ReadOrder 等 8 个字段，真正的文本在第 8 个逗号之后
    static func textFromMKVASSBlock(_ raw: String) -> String {
        var rest = raw
        for _ in 0..<8 {
            guard let comma = rest.firstIndex(of: ",") else { return cleanASSText(raw) }
            rest = String(rest[rest.index(after: comma)...])
        }
        return cleanASSText(rest)
    }

    /// MKV 里 S_TEXT/WEBVTT 的块带自己的时间行，只取正文
    static func textFromMKVWebVTTBlock(_ raw: String) -> String {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let arrow = lines.firstIndex(where: { $0.contains("-->") }) else {
            return stripTags(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return stripTags(lines[(arrow + 1)...].joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
