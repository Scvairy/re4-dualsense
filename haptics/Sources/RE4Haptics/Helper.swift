import Darwin
import Foundation
import Tactile

func log(_ message: String) {
    FileHandle.standardError.write(Data("re4-haptics: \(message)\n".utf8))
}

@main
struct Helper {
    static let usage = "Usage: re4-haptics [--fd N] [--trace] [--no-restore] [--pcm-prefill-blocks 1|2] [--report-backlog-ms 0...60]"

    @MainActor
    static func main() async {
        var fd: Int32 = STDIN_FILENO
        var trace = false
        var restoreAudioMode = true
        var pcmPrefillBlocks = 2
        var backlogMilliseconds = 30
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--fd":
                guard let value = args.next(), let parsed = Int32(value), parsed >= 0 else {
                    log(usage)
                    exit(64)
                }
                fd = parsed
            case "--trace":
                trace = true
            case "--no-restore":
                restoreAudioMode = false
            case "--pcm-prefill-blocks":
                guard let value = args.next(), let parsed = Int(value), (1...2).contains(parsed) else {
                    log(usage)
                    exit(64)
                }
                pcmPrefillBlocks = parsed
            case "--report-backlog-ms":
                guard let value = args.next(), let parsed = Int(value), (0...60).contains(parsed) else {
                    log(usage)
                    exit(64)
                }
                backlogMilliseconds = parsed
            case "--help", "-h":
                print(usage)
                return
            default:
                log(usage)
                exit(64)
            }
        }
        guard fcntl(fd, F_GETFD) >= 0 else {
            log("invalid input fd \(fd)")
            exit(64)
        }

        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let directory = TriggerCatalog.directory(for: executable)
        let catalog: TriggerCatalog
        do {
            catalog = try TriggerCatalog.load(from: directory)
            if trace { log("loaded \(catalog.entries.count) trigger mappings") }
        } catch {
            if trace { log("could not load \(directory.path)/triggers.tsv: \(error.localizedDescription)") }
            catalog = TriggerCatalog(entries: [:])
        }
        let playback = Playback(catalog: catalog, trace: trace, restoreAudioMode: restoreAudioMode,
                                pcmPrefillBlocks: pcmPrefillBlocks, maxBacklog: .milliseconds(backlogMilliseconds))
        let discovery = Task {
            do {
                for try await event in DeviceDiscovery().events() {
                    guard !Task.isCancelled else { break }
                    await playback.controllerEvent(event)
                }
            } catch {
                if !Task.isCancelled { log("controller discovery failed: \(error)") }
            }
        }
        let ticker = Task {
            var nextReport = ContinuousClock.now + .seconds(1)
            while !Task.isCancelled {
                playback.tick()
                let now = ContinuousClock.now
                if now >= nextReport {
                    playback.reportStatus(trace: trace)
                    nextReport = now + .seconds(1)
                }
                try? await Task.sleep(for: playback.needsTick ? .milliseconds(3) : .milliseconds(25))
            }
        }

        var status: Int32 = 0
        do {
            while let frame = try await Frame.read(from: fd) {
                playback.receive(frame)
            }
        } catch {
            log(error.localizedDescription)
            status = 1
        }

        await exitAfterControllerCleanup(status: status) {
            ticker.cancel()
            discovery.cancel()
            if trace { playback.reportStatus(trace: true) }
            await playback.shutdown()
            await discovery.value
        }
    }
}
