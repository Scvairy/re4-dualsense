import CoreHID
import Foundation
import Tactile

@MainActor
final class OutputConnection {
    let deviceID: UInt64
    private let client: HIDDeviceClient
    private var builder: OutputReportBuilder

    init(info: DeviceInfo, reference: HIDDeviceClient.DeviceReference) throws {
        guard InputMonitoringPermission.status != .denied else {
            throw TransportError.inputMonitoringDenied
        }
        guard let client = HIDDeviceClient(deviceReference: reference) else {
            throw InputMonitoringPermission.status == .granted
                ? TransportError.deviceUnavailable : TransportError.inputMonitoringDenied
        }
        // Opening Tactile's DeviceConnection starts input monitoring and reads
        // calibration, which enables full Bluetooth input reports. This client
        // is shared and only issues output requests.
        self.client = client
        deviceID = info.deviceID
        builder = OutputReportBuilder(features: .resolve(model: info.model, firmware: nil))
    }

    func restoreAudioMode() async throws {
        try await send(builder.build(OutputState(), transport: .bluetooth))
    }

    func neutralize() async {
        try? await send(builder.build(.neutral(), transport: .bluetooth))
    }

    func send(_ report: [UInt8]) async throws {
        guard let id = report.first.flatMap(HIDReportID.init(rawValue:)),
              CRC32.verify(report, prefix: .output) else {
            throw TransportError.notSupported("invalid Bluetooth output report")
        }
        do {
            // The pump also uses a separate 100 ms watchdog for missing completions.
            try await client.dispatchSetReportRequest(type: .output, id: id, data: Data(report),
                                                      timeout: .milliseconds(250))
        } catch HIDDeviceError.timeout, HIDDeviceError.notResponding {
            throw TransportError.timeout
        }
    }
}
