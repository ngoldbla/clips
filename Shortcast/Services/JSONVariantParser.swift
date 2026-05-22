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
              let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
        else {
            throw JSONVariantParserError.noJSONObject
        }

        var rawVariants: [[String: Any]] = []
        var language: String?

        if let object = root as? [String: Any] {
            language = object["language"] as? String
            if let array = object["variants"] as? [[String: Any]] {
                rawVariants = array
            } else {
                // Object keyed directly by platform name.
                rawVariants = SocialPlatform.allCases.compactMap {
                    object[$0.rawValue] as? [String: Any]
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
        return rawList
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
            .filter { !$0.isEmpty }
    }
}
