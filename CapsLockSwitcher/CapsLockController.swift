import IOKit.hidsystem

final class CapsLockController {
    private var connection: io_connect_t = 0

    init() {
        open()
    }

    deinit {
        close()
    }

    var isOn: Bool? {
        var enabled = false
        let result = withConnection { IOHIDGetModifierLockState($0, Int32(kIOHIDCapsLockState), &enabled) }
        return result == KERN_SUCCESS ? enabled : nil
    }

    func set(_ enabled: Bool) -> kern_return_t {
        withConnection { IOHIDSetModifierLockState($0, Int32(kIOHIDCapsLockState), enabled) }
    }

    func toggle() -> kern_return_t {
        guard let enabled = isOn else { return kIOReturnNotOpen }
        return set(!enabled)
    }

    /// Runs `body` on the IOHIDSystem connection, reopening it once if it went stale.
    private func withConnection(_ body: (io_connect_t) -> kern_return_t) -> kern_return_t {
        if connection == 0 { open() }
        guard connection != 0 else { return kIOReturnNotOpen }
        let result = body(connection)
        guard result != KERN_SUCCESS else { return result }
        close()
        open()
        guard connection != 0 else { return result }
        return body(connection)
    }

    private func open() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) != KERN_SUCCESS {
            connection = 0
        }
    }

    private func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }
}
