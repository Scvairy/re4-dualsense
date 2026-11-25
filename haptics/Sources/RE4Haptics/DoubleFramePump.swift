import Foundation
import Tactile

// The compact haptics-only framing uses the same 142-byte report 0x32
// as the single-frame format. See the protocol source in README.md.
struct DoubleFrameReport {
    static let byteCount = 142
    static let sampleCount = HapticsFormat.bytesPerReport * 2
    private var sequence: UInt8 = 0
    private var frameCounter: UInt8 = 0

    mutating func encode(_ samples: [Int8]) -> [UInt8] {
        precondition(samples.count == Self.sampleCount)
        var packet = [UInt8](repeating: 0, count: Self.byteCount)
        packet[0] = HapticsFormat.reportID
        packet[1] = sequence << 4
        // Short control block with mic disabled, followed by two 64-byte
        // stereo PCM blocks. Bit 6 in 0xd2 marks the double payload.
        packet.replaceSubrange(2..<10, with: [0x91, 4, 0x66, 48, 48, frameCounter, 0xd2, 64])
        for (index, sample) in samples.enumerated() {
            packet[10 + index] = UInt8(bitPattern: sample)
        }
        CRC32.seal(&packet, prefix: .output)
        sequence = (sequence + 1) & 0x0f
        frameCounter &+= 2
        return packet
    }
}

@MainActor
final class DoubleFramePump {
    private static let period: Duration = .seconds(2 * HapticsFormat.reportPeriodSeconds)
    private static let writeTimeout: Duration = .milliseconds(100)
    private static let touchedDelay: Duration = .milliseconds(15)
    private static let silentTailReports = 4

    private struct Pending {
        let createdAt: ContinuousClock.Instant
        let samples: [Int8]
    }

    private final class Onset {
        let receivedAt: ContinuousClock.Instant
        var measured = false

        init(_ receivedAt: ContinuousClock.Instant) {
            self.receivedAt = receivedAt
        }
    }

    private struct Voice {
        var track: Track
        let onset: Onset?
    }

    private struct Write {
        let id: UInt64
        let task: Task<Void, Never>
        let watchdog: Task<Void, Never>
    }

    private enum WriteResult {
        case sent, failed, stalled
    }

    let mixer: HapticsMixer
    private let maxBacklog: Duration
    private let restore: (@Sendable () async throws -> Void)?
    private let send: @Sendable ([UInt8]) async throws -> Void
    private let clock = ContinuousClock()
    private var encoder = DoubleFrameReport()
    private var scheduler: Task<Void, Never>?
    private var writing: Write?
    private var writeID: UInt64 = 0
    private var pending: [Pending] = []
    private var voices: [Voice] = []
    private var quantizer = Quantizer8(dither: false)
    private var tailRemaining = 0
    private var restorePending = false
    private var touchedWake: Task<Void, Never>?

    private var sent = 0
    private var dropped = 0
    private var deferred = 0
    private var stalled = 0
    private var restored = 0
    private var restoreFailed = 0
    private var underrunTicks = 0
    private var underrunFrames = 0
    private var sendLatencyTotal = 0.0
    private var recentLatencies: [Double] = []
    private var triggerCount = 0
    private var triggerLatencyTotal = 0.0
    private var recentTriggerLatencies: [Double] = []

    init(mixer: HapticsMixer, maxBacklog: Duration = .milliseconds(30),
         restore: (@Sendable () async throws -> Void)? = nil,
         send: @escaping @Sendable ([UInt8]) async throws -> Void) {
        self.mixer = mixer
        self.maxBacklog = maxBacklog
        self.restore = restore
        self.send = send
    }

    func start() {
        guard scheduler == nil else { return }
        scheduler = Task { [weak self, clock] in
            var deadline = clock.now + Self.period
            while !Task.isCancelled {
                do {
                    try await clock.sleep(until: deadline, tolerance: .milliseconds(1))
                } catch {
                    break
                }
                guard let self, !Task.isCancelled else { break }
                let now = clock.now
                self.slot(at: now)
                deadline += Self.period
                // Do not burst output after a suspended process wakes up.
                if deadline <= now { deadline = now + Self.period }
            }
        }
        restorePending = restore != nil
        sendPending()
    }

    private func slot(at now: ContinuousClock.Instant) {
        discardExpired(at: now)
        if let samples = render() {
            if writing != nil || !pending.isEmpty { deferred += 1 }
            pending.append(Pending(createdAt: now, samples: samples))
        }
        sendPending()
    }

    private func discardExpired(at now: ContinuousClock.Instant) {
        while let oldest = pending.first, now - oldest.createdAt > maxBacklog {
            pending.removeFirst()
            dropped += 1
            // Started tracks follow the report timeline. New voices keep
            // their attack for the oldest block that will actually be sent.
            for index in voices.indices where voices[index].track.position > 0 {
                voices[index].track.skip(samples: DoubleFrameReport.sampleCount)
            }
            voices.removeAll { $0.track.remainingSamples == 0 }
        }
    }

    private func sendPending() {
        guard scheduler != nil, writing == nil else { return }
        if restorePending, let restore {
            restorePending = false
            startWrite(isRestore: true, operation: restore)
            return
        }
        guard !pending.isEmpty else { return }
        let (samples, onsets) = mixVoices(into: pending.removeFirst().samples)
        let packet = encoder.encode(samples)
        let send = self.send
        startWrite(isRestore: false, onsets: onsets) { try await send(packet) }
    }

    var voiceCount: Int { voices.count }

    func play(_ track: Track, triggeredAt: ContinuousClock.Instant?) {
        discardExpired(at: clock.now)
        voices.append(Voice(track: track, onset: triggeredAt.map(Onset.init)))
        sendPending()
    }

    private func mixVoices(into samples: [Int8]) -> ([Int8], [Onset]) {
        guard !voices.isEmpty else { return (samples, []) }
        var mixed = samples.map { Float($0) / 127 }
        var onsets: [Onset] = []
        for index in voices.indices {
            if let onset = voices[index].onset, !onset.measured { onsets.append(onset) }
            voices[index].track.mix(into: &mixed)
        }
        voices.removeAll { $0.track.remainingSamples == 0 }
        return (mixed.map { quantizer.quantize($0) }, onsets)
    }

    private func startWrite(isRestore: Bool, onsets: [Onset] = [],
                            operation: @escaping @Sendable () async throws -> Void) {
        writeID &+= 1
        let id = writeID
        let started = clock.now
        let task = Task { [weak self] in
            let result: WriteResult
            do {
                try await operation()
                result = .sent
            } catch TransportError.timeout {
                result = .stalled
            } catch {
                result = .failed
            }
            self?.finishWrite(id: id, started: started, isRestore: isRestore, onsets: onsets, result: result)
        }
        // Do not use a task group here: it would wait for a cancelled HID
        // request to finish before returning, which can permanently block output.
        let watchdog = Task { [weak self, clock] in
            do {
                try await clock.sleep(until: started + Self.writeTimeout)
                self?.finishWrite(id: id, started: started, isRestore: isRestore, onsets: onsets, result: .stalled)
            } catch {}
        }
        writing = Write(id: id, task: task, watchdog: watchdog)
    }

    private func finishWrite(id: UInt64, started: ContinuousClock.Instant, isRestore: Bool,
                             onsets: [Onset], result: WriteResult) {
        // A late completion belongs to the expired request, not its successor.
        guard let write = writing, write.id == id else { return }
        writing = nil
        write.watchdog.cancel()
        if result == .stalled {
            stalled += 1
            write.task.cancel()
        }
        if isRestore {
            if result == .sent {
                restored += 1
            } else {
                restoreFailed += 1
                // Let waveform output progress before retrying a failed restore.
                restorePending = false
            }
        } else if result == .sent {
            sent += 1
            let now = clock.now
            let latency = Self.microseconds(now - started)
            sendLatencyTotal += latency
            if recentLatencies.count == 256 { recentLatencies.removeFirst() }
            recentLatencies.append(latency)
            for onset in onsets where !onset.measured {
                onset.measured = true
                triggerCount += 1
                let latency = Self.microseconds(now - onset.receivedAt)
                triggerLatencyTotal += latency
                if recentTriggerLatencies.count == 256 { recentTriggerLatencies.removeFirst() }
                recentTriggerLatencies.append(latency)
            }
        } else {
            dropped += 1
        }
        discardExpired(at: clock.now)
        sendPending()
    }

    func outputTouched() {
        guard restore != nil, scheduler != nil, touchedWake == nil else { return }
        touchedWake = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.touchedDelay)
            } catch { return }
            guard let self else { return }
            self.touchedWake = nil
            self.restorePending = true
            self.discardExpired(at: self.clock.now)
            self.sendPending()
        }
    }

    private func render() -> [Int8]? {
        let hasPCM = !mixer.isIdle
        let active = hasPCM || !voices.isEmpty
        let sendSilence = tailRemaining > 0
        if active {
            tailRemaining = Self.silentTailReports
        } else if tailRemaining > 0 {
            tailRemaining -= 1
        }
        // Render even while idle so the mixer can apply StopAll's pending
        // ring-buffer clear before newer PCM arrives.
        var first = [Int8](repeating: 0, count: HapticsFormat.bytesPerReport)
        var second = first
        let missing = mixer.render(into: &first) + mixer.render(into: &second)
        if hasPCM && missing > 0 {
            underrunTicks += 1
            underrunFrames += missing
        }
        return active || sendSilence ? first + second : nil
    }

    func stopAll() {
        mixer.stopAll()
        pending.removeAll()
        voices.removeAll()
        tailRemaining = Self.silentTailReports
    }

    func stop() async {
        let running = scheduler
        scheduler = nil
        running?.cancel()
        touchedWake?.cancel()
        touchedWake = nil
        restorePending = false
        pending.removeAll()
        await running?.value
        await writing?.watchdog.value
    }

    var metrics: String {
        let mean = sent == 0 ? 0 : sendLatencyTotal / Double(sent)
        let buffered = Double(mixer.stream.availableToRead / 2) * 1000 / HapticsFormat.sampleRate
        let timing = String(format: "mean=%.1f µs p99=%.1f µs buffered=%.1f ms",
                            mean, Self.percentile99(recentLatencies), buffered)
        let triggerMean = triggerCount == 0 ? 0 : triggerLatencyTotal / Double(triggerCount)
        let triggerTiming = String(format: "trigger-first count=%d mean=%.1f ms p99=%.1f ms",
                                   triggerCount, triggerMean / 1000, Self.percentile99(recentTriggerLatencies) / 1000)
        return "sent=\(sent) dropped=\(dropped) deferred=\(deferred) stalled=\(stalled)"
            + " restored=\(restored) restoreFailed=\(restoreFailed)"
            + " underruns=\(underrunTicks) ticks/\(underrunFrames) frames send latency \(timing) \(triggerTiming)"
    }

    private static func microseconds(_ duration: Duration) -> Double {
        let elapsed = duration.components
        return Double(elapsed.seconds) * 1_000_000 + Double(elapsed.attoseconds) / 1e12
    }

    private static func percentile99(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[Int((Double(sorted.count - 1) * 0.99).rounded())]
    }
}
