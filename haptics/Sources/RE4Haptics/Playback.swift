import CoreHID
import Foundation
import Tactile

@MainActor
final class Playback {
    private static let maxTracks = HapticsMixer.maxVoices

    private let catalog: TriggerCatalog
    private let trace: Bool
    private let restoreAudioMode: Bool
    private let pcmPrefillBlocks: Int
    private let maxBacklog: Duration
    // One double report of PCM per ring, independent of the prefill.
    private static let queueSamples = DoubleFrameReport.sampleCount
    private let staging = HapticsMixer()
    private var input: PCMInput?
    private var pcmFormat: (rate: Double, channels: Int)?
    private var inputDeadline: ContinuousClock.Instant?
    private var finishStream = false
    private var loading: [UUID: Task<Void, Never>] = [:]
    private var available: [(info: DeviceInfo, reference: HIDDeviceClient.DeviceReference)] = []
    private var connection: OutputConnection?
    private var pump: DoubleFramePump?
    private var warned: Set<String> = []
    private var waitingReported = false

    init(catalog: TriggerCatalog, trace: Bool, restoreAudioMode: Bool = true,
         pcmPrefillBlocks: Int = 2, maxBacklog: Duration = .milliseconds(30)) {
        self.catalog = catalog
        self.trace = trace
        self.restoreAudioMode = restoreAudioMode
        self.pcmPrefillBlocks = pcmPrefillBlocks
        self.maxBacklog = maxBacklog
    }

    func controllerEvent(_ event: DiscoveryEvent) async {
        switch event {
        case .connected(let info, let reference):
            if info.transport == .bluetooth, !available.contains(where: { $0.info.deviceID == info.deviceID }) {
                available.append((info, reference))
            }
        case .disconnected(let deviceID):
            available.removeAll { $0.info.deviceID == deviceID }
            if connection?.deviceID == deviceID {
                await disconnect()
                log("DualSense disconnected")
            }
        }
        guard connection == nil, !Task.isCancelled else { return }
        for (info, reference) in available {
            connect(info, reference: reference)
            if connection != nil { break }
        }
    }

    private func connect(_ info: DeviceInfo, reference: HIDDeviceClient.DeviceReference) {
        let descriptor = try? HIDDescriptor(parsing: [UInt8](info.reportDescriptor))
        if let length = descriptor?.report(.output, id: HapticsFormat.reportID)?.byteLength,
           length != DoubleFrameReport.byteCount {
            warnOnce("report-length", "unsupported haptics report length: \(length)")
            return
        }
        let connection: OutputConnection
        do {
            connection = try OutputConnection(info: info, reference: reference)
        } catch {
            warnOnce("open", "controller open failed: \(error)")
            return
        }
        let restore: (@Sendable () async throws -> Void)?
        if restoreAudioMode {
            restore = {
                try await connection.restoreAudioMode()
            }
        } else {
            restore = nil
        }
        let mixer = HapticsMixer(streamPrefillFrames: pcmPrefillBlocks * HapticsFormat.framesPerReport)
        let pump = DoubleFramePump(mixer: mixer, maxBacklog: maxBacklog, restore: restore) { packet in
            try await connection.send(packet)
        }
        self.pump = pump
        self.connection = connection
        pump.start()
        waitingReported = false
        log("connected to \(info.model.displayName) over Bluetooth in shared output-only mode (64 frames/report)")
    }

    func receive(_ frame: Frame) {
        switch frame.type {
        case 1:
            guard let pcm = frame.pcm else {
                warnOnce("pcm", "ignored malformed PCM frame")
                return
            }
            guard connection != nil else { return }
            let now = ContinuousClock.now
            if pcmFormat?.rate != pcm.rate || pcmFormat?.channels != pcm.channels {
                clearPCM()
                input = PCMInput(mixer: staging, inputRate: pcm.rate)
                pcmFormat = (pcm.rate, pcm.channels)
            }
            expirePCM(at: now)
            let duration = Double(pcm.samples.count / pcm.channels) / pcm.rate
            inputDeadline = now + .seconds(max(0.025, duration + 0.012))
            input?.feed(interleaved: pcm.samples, channelCount: pcm.channels)
            fillOutput()
        case 2:
            guard let track = frame.track else {
                warnOnce("track", "ignored malformed PlayTrack frame")
                return
            }
            guard connection != nil, track.gain > 0 else { return }
            playTrack(track.url, gain: track.gain, side: track.side)
        case 3 where frame.payload.isEmpty:
            stopAll()
        case 3:
            warnOnce("stop", "ignored StopAll frame with a payload")
        case 4:
            let receivedAt = ContinuousClock.now
            guard let trigger = frame.trigger else {
                warnOnce("trigger", "ignored malformed Trigger frame")
                return
            }
            guard let entry = catalog.entries[trigger.hash], entry.allows(pad: trigger.pad) else { return }
            let gain = entry.gain * trigger.powerScale
            guard gain.isFinite, gain > 0 else { return }
            if trace {
                let hash = String(format: "0x%08x", trigger.hash)
                let scale = String(format: "%.4f", gain)
                log("trigger \(hash) \(entry.path) gain=\(scale)")
            }
            guard connection != nil else { return }
            playTrack(entry.url, gain: gain, side: .both, triggeredAt: receivedAt)
        case 5 where frame.payload.isEmpty:
            pump?.outputTouched()
        case 5:
            warnOnce("output-touched", "ignored OutputTouched frame with a payload")
        default:
            warnOnce("unknown", "ignored unknown frame type \(frame.type)")
        }
    }

    private func playTrack(_ url: URL, gain: Float, side: Side, triggeredAt: ContinuousClock.Instant? = nil) {
        guard let pump else { return }
        guard pump.voiceCount + loading.count < Self.maxTracks else {
            warnOnce("voices", "ignored PlayTrack because all track slots are in use")
            return
        }
        let id = UUID()
        loading[id] = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try Track.load(url, gain: gain, side: side) }
            await self?.trackLoaded(id, url: url, result: result, triggeredAt: triggeredAt)
        }
    }

    private func trackLoaded(_ id: UUID, url: URL, result: Result<Track, any Error>,
                             triggeredAt: ContinuousClock.Instant?) {
        guard loading.removeValue(forKey: id) != nil, let pump else { return }
        switch result {
        case .success(let track):
            pump.play(track, triggeredAt: triggeredAt)
        case .failure(let error):
            warnOnce(url.path, "cannot play \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // PCMInput keeps a few milliseconds of resampler look-ahead. Finish its
    // tail on a gap and reset the filters, so a later burst starts clean.
    private func expirePCM(at now: ContinuousClock.Instant) {
        guard let inputDeadline, now >= inputDeadline else { return }
        input?.flush()
        self.inputDeadline = nil
        finishStream = true
    }

    // The main actor owns both ends of the staging ring. The controller pump
    // consumes only its own output ring, with a single writer here.
    private func fillOutput() {
        guard let mixer = pump?.mixer else { return }

        let excess = staging.stream.availableToRead - Self.queueSamples
        if excess > 0 {
            var discarded = [Float](repeating: 0, count: excess)
            _ = discarded.withUnsafeMutableBufferPointer {
                staging.stream.read(into: $0.baseAddress!, count: $0.count)
            }
        }
        let room = Self.queueSamples - mixer.stream.availableToRead
        let count = min(room, staging.stream.availableToRead)
        if count > 0 {
            var samples = [Float](repeating: 0, count: count)
            _ = samples.withUnsafeMutableBufferPointer {
                staging.stream.read(into: $0.baseAddress!, count: $0.count)
            }
            mixer.stream.write(samples)
        }
        if finishStream, staging.stream.availableToRead == 0 {
            mixer.finishStream()
            finishStream = false
        }
    }

    private func clearPCM() {
        staging.stream.clear()
        input = nil
        pcmFormat = nil
        inputDeadline = nil
        finishStream = false
    }

    func stopAll() {
        clearPCM()
        for task in loading.values { task.cancel() }
        loading.removeAll()
        pump?.stopAll()
    }

    private func disconnect() async {
        stopAll()
        let pump = self.pump
        self.pump = nil
        connection = nil
        await pump?.stop()
    }

    func shutdown() async {
        let connection = self.connection
        await disconnect()
        await connection?.neutralize()
    }

    var needsTick: Bool {
        inputDeadline != nil || staging.stream.availableToRead > 0
    }

    func tick() {
        expirePCM(at: .now)
        fillOutput()
    }

    func reportStatus(trace: Bool) {
        if connection == nil, !waitingReported {
            log("waiting for a Bluetooth DualSense")
            waitingReported = true
        }
        if trace, let pump {
            log(pump.metrics)
        }
    }

    private func warnOnce(_ key: String, _ message: String) {
        if warned.insert(key).inserted { log(message) }
    }
}
