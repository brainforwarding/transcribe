import Foundation
import AVFoundation

/// Render captured mono 16 kHz spans on their host-clock timeline, padding actual gaps
/// with silence. Used for final source uploads and mixed, nonauthoritative preview windows.
func writeAlignedAudio(tracks: [SessionAudioTrack], to output: URL, start: Double,
                       duration: Double, mix: Bool) throws {
    guard start.isFinite, duration.isFinite, duration >= 0,
          let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    else { throw RuntimeError("Invalid audio timeline.") }
    let totalFrames = Int64((duration * 16_000).rounded())
    struct Input { let url: URL; let firstFrame: Int64; let lastFrame: Int64 }
    var inputs: [Input] = []
    for track in tracks {
        for span in track.spans where span.offset < start + duration && span.offset + span.duration > start {
            let first = Int64(((span.offset - start) * 16_000).rounded())
            inputs.append(Input(url: span.url, firstFrame: first, lastFrame: first + Int64((span.duration * 16_000).rounded())))
        }
    }
    // Only files overlapping the current one-second render window remain open.
    // A long workshop can contain hundreds of finalized capture parts per source.
    var openInputs: [Int: AVAudioFile] = [:]
    let file = try AVAudioFile(forWriting: output, settings: format.settings)
    var position: Int64 = 0
    while position < totalFrames {
        try autoreleasepool {
            let count = AVAudioFrameCount(min(16_000, totalFrames - position))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count), let dest = buffer.floatChannelData?[0]
            else { throw RuntimeError("Audio buffering failed.") }
            buffer.frameLength = count
            dest.initialize(repeating: 0, count: Int(count))
            for (index, input) in inputs.enumerated() where input.firstFrame < position + Int64(count) && input.lastFrame > position {
                let inputFile: AVAudioFile
                if let opened = openInputs[index] { inputFile = opened }
                else {
                    inputFile = try AVAudioFile(forReading: input.url)
                    guard inputFile.processingFormat.sampleRate == 16_000, inputFile.processingFormat.channelCount == 1 else {
                        throw RuntimeError("Captured audio must be normalized before timeline rendering.")
                    }
                    guard inputFile.length >= input.lastFrame - input.firstFrame else {
                        throw RuntimeError("A recorded audio section is incomplete.")
                    }
                    openInputs[index] = inputFile
                }
                let from = max(position, input.firstFrame), to = min(position + Int64(count), input.lastFrame)
                let frames = AVAudioFrameCount(to - from)
                inputFile.framePosition = from - input.firstFrame
                let shift = Int(from - position)
                let scale: Float = mix ? 1 / Float(max(1, tracks.count)) : 1
                var consumed: AVAudioFrameCount = 0
                while consumed < frames {
                    let requested = min(8_192, frames - consumed)
                    guard let read = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: requested) else {
                        throw RuntimeError("Audio buffering failed.")
                    }
                    try inputFile.read(into: read, frameCount: requested)
                    // AVAudioFile may return fewer frames than requested before EOF.
                    guard read.frameLength > 0, let samples = read.floatChannelData?[0] else {
                        throw RuntimeError("A recorded audio section is incomplete.")
                    }
                    for i in 0..<Int(read.frameLength) { dest[shift + Int(consumed) + i] += samples[i] * scale }
                    consumed += read.frameLength
                }
            }
            for i in 0..<Int(count) { dest[i] = min(1, max(-1, dest[i])) }
            try file.write(from: buffer)
            position += Int64(count)
            openInputs = openInputs.filter { inputs[$0.key].lastFrame > position }
        }
    }
}
