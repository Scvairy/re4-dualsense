import AudioToolbox
import CoreAudio
import Foundation
import IOKit
import IOKit.hid
import os

// Wired DualSense haptics. Over USB the controller is a 4-channel audio device:
// channels 1-2 drive the speaker and 3-4 drive the left and right actuators.
// macOS keeps the controller in emulated-rumble mode, which ignores channels
// 3-4, so an all-zero output report 0x02 clears those flags first. That report
// leaves the lightbar, triggers and audio settings alone. Approach from
// https://github.com/seedds/nxnative/pull/1993 (tested on macOS 27).
final class USBOutput: @unchecked Sendable {
    static let sampleRate = 48_000.0
    private static let channels = 4
    private static let maxVoices = 16

    let audioDevice: AudioDeviceID
    private var unit: AudioUnit?
    private var hid: IOHIDDevice?
    private let voices = OSAllocatedUnfairLock(initialState: [Track]())
    private let rendered = OSAllocatedUnfairLock(initialState: (callbacks: 0, frames: 0))

    // Finds exactly one wired DualSense or DualSense Edge audio device.
    static func findDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return nil }
        let matches = ids.filter { id in
            guard uint32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeUSB,
                  outputChannels(id) == channels,
                  string(id, kAudioObjectPropertyManufacturer)?.hasPrefix("Sony") == true,
                  let name = string(id, kAudioObjectPropertyName) else { return false }
            return name == "DualSense Wireless Controller" || name == "DualSense Edge Wireless Controller"
        }
        return matches.count == 1 ? matches[0] : nil
    }

    init(device: AudioDeviceID) throws {
        audioDevice = device
        hid = try Self.openHID(matching: device)
        enableAudioHaptics()
        do {
            try startAudio()
        } catch {
            close()
            throw error
        }
    }

    // Sends the all-zero output report. Call again whenever another process
    // may have changed the controller's output state.
    @discardableResult
    func enableAudioHaptics() -> Bool {
        guard let hid else { return false }
        var report = [UInt8](repeating: 0, count: 48)
        report[0] = 0x02
        return IOHIDDeviceSetReport(hid, kIOHIDReportTypeOutput, 0x02, report, report.count) == kIOReturnSuccess
    }

    func play(_ track: Track) {
        voices.withLock { voices in
            if voices.count >= Self.maxVoices { voices.removeFirst() }
            voices.append(track)
        }
    }

    func stopAll() {
        voices.withLock { $0.removeAll() }
    }

    var voiceCount: Int { voices.withLock { $0.count } }

    var metrics: String {
        let (callbacks, frames) = rendered.withLock { $0 }
        return "usb callbacks=\(callbacks) frames=\(frames) voices=\(voiceCount)"
    }

    func close() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
        if let hid {
            IOHIDDeviceClose(hid, IOOptionBits(kIOHIDOptionsTypeNone))
            self.hid = nil
        }
        stopAll()
    }

    // Called on the audio thread: channels 1-2 stay silent, the mixed left and
    // right track channels go to 3 and 4.
    fileprivate func render(_ output: UnsafeMutablePointer<Float>, frames: Int) {
        let count = frames * Self.channels
        output.initialize(repeating: 0, count: count)
        let mixed = voices.withLock { voices in
            var mixed = [Float](repeating: 0, count: frames * 2)
            for index in voices.indices { voices[index].mix(into: &mixed) }
            voices.removeAll { $0.remainingSamples == 0 }
            return mixed
        }
        for frame in 0..<frames {
            output[frame * Self.channels + 2] = max(-1, min(1, mixed[frame * 2]))
            output[frame * Self.channels + 3] = max(-1, min(1, mixed[frame * 2 + 1]))
        }
        rendered.withLock { $0.callbacks += 1; $0.frames += frames }
    }

    private func startAudio() throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple,
                                                    componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw HelperError("no audio output unit")
        }
        var created: AudioUnit?
        try check(AudioComponentInstanceNew(component, &created), "create audio unit")
        guard let unit = created else { throw HelperError("no audio unit") }
        self.unit = unit

        var off: UInt32 = 0, on: UInt32 = 1, device = audioDevice
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                       &off, UInt32(MemoryLayout<UInt32>.size)), "disable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                       &on, UInt32(MemoryLayout<UInt32>.size)), "enable output")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &device, UInt32(MemoryLayout<AudioDeviceID>.size)), "select device")
        // A short device buffer keeps the trigger-to-actuator delay low.
        var bufferFrames: UInt32 = 128
        var bufferAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectSetPropertyData(audioDevice, &bufferAddress, 0, nil,
                                       UInt32(MemoryLayout<UInt32>.size), &bufferFrames)

        let bytesPerFrame = UInt32(Self.channels * MemoryLayout<Float>.size)
        var format = AudioStreamBasicDescription(mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
                                                 mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1,
                                                 mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: UInt32(Self.channels),
                                                 mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                       &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set format")
        var map: [Int32] = [0, 1, 2, 3]
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 0,
                                       &map, UInt32(map.count * MemoryLayout<Int32>.size)), "set channel map")
        var callback = AURenderCallbackStruct(inputProc: usbRender,
                                              inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set callback")
        try check(AudioUnitInitialize(unit), "initialize audio unit")
        try check(AudioOutputUnitStart(unit), "start audio unit")
    }

    // The audio device UID ends in the USB location ID, which the matching HID
    // device also reports. Only that device receives the output report.
    private static func openHID(matching device: AudioDeviceID) throws -> IOHIDDevice {
        guard let uid = string(device, kAudioDevicePropertyDeviceUID) else { throw HelperError("no audio device UID") }
        let parts = uid.split(separator: ":")
        guard parts.count >= 5, parts[0] == "AppleUSBAudioEngine",
              let location = UInt32(parts[parts.count - 2], radix: 16), location != 0 else {
            throw HelperError("unexpected audio device UID \(uid)")
        }
        guard let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary? else {
            throw HelperError("cannot match HID devices")
        }
        matching[kIOHIDVendorIDKey] = 0x054c
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            throw HelperError("cannot list HID devices")
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let hid = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
            let product = IOHIDDeviceGetProperty(hid, kIOHIDProductIDKey as CFString) as? Int
            let hidLocation = IOHIDDeviceGetProperty(hid, kIOHIDLocationIDKey as CFString) as? Int
            guard product == 0x0ce6 || product == 0x0df2, hidLocation.map(UInt32.init) == location else { continue }
            let result = IOHIDDeviceOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
            guard result == kIOReturnSuccess else {
                throw HelperError(String(format: "cannot open the USB DualSense (0x%08x); grant Input Monitoring", result))
            }
            return hid
        }
        throw HelperError("no HID device at USB location \(String(location, radix: 16))")
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func outputChannels(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

private func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw HelperError("\(what) failed (\(status))") }
}

private func usbRender(_ refCon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                       _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                       _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let output = Unmanaged<USBOutput>.fromOpaque(refCon).takeUnretainedValue()
    guard let data, let buffer = UnsafeMutableAudioBufferListPointer(data).first,
          buffer.mNumberChannels == 4, let samples = buffer.mData?.assumingMemoryBound(to: Float.self),
          Int(buffer.mDataByteSize) >= Int(frames) * 4 * MemoryLayout<Float>.size else {
        return kAudioUnitErr_FormatNotSupported
    }
    output.render(samples, frames: Int(frames))
    return noErr
}
