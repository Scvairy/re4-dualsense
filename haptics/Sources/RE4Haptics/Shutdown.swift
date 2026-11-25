import Darwin
import Dispatch

@MainActor
func exitAfterControllerCleanup(status: Int32, cleanup: () async -> Void) async -> Never {
    // A pending HID request can also hold up discovery or neutral output.
    // Enforce the process deadline independently of those async operations.
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(200)) {
        _exit(status)
    }
    await cleanup()
    exit(status)
}
