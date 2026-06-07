import Foundation

enum JSONVariantParserError: LocalizedError {
    case noJSONObject
    case noVariants

    var errorDescription: String? {
        switch self {
        case .noJSONObject:
            return "The model didn't return readable JSON."
        case .noVariants:
            return "The model's response had no usable platform variants."
        }
    }
}

/// Tolerant parser for the model's JSON output. The model is asked for clean
/// JSON, but small models drift — this strips fences / thinking blocks, finds
/// the first balanced object, and accepts a few key spellings.
enum JSONVariantParser {

    static func parse(_ raw: String) throws -> GenerationResult {
        guard let jsonString = extractJSONObject(from: raw),
              let root = deserializeTolerant(jsonString)
        else {
            throw JSONVariantParserError.noJSONObject
        }
        return try parse(object: root)
    }

    /// Deserializes a JSON object string, repairing the JSON-breaking glitches
    /// small models occasionally emit before giving up. Returns the parsed value
    /// (object or array) or nil.
    static func deserializeTolerant(_ jsonString: String) -> Any? {
        if let data = jsonString.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) {
            return root
        }
        let repaired = repairDrift(jsonString)
        if let data = repaired.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) {
            return root
        }
        return nil
    }

    /// Fixes the glitches that break otherwise-good model JSON: a property name
    /// that dropped its opening quote (`  foo": …` → `  "foo": …`, a token the
    /// model sometimes mis-samples), unquoted bare-word array elements (the
    /// hashtag case), and trailing commas before `}`/`]`.
    static func repairDrift(_ json: String) -> String {
        var s = json
        // Key missing its opening quote (after `{`, `,` or a newline).
        s = regexReplace(s, #"([\n\r{,]\s*)([A-Za-z_][A-Za-z0-9_]*)("\s*:)"#, with: "$1\"$2$3")
        // Unquoted bare words inside arrays, e.g. `[trabajo, productividad]`.
        s = quoteBareArrayWords(s)
        // Trailing comma before a closing brace/bracket.
        s = regexReplace(s, #",(\s*[}\]])"#, with: "$1")
        return s
    }

    /// Wraps unquoted bare-word elements inside JSON arrays in quotes, e.g.
    /// `[trabajo, productividad]` → `["trabajo", "productividad"]`. Models do this
    /// for hashtag arrays because the prompt asks for bare words (no `#`), which
    /// makes the whole object invalid JSON and fails the parse.
    ///
    /// String-aware (never touches text inside quotes, so prose like
    /// `"uno, dos, tres"` is safe) and array-aware (only quotes elements whose
    /// enclosing container is `[`, leaving numbers, objects, nested arrays and
    /// the JSON literals true/false/null untouched).
    static func quoteBareArrayWords(_ json: String) -> String {
        let literals: Set<String> = ["true", "false", "null"]
        let chars = Array(json)
        var out = String()
        out.reserveCapacity(chars.count + 16)
        var stack: [Character] = []            // nesting of { and [
        var inString = false
        var escaped = false
        var lastSignificant: Character?        // last non-whitespace char emitted outside a string

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inString = true; out.append(c); lastSignificant = c; i += 1
            case "{", "[":
                stack.append(c); out.append(c); lastSignificant = c; i += 1
            case "}", "]":
                if !stack.isEmpty { stack.removeLast() }
                out.append(c); lastSignificant = c; i += 1
            case " ", "\t", "\n", "\r":
                out.append(c); i += 1          // whitespace doesn't change element boundary
            default:
                let inArray = stack.last == "["
                let atElementStart = lastSignificant == "[" || lastSignificant == ","
                if inArray, atElementStart, c.isLetter {
                    var token = ""
                    while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                        token.append(chars[i]); i += 1
                    }
                    if literals.contains(token.lowercased()) {
                        out.append(token)            // a real boolean/null — leave it typed
                    } else {
                        out.append("\""); out.append(token); out.append("\"")
                    }
                    lastSignificant = "\""
                } else {
                    out.append(c); lastSignificant = c; i += 1
                }
            }
        }
        return out
    }

    private static func regexReplace(_ s: String, _ pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// Same as `parse(_:)` but for an already-deserialized JSON value — lets the
    /// Director's combined output reuse this when captions arrive inline per clip.
    static func parse(object root: Any) throws -> GenerationResult {
        var rawVariants: [[String: Any]] = []
        var language: String?

        if let object = root as? [String: Any] {
            language = object["language"] as? String
            if let array = object["variants"] as? [[String: Any]] {
                rawVariants = array
            } else {
                // Object keyed directly by platform name (e.g. the Director's
                // inline `captions` block). Inject the platform key into each
                // entry so `makeVariant` — which requires a "platform" field —
                // can build them.
                rawVariants = SocialPlatform.allCases.compactMap { platform in
                    guard var dict = object[platform.rawValue] as? [String: Any] else { return nil }
                    dict["platform"] = platform.rawValue
                    return dict
                }
            }
        } else if let array = root as? [[String: Any]] {
            rawVariants = array
        }

        var byPlatform: [SocialPlatform: PostVariant] = [:]
        for entry in rawVariants {
            if let variant = makeVariant(from: entry) {
                byPlatform[variant.platform] = variant
            }
        }

        let ordered = SocialPlatform.allCases.compactMap { byPlatform[$0] }
        guard !ordered.isEmpty else { throw JSONVariantParserError.noVariants }
        return GenerationResult(variants: ordered, detectedLanguage: language)
    }

    /// Returns the first balanced `{ ... }` block, ignoring everything else
    /// (markdown fences, thinking text, trailing commentary).
    static func extractJSONObject(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < raw.endIndex {
            let char = raw[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                switch char {
                case "\"": inString = true
                case "{":  depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return String(raw[start...index]) }
                default: break
                }
            }
            index = raw.index(after: index)
        }
        return nil
    }

    private static func makeVariant(from entry: [String: Any]) -> PostVariant? {
        guard let platformRaw = (entry["platform"] as? String)?.lowercased(),
              let platform = SocialPlatform(rawValue: platformRaw)
        else { return nil }

        let hook = string(entry, "hook", "title", "headline")
        let summary = string(entry, "description", "caption", "summary", "body")
        let hashtags = normalizeHashtags(entry["hashtags"] ?? entry["tags"])
        return PostVariant(platform: platform, hook: hook, summary: summary, hashtags: hashtags)
    }

    /// First non-empty string value among the given keys.
    private static func string(_ entry: [String: Any], _ keys: String...) -> String {
        for key in keys {
            if let value = (entry[key] as? String)?.trimmed, !value.isEmpty {
                return value
            }
        }
        return ""
    }

    private static func normalizeHashtags(_ value: Any?) -> [String] {
        let rawList: [String]
        if let array = value as? [String] {
            rawList = array
        } else if let array = value as? [Any] {
            rawList = array.compactMap { $0 as? String }
        } else if let joined = value as? String {
            rawList = joined.split(whereSeparator: { " ,\n".contains($0) }).map(String.init)
        } else {
            rawList = []
        }
        let cleaned = rawList
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
            .filter { !$0.isEmpty }

        // Small models sometimes repeat the same tag many times — keep the first
        // occurrence of each (case-insensitively) and drop the rest.
        var seen = Set<String>()
        return cleaned.filter { seen.insert($0.lowercased()).inserted }
    }
}
