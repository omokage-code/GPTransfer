import Darwin
import Foundation

@main
struct CameraTransferAutoLauncher {
    static func main() async {
        guard CommandLine.arguments.count >= 2 else {
            return
        }

        let appPath = CommandLine.arguments[1]
        let stateFile = stateFileURL()
        let connectionSignature = cameraConnectionSignature()

        if let connectionSignature {
            try? FileManager.default.createDirectory(
                at: stateFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            guard !isMainAppRunning() else {
                try? connectionSignature.write(to: stateFile, atomically: true, encoding: .utf8)
                return
            }

            if let previousSignature = try? String(contentsOf: stateFile, encoding: .utf8),
               previousSignature == connectionSignature {
                openApp(at: appPath)
                return
            }

            try? connectionSignature.write(to: stateFile, atomically: true, encoding: .utf8)
            openApp(at: appPath)
        } else {
            try? FileManager.default.removeItem(at: stateFile)
        }
    }

    private static func stateFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GPTransfer", isDirectory: true)
            .appendingPathComponent("auto-launch-camera-present")
    }

    private static func cameraConnectionSignature() -> String? {
        let candidates = localIPv4Addresses().filter { address in
            let parts = address.split(separator: ".")
            return parts.count == 4 && parts[0] == "172" && parts[3] != "51"
        }
        guard !candidates.isEmpty else {
            return nil
        }
        return candidates.sorted().joined(separator: "\n")
    }

    private static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return []
        }
        defer { freeifaddrs(interfaces) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP,
                  let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            let status = getnameinfo(
                address,
                length,
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if status == 0 {
                let bytes = hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                result.append(String(decoding: bytes, as: UTF8.self))
            }
        }
        return result
    }

    private static func isMainAppRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-x", "GoProUsbTransferTestApp"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func openApp(at appPath: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = [appPath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }
}
