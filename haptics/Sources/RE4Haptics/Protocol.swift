import Darwin
import Dispatch
import Foundation

struct HelperError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct Frame: Sendable {
    private static let maxPayload = 256 * 1024

    let type: UInt32
    let payload: Data

    var pcm: (rate: Double, channels: Int, samples: [Float])? {
        guard payload.count > 8 else { return nil }
        let rate = Double(payload.uint32(at: 0))
        let channels = Int(payload.uint32(at: 4))
        guard (8_000...192_000).contains(rate), (channels == 1 || channels == 2),
              (payload.count - 8).isMultiple(of: channels * 4) else { return nil }
        let samples = payload.withUnsafeBytes { bytes in
            stride(from: 8, to: bytes.count, by: 4).map { offset in
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
        }
        return (rate, channels, samples)
    }

    var track: (gain: Float, side: Side, url: URL)? {
        guard payload.count > 8 else { return nil }
        let gain = Float(bitPattern: payload.uint32(at: 0))
        guard gain.isFinite, gain >= 0,
              let side = Side(rawValue: payload.uint32(at: 4)),
              let path = String(data: payload.dropFirst(8), encoding: .utf8),
              !path.contains("\0") else { return nil }
        return (gain, side, URL(fileURLWithPath: path))
    }

    var trigger: (hash: UInt32, powerScale: Float, pad: Int32)? {
        guard payload.count == 12 else { return nil }
        let scale = Float(bitPattern: payload.uint32(at: 4))
        let pad = Int32(bitPattern: payload.uint32(at: 8))
        guard scale.isFinite, scale == -1 || scale >= 0, (-1...31).contains(pad) else { return nil }
        return (payload.uint32(at: 0), scale == -1 ? 1 : scale, pad)
    }

    static func read(from fd: Int32) async throws -> Frame? {
        try await withCheckedThrowingContinuation { continuation in
            // Keep the blocking pipe read off the main actor and Swift task pool.
            DispatchQueue.global(qos: .userInteractive).async {
                continuation.resume(with: Result {
                    guard let header = try readExactly(8, from: fd) else { return nil }
                    let length = Int(header.uint32(at: 4))
                    guard length <= maxPayload else { throw HelperError("frame payload exceeds \(maxPayload) bytes") }
                    guard let payload = try readExactly(length, from: fd) else { return nil }
                    return Frame(type: header.uint32(at: 0), payload: payload)
                })
            }
        }
    }

    private static func readExactly(_ length: Int, from fd: Int32) throws -> Data? {
        var data = Data(count: length)
        return try data.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < length {
                let count = Darwin.read(fd, base.advanced(by: offset), length - offset)
                if count > 0 {
                    offset += count
                } else if count == 0 {
                    return false
                } else if errno == EAGAIN {
                    var input = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    if poll(&input, 1, -1) < 0 && errno != EINTR {
                        throw HelperError("poll fd \(fd): \(String(cString: strerror(errno)))")
                    }
                } else if errno != EINTR {
                    throw HelperError("read fd \(fd): \(String(cString: strerror(errno)))")
                }
            }
            return true
        } ? data : nil
    }
}

private extension Data {
    func uint32(at offset: Int) -> UInt32 {
        withUnsafeBytes { bytes in
            UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }
}

enum Side: UInt32, Sendable {
    case both = 0, left = 1, right = 2
}
