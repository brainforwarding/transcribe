import Foundation
import AVFoundation
import CoreMedia

public struct MicDevice: Sendable, Identifiable, Hashable {
    public let uniqueID: String
    public let name: String
    public var id: String { uniqueID }
}

/// Records a chosen microphone via AVCaptureSession (the only reliable way to capture a
/// *non-default* device — AVAudioEngine is locked to the system default input). Writes
/// Float32 LinearPCM (the writer converts, absorbing AVCaptureSession's first-buffer
/// 24/32-bit format drift) and records the first buffer's PTS for sample-accurate alignment.
@available(macOS 13.0, *)
public final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

    /// Input devices for the mic picker. Selected by stable uniqueID.
    public static func available() -> [MicDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInMicrophone]
        if #available(macOS 14.0, *) { types.append(.external) }
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified)
        return session.devices.map { MicDevice(uniqueID: $0.uniqueID, name: $0.localizedName) }
    }

    private let outputURL: URL
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "transcribe.mic.capture")

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private var started = false
    private var samples = 0

    public var onLog: (@Sendable (String) -> Void)?

    public init(outputURL: URL) { self.outputURL = outputURL }

    private func log(_ s: String) {
        if let onLog { onLog(s) } else { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    }

    public var firstSamplePTS: CMTime? { queue.sync { firstPTS } }

    /// `uniqueID == nil` → system default input. Returns the resolved device name.
    @discardableResult
    public func start(uniqueID: String?) throws -> String {
        let device: AVCaptureDevice
        if let uniqueID, let d = AVCaptureDevice(uniqueID: uniqueID) {
            device = d
        } else if let d = AVCaptureDevice.default(for: .audio) {
            if uniqueID != nil { log("mic '\(uniqueID!)' not found — using system default input.") }
            device = d
        } else {
            throw RuntimeError("no audio input device available")
        }

        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RuntimeError("cannot add mic input") }
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw RuntimeError("cannot add mic output") }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        return device.localizedName
    }

    public func stop() async {
        session.stopRunning()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(); return }
                guard let writer = self.writer, let input = self.writerInput, writer.status == .writing else {
                    cont.resume(); return
                }
                input.markAsFinished()
                writer.finishWriting { cont.resume() }
            }
        }
        log("mic: \(samples) buffers captured")
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        samples += 1
        if !started {
            started = true
            let pts = sampleBuffer.presentationTimeStamp
            firstPTS = pts
            // Derive sample rate / channels from the first buffer; encode to Float32 PCM CAF.
            var sampleRate = 48_000.0
            var channels = 1
            if let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                sampleRate = asbd.mSampleRate
                channels = Int(asbd.mChannelsPerFrame)
            }
            do {
                try? FileManager.default.removeItem(at: outputURL)
                let w = try AVAssetWriter(outputURL: outputURL, fileType: .caf)
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
                let wi = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                wi.expectsMediaDataInRealTime = true
                guard w.canAdd(wi) else { log("mic: cannot add writer input"); return }
                w.add(wi)
                guard w.startWriting() else { log("mic: writer start failed: \(w.error?.localizedDescription ?? "?")"); return }
                w.startSession(atSourceTime: pts)
                self.writer = w
                self.writerInput = wi
            } catch {
                log("mic: writer setup failed: \(error)")
                return
            }
        }
        if let input = writerInput, input.isReadyForMoreMediaData {
            if !input.append(sampleBuffer) {
                log("mic: append failed: \(writer?.error?.localizedDescription ?? "?")")
            }
        }
    }
}
