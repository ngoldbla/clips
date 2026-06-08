import Foundation

// Headless validation of the Director (Gemma 4 E2B). Loads the REAL
// `MomentFinderService` and runs one moment-finding + inline-caption pass over a
// transcript — no GUI / WindowServer, so it runs from any shell (the app's
// SwiftUI `.task` never fires when the binary is launched without a window
// session, which is why the GUI autorun seam can't be driven headlessly).
//
// Pick the model with the DEBUG env `CLIPMUNK_DIRECTOR_MODEL` (e.g. the unsloth
// UD build) to A/B it against the standard 4-bit baseline. Optional arg 1 is a
// transcript file; otherwise the built-in sample is used.

func note(_ message: String) {
    FileHandle.standardError.write(Data("[probe] \(message)\n".utf8))
}

/// A realistic ~2-minute tutorial transcript in the `[M:SS] text` shape the
/// Director reads (the same `srtLike()` format the pipeline feeds it).
let sampleTranscript = """
[0:00] Welcome back to the channel. Today I'm going to show you the three biggest mistakes people make when they book a meeting room, and how to fix them in under a minute.
[0:12] The first mistake is booking a room that's way too big. If it's just you and one other person, you do not need the twelve-seat boardroom.
[0:24] Here's the trick nobody tells you: filter by capacity first, then by time. It sounds obvious but ninety percent of people do it backwards and end up double-booked.
[0:39] Mistake number two, and this one cost my team a whole client pitch, is not checking whether the room actually has a screen that works with your laptop.
[0:54] Always, always do a thirty second tech check the day before. Walk in, plug in, make sure it mirrors. Future you will thank present you.
[1:10] The third mistake is the silent killer: back to back bookings with no buffer. You run five minutes over, the next group is standing outside, and now you look unprofessional.
[1:28] So here's what I do. I block a ten minute buffer after every meeting automatically. In the settings, turn on auto buffer and set it to ten minutes. Done.
[1:45] If you only remember one thing from this video, let it be this: the room doesn't make the meeting, the prep does. Book smart, check early, leave a buffer.
[2:00] That's it for today. If this saved you a headache, you know what to do. I'll see you in the next one.
"""

MemoryPolicy.configureMLX()
let start = Date()
let svc = await MomentFinderService()

let env = ProcessInfo.processInfo.environment
let transcript: String
if CommandLine.arguments.count > 1,
   let text = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8),
   !text.isEmpty {
    transcript = text
} else {
    transcript = sampleTranscript
}

let modelID = env["CLIPMUNK_DIRECTOR_MODEL"] ?? ChatModelProfile.director.modelID
note("director=\(modelID), transcript=\(transcript.count) chars")

await svc.prepareIfNeeded()
guard await svc.isReady else {
    print("LOAD_FAILED phase=\(await svc.phase)")
    exit(2)
}
note(String(format: "loaded in %.1fs", Date().timeIntervalSince(start)))

do {
    let clips = try await svc.findMoments(
        transcript: transcript, includeCaptions: true,
        language: "English", styleExamples: "")
    print(String(format: "FINDMOMENTS_OK clips=%d total=%.1fs",
                 clips.count, Date().timeIntervalSince(start)))
    for (i, c) in clips.enumerated() {
        print(String(format: "  [%d] %@  score=%.0f  hook=%@",
                     i + 1, c.rangeLabel, c.score, c.hook))
        if let tt = c.variants.first(where: { $0.platform == .tiktok }) {
            print("       tiktok: \(tt.hook)  |  #\(tt.hashtags.prefix(3).joined(separator: " #"))")
        }
    }
    print("CAPTIONS_PRESENT=\(clips.filter { !$0.variants.isEmpty }.count)/\(clips.count)")
    exit(0)
} catch {
    print("FINDMOMENTS_FAILED \(error)")
    exit(3)
}
