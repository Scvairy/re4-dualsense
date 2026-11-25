import AVFAudio
import Foundation
import Tactile

struct Track: Sendable {
    let samples: [Float]
    let gain: Float
    let side: Side
    var position = 0

    static func load(_ url: URL, gain: Float, side: Side,
                     sampleRate: Double = HapticsFormat.sampleRate) throws -> Track {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, (8_000...192_000).contains(format.sampleRate),
              (1...2).contains(format.channelCount),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                               channels: format.channelCount),
              let converter = AVAudioConverter(from: format, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512) else {
            throw HelperError("expected a nonempty mono or stereo audio file")
        }

        // Prepare the track off the playback task, without imposing a file
        // prefill on the live mixer.
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        var samples: [Float] = []
        let right = format.channelCount == 1 ? 0 : 1
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            var inputError: (any Error)?
            let status = converter.convert(to: output, error: &conversionError) { requested, status in
                status.pointee = .endOfStream
                guard file.framePosition < file.length else { return nil }
                do {
                    try file.read(into: input, frameCount: min(requested, input.frameCapacity))
                    guard input.frameLength > 0 else {
                        throw HelperError("audio ended before the declared frame count")
                    }
                    status.pointee = .haveData
                    return input
                } catch {
                    inputError = error
                    return nil
                }
            }
            if let inputError { throw inputError }
            if let conversionError { throw conversionError }
            guard status != .error, status != .inputRanDry, let channels = output.floatChannelData else {
                throw HelperError("cannot convert audio to the controller sample rate")
            }
            for index in 0..<Int(output.frameLength) {
                samples.append(channels[0][index])
                samples.append(channels[right][index])
            }
            if status == .endOfStream { break }
        }
        guard !samples.isEmpty else { throw HelperError("audio is too short at the controller sample rate") }
        return Track(samples: samples, gain: gain, side: side)
    }

    mutating func mix(into output: inout [Float]) {
        let count = min(output.count, samples.count - position)
        for i in stride(from: 0, to: count, by: 2) {
            if side != .right { output[i] += samples[position + i] * gain }
            if side != .left { output[i + 1] += samples[position + i + 1] * gain }
        }
        position += count
    }

    var remainingSamples: Int { samples.count - position }

    mutating func skip(samples: Int) {
        position += min(samples, remainingSamples)
    }
}
