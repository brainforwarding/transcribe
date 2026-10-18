import Foundation
import AVFoundation

/// Deterministic checks for the voice-processing input's pure parts. No audio hardware.
public func micInputSelftest() -> [String] {
    var failures: [String] = []
    func check(_ name: String, _ cond: Bool) { if !cond { failures.append(name) } }

    check("mic.unknownUID", CoreAudioDevices.deviceID(forUID: "transcribe-selftest-no-such-device") == nil)
    check("mic.disconnectedUID", !CoreAudioDevices.isMicrophone(uid: "transcribe-selftest-no-such-device"))
    check("mic.unknownDeviceHasNoInput", !CoreAudioDevices.hasInputChannels(0))

    let absent = MicrophoneStartup()
    do { try absent.wait(timeout: .milliseconds(0)); failures.append("mic.noBuffersMustFail") }
    catch { check("mic.noBuffersExplainsMicrophone", error.localizedDescription.contains("microphone")) }
    absent.recordedAudio()
    do { try absent.wait(timeout: .milliseconds(0)); failures.append("mic.timeoutCannotBecomeSuccess") } catch {}

    let interrupted = MicrophoneStartup()
    interrupted.failed("Microphone disconnected")
    interrupted.recordedAudio()
    do { try interrupted.wait(timeout: .milliseconds(0)); failures.append("mic.interruptionMustFailStartup") }
    catch { check("mic.startupPreservesFailure", error.localizedDescription == "Microphone disconnected") }

    let recording = MicrophoneStartup()
    recording.recordedAudio()
    do { try recording.wait(timeout: .milliseconds(0)) }
    catch { failures.append("mic.writtenAudioAllowsStartup") }

    if #available(macOS 14.0, *) {
        // Three channels at 48 kHz: only channel 0 (the processed voice) survives, unmixed.
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3)!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        for channel in 0..<3 { for i in 0..<4 { buffer.floatChannelData![channel][i] = Float(channel * 10 + i) } }
        let voice = VoiceProcessingMicInput.firstChannel(of: buffer)
        check("mic.firstChannel.mono", voice?.format.channelCount == 1)
        check("mic.firstChannel.rate", voice?.format.sampleRate == 48_000)
        check("mic.firstChannel.samples", voice.map { b in (0..<4).map { b.floatChannelData![0][$0] } } == [0, 1, 2, 3])
        buffer.floatChannelData![0][0] = 99
        check("mic.firstChannel.copied", voice?.floatChannelData?[0][0] == 0)
        buffer.frameLength = 0
        check("mic.firstChannel.empty", VoiceProcessingMicInput.firstChannel(of: buffer) == nil)
    }
    return failures
}
