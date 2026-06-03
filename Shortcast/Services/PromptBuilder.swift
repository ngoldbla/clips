import Foundation

/// Assembles the full prompt handed to Gemma 4 alongside the video frames and
/// audio: the bundled `social-content-coach` skill, the creator's style, the
/// language instruction, and a strict JSON output contract.
enum PromptBuilder {

    /// Loads the bundled `social-content-coach.md`. Falls back to a terse
    /// built-in brief if the resource is somehow missing.
    static func coachDocument() -> String {
        guard let url = Bundle.main.url(forResource: "social-content-coach", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return fallbackCoach }
        return text
    }

    static func buildPrompt(languageOverride: String, styleExamples: String) -> String {
        buildPrompt(
            coach: coachDocument(),
            languageOverride: languageOverride,
            styleExamples: styleExamples)
    }

    /// Same as `buildPrompt(languageOverride:styleExamples:)` but with the coach
    /// document supplied directly — used by tests / the probe tool.
    static func buildPrompt(coach: String, languageOverride: String, styleExamples: String) -> String {
        assemble(coach: coach, languageOverride: languageOverride,
                 styleExamples: styleExamples, task: taskAndSchema)
    }

    /// Captioning prompt for the text-only Copywriter (Qwen). Same coach, style
    /// and JSON contract, but the content is the clip's transcript, not video.
    static func buildTranscriptPrompt(languageOverride: String, styleExamples: String) -> String {
        assemble(coach: coachDocument(), languageOverride: languageOverride,
                 styleExamples: styleExamples, task: transcriptTaskAndSchema)
    }

    private static func assemble(coach: String, languageOverride: String,
                                 styleExamples: String, task: String) -> String {
        var sections: [String] = [coach]

        let language = languageOverride.trimmed
        if language.isEmpty {
            sections.append("""
            ## Output language
            Write every field in the SAME language that is spoken in the clip — \
            detect it. Do not translate it to English.
            """)
        } else {
            sections.append("""
            ## Output language
            Write every field in this language: \(language). \
            Use it regardless of the language spoken in the clip.
            """)
        }

        let style = styleExamples.trimmed
        if !style.isEmpty {
            sections.append("""
            ## The creator's own voice — match this style
            Below are examples of captions this creator likes. Mirror their tone, \
            rhythm, emoji use and formatting:

            \(style)
            """)
        }

        sections.append(task)
        return sections.joined(separator: "\n\n---\n\n")
    }

    private static let taskAndSchema = """
    ## Your task

    You have been given a short vertical video — its sampled frames and its \
    audio track. Watch and listen to it, then write a publishing package for \
    three platforms: TikTok, Instagram Reels and YouTube Shorts.

    Return ONLY a single JSON object. No prose, no markdown fences, no thinking \
    out loud. Use exactly this shape:

    {
      "language": "<BCP-47 code of the language you wrote in, e.g. es, en>",
      "variants": [
        {
          "platform": "tiktok",
          "hook": "<scroll-stopping first line, 90 characters or fewer>",
          "description": "<short, punchy caption>",
          "hashtags": ["tag", "tag", "tag"]
        },
        {
          "platform": "instagram",
          "hook": "<strong first line>",
          "description": "<2-4 short paragraphs, storytelling, ending with a call to action>",
          "hashtags": ["...20 to 30 tags, mixing big and niche reach..."]
        },
        {
          "platform": "youtube",
          "hook": "<concise, search-friendly title, about 40-60 characters>",
          "description": "<keyword-rich description written for search>",
          "hashtags": ["...3 to 5 tags..."]
        }
      ]
    }

    Rules:
    - hashtags are plain words, with NO leading '#'.
    - Each hashtag must be unique — never repeat the same tag.
    - Exactly three variants, one per platform, in the order above.
    - Never invent facts that are not visible or audible in the video.
    - Output the JSON object and nothing else.
    """

    private static let transcriptTaskAndSchema = """
    ## Your task

    You have been given the transcript of one short vertical clip (it was cut \
    from a longer video). A suggested hook line is provided. Using the \
    transcript, write a publishing package for three platforms: TikTok, \
    Instagram Reels and YouTube Shorts.

    Return ONLY a single JSON object. No prose, no markdown fences, no thinking \
    out loud. Use exactly this shape:

    {
      "language": "<BCP-47 code of the language you wrote in, e.g. es, en>",
      "variants": [
        {
          "platform": "tiktok",
          "hook": "<scroll-stopping first line, 90 characters or fewer>",
          "description": "<short, punchy caption>",
          "hashtags": ["tag", "tag", "tag"]
        },
        {
          "platform": "instagram",
          "hook": "<strong first line>",
          "description": "<2-4 short paragraphs, storytelling, ending with a call to action>",
          "hashtags": ["...20 to 30 tags, mixing big and niche reach..."]
        },
        {
          "platform": "youtube",
          "hook": "<concise, search-friendly title, about 40-60 characters>",
          "description": "<keyword-rich description written for search>",
          "hashtags": ["...3 to 5 tags..."]
        }
      ]
    }

    Rules:
    - hashtags are plain words, with NO leading '#'.
    - Each hashtag must be unique — never repeat the same tag.
    - Exactly three variants, one per platform, in the order above.
    - Never invent facts that are not in the transcript.
    - Output the JSON object and nothing else.
    """

    /// Used only if the bundled resource fails to load.
    private static let fallbackCoach = """
    # social-content-coach (fallback)

    You are an expert short-form social copywriter. Write hooks that stop the \
    scroll in the first second, captions that are easy to skim, and hashtags \
    that match the actual content. TikTok rewards punchy energy, Instagram \
    rewards storytelling and a clear call to action, YouTube Shorts rewards \
    clear, searchable titles.
    """
}
