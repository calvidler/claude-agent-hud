import Foundation

// MARK: - Shell

enum Shell {
    /// Runs a command to completion and returns its exit status and stdout.
    @discardableResult
    static func run(
        _ path: String, _ arguments: [String],
        environment: [String: String]? = nil, input: String? = nil,
        currentDirectory: String? = nil, timeout: TimeInterval = 30
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        let stdin = Pipe()
        process.standardInput = stdin
        guard (try? process.run()) != nil else { return (-1, "") }
        // A hung child would otherwise block its caller forever (and, for the
        // session poll, stop the HUD updating).
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
