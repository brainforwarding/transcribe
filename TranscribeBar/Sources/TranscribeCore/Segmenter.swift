import AVFoundation
import Foundation

public struct AudioChunk: Sendable {
    public let url: URL
    public let offset: Double   // seconds, start on the source timeline
}

private let outSampleRate = 16_000.0

/// Downmix + resample one track to **mono 16 kHz AAC/m4a** and split into ≤`chunkSeconds`
/// chunks, using AVAudioFile (read) → AVAudioConverter (resample/downmix) → AVAudioFile
/// (write AAC). This is the reliable offline-conversion path; AVAssetReader/Writer chokes on
/// resample+downmix ("Cannot Encode Media"). Each chunk is a standalone m4a starting at 0;
/// its `offset` (a multiple of `chunkSeconds`, on the output timeline) globalizes whisper
/// timestamps.
public func segmentTrack(srcWAV: URL, outDir: URL, prefix: String,
                         chunkSeconds: Double = 1200) throws -> [AudioChunk] {
    let inFile = try AVAudioFile(forReading: srcWAV)
    let inFormat = inFile.processingFormat
    guard inFile.length > 0,
          let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: outSampleRate, channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: inFormat, to: outFormat)
    else { return [] }

    let framesPerChunk = AVAudioFrameCount(chunkSeconds * outSampleRate)
    let inBlockFrames: AVAudioFrameCount = 16_384
    let outBlockFrames: AVAudioFrameCount = 16_384

    var chunks: [AudioChunk] = []
    var outFile: AVAudioFile?
    var framesInChunk: AVAudioFrameCount = 0

    func rollChunkIfNeeded() throws {
        if outFile == nil || framesInChunk >= framesPerChunk {
            outFile = nil   // flush/close previous
            let url = outDir.appendingPathComponent(
                String(format: "%@_chunk_%03d.m4a", prefix, chunks.count))
            try? FileManager.default.removeItem(at: url)
            // 32 kbps is plenty for 16 kHz mono speech; the AAC encoder rejects higher
            // bitrates at this sample rate (kAudioConverterEncodeBitRate error).
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: outSampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ]
            outFile = try AVAudioFile(forWriting: url, settings: settings)
            chunks.append(AudioChunk(url: url, offset: Double(chunks.count) * chunkSeconds))
            framesInChunk = 0
        }
    }

    var inputDone = false
    while true {
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outBlockFrames)
        else { break }
        var convError: NSError?
        let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if inputDone { outStatus.pointee = .endOfStream; return nil }
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inBlockFrames)
            else { outStatus.pointee = .endOfStream; inputDone = true; return nil }
            do {
                try inFile.read(into: inBuf, frameCount: inBlockFrames)
            } catch {
                outStatus.pointee = .endOfStream; inputDone = true; return nil
            }
            if inBuf.frameLength == 0 { outStatus.pointee = .endOfStream; inputDone = true; return nil }
            outStatus.pointee = .haveData
            return inBuf
        }
        if let convError { throw RuntimeError("convert failed: \(convError.localizedDescription)") }
        if outBuf.frameLength > 0 {
            try rollChunkIfNeeded()
            try outFile?.write(from: outBuf)
            framesInChunk += outBuf.frameLength
        }
        if status == .endOfStream { break }
        if status == .error { throw RuntimeError("converter error") }
    }
    outFile = nil   // close last
    return chunks
}
