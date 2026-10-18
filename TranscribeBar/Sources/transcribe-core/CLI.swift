import Foundation
import TranscribeCore

// Headless validation CLI for the Transcribe core. Reads OPENAI_API_KEY (+ optional
// OPENAI_BASE_URL) from the environment.
//   transcribe-core selftest
//   transcribe-core mics
//   transcribe-core record  <outDir> <seconds> [micUniqueID] [--mic-only]
//   transcribe-core transcribe <mic.wav|-> <system.wav|-> <outDir> [lang]
//   transcribe-core capture <outDir> <seconds> [micUniqueID] [lang] [--mic-only]   (record + transcribe)
@main
struct CLI {
    static func main() async {
        let args = CommandLine.arguments
        let cmd = args.count >= 2 ? args[1] : ""

        switch cmd {
        case "selftest":
            let failures = mergeSelftest() + namingSelftest() + micInputSelftest()
            let contractsPassed = await runTranscriptionSelftests()
            let storePassed = runSessionStoreSelftests()
            if failures.isEmpty && contractsPassed && storePassed { print("selftest: ALL MERGE + NAMING + CORE CONTRACT + STORE TESTS PASSED"); exit(0) }
            err("selftest FAILED: \(failures.joined(separator: ", "))"); exit(1)

        case "mics":
            if #available(macOS 13.0, *) {
                for d in MicCapture.available() { print("  \(d.uniqueID)  \(d.name)") }
            }
            exit(0)

        case "record":
            await recordCmd(args, transcribeAfter: false)

        case "capture":
            await recordCmd(args, transcribeAfter: true)

        case "transcribe":
            guard args.count >= 5 else { usage(); exit(2) }
            let micURL = args[2] == "-" ? nil : URL(fileURLWithPath: args[2])
            let sysURL = args[3] == "-" ? nil : URL(fileURLWithPath: args[3])
            let outDir = URL(fileURLWithPath: args[4])
            let lang = args.count > 5 ? args[5] : nil
            let config = OpenAIConfig.fromEnv()
            guard config.hasKey else { err("OPENAI_API_KEY not set"); exit(1) }
            do {
                let r = try await transcribeSession(
                    micWAV: micURL, systemWAV: sysURL, chunkDir: outDir,
                    transcriptURL: outDir.appendingPathComponent("transcript.md"),
                    title: outDir.lastPathComponent, language: lang, micOffset: 0, config: config)
                print("\n=== \(r.transcriptURL.path) ===\n")
                print((try? String(contentsOf: r.transcriptURL, encoding: .utf8)) ?? "")
            } catch { err("ERROR: \(error)"); exit(1) }

        default:
            usage(); exit(2)
        }
    }

    @available(macOS 13.0, *)
    static func recordCmd(_ rawArgs: [String], transcribeAfter: Bool) async {
        let micOnly = rawArgs.contains("--mic-only")
        let args = rawArgs.filter { $0 != "--mic-only" }
        guard args.count >= 4 else { usage(); exit(2) }
        let outDir = URL(fileURLWithPath: args[2])
        let seconds = Double(args[3]) ?? 6
        let micUID = args.count > 4 && args[4] != "-" ? args[4] : nil
        let lang = args.count > 5 ? args[5] : nil
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let ctl = CaptureController(outDir: outDir, micUniqueID: micUID, micOnly: micOnly)
        ctl.onLog = { s in FileHandle.standardError.write(("  [cap] " + s + "\n").data(using: .utf8)!) }
        do { try await ctl.start() } catch { err("capture start failed: \(error)"); exit(1) }
        print("recording for \(seconds)s\(micOnly ? " (mic only)" : "")…")
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        let r = await ctl.stop()

        func size(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int) ?? 0 }
        if let sysURL = r.systemURL, let sys = r.systemSummary {
            print(String(format: "system: %@ (%d bytes, non-silent=%@)  mic: %@ (%d bytes)  micOffset=%.3fs",
                         sysURL.lastPathComponent, size(sysURL), sys.nonSilent ? "yes" : "no",
                         r.micURL.lastPathComponent, size(r.micURL), r.micOffset))
        } else {
            print(String(format: "mic only: %@ (%d bytes)", r.micURL.lastPathComponent, size(r.micURL)))
        }

        if transcribeAfter {
            let config = OpenAIConfig.fromEnv()
            guard config.hasKey else { err("OPENAI_API_KEY not set"); exit(1) }
            do {
                let result = try await transcribeFinal(tracks: r.tracks,
                    kind: micOnly ? .dictation : .onlineMeeting,
                    chunkDir: outDir.appendingPathComponent("work"),
                    languages: lang.map { [$0] } ?? [], config: config)
                guard result.complete, r.issues.isEmpty else {
                    err("Capture/transcription is incomplete. Audio and successful chunks are retained.")
                    exit(1)
                }
                let conversation: String
                if micOnly { conversation = result.text }
                else {
                    let turns = result.segments.map { turn -> Segment in
                        var turn = turn; turn.label = turn.source == .mic ? "You" : "Them"; return turn
                    }
                    conversation = renderConversation(mergeSegments(turns), timestamps: true)
                }
                let transcriptURL = outDir.appendingPathComponent("transcript.md")
                let markdown = "# \(outDir.lastPathComponent)\n\n" + (conversation.isEmpty ? "_(no speech detected)_" : conversation) + "\n"
                try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
                print("\n=== \(transcriptURL.path) ===\n")
                print(markdown)
            } catch { err("transcribe failed: \(error)"); exit(1) }
        }
        exit(0)
    }

    static func usage() {
        err("""
        usage:
          transcribe-core selftest
          transcribe-core mics
          transcribe-core record    <outDir> <seconds> [micUniqueID] [--mic-only]
          transcribe-core capture   <outDir> <seconds> [micUniqueID] [lang] [--mic-only]
          transcribe-core transcribe <mic.wav|-> <system.wav|-> <outDir> [lang]
        """)
    }

    static func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
}
