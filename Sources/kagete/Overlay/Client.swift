import Darwin
import Foundation

/// Fire-and-forget client for the overlay daemon. Failures are swallowed —
/// the overlay is an awareness affordance, never a critical path.
enum OverlayClient {
    static func notify(_ msg: OverlayMessage) {
        guard isEnabled else { return }

        if connectAndSend(msg) { return }
        // Socket dead — spawn daemon, retry briefly.
        spawnDaemon()
        for _ in 0..<20 {   // up to ~200ms of retries
            usleep(10_000)
            if connectAndSend(msg) { return }
        }
    }

    /// Synchronous round-trip — used by `overlay status`, which wants a reply.
    static func query(_ msg: OverlayMessage) -> String? {
        guard isEnabled else { return nil }
        let fd = openSocket()
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard write(fd: fd, OverlayWire.encode(msg)) else { return nil }
        return OverlayWire.readLine(fd: fd)
    }

    static var isEnabled: Bool {
        if let v = ProcessInfo.processInfo.environment["KAGETE_OVERLAY"] {
            return v != "0" && v.lowercased() != "false"
        }
        return true
    }

    // MARK: - Internals

    private static func connectAndSend(_ msg: OverlayMessage) -> Bool {
        let fd = openSocket()
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return write(fd: fd, OverlayWire.encode(msg))
    }

    private static func openSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = OverlayConfig.socketPath
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd); return -1
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: Int8.self, capacity: pathBytes.count) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = Int8(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        if ok != 0 { close(fd); return -1 }
        return fd
    }

    private static func write(fd: Int32, _ data: Data) -> Bool {
        var remaining = data
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBytes { buf -> Int in
                Darwin.write(fd, buf.baseAddress, remaining.count)
            }
            if n <= 0 { return false }
            remaining.removeFirst(n)
        }
        return true
    }

    private static func spawnDaemon() {
        let exe = ProcessInfo.processInfo.arguments.first
            ?? "/usr/local/bin/kagete"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = ["_overlay-daemon"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { /* ignore */ }
    }
}

enum OverlayWire {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
    static let decoder = JSONDecoder()

    static func encode(_ msg: OverlayMessage) -> Data {
        var data = (try? encoder.encode(msg)) ?? Data()
        data.append(0x0A)   // newline delimiter
        return data
    }

    static func decode(_ data: Data) -> OverlayMessage? {
        try? decoder.decode(OverlayMessage.self, from: data)
    }

    /// Read one newline-terminated UTF-8 line from a raw fd. Returns nil on EOF/error.
    static func readLine(fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &byte, 1)
            if n <= 0 { return bytes.isEmpty ? nil : String(bytes: bytes, encoding: .utf8) }
            if byte == 0x0A { return String(bytes: bytes, encoding: .utf8) }
            bytes.append(byte)
            if bytes.count > 64_000 { return nil }
        }
    }
}
