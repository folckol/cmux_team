import Foundation

/// Manages the lifecycle of the cmuxd-context Go daemon process.
/// Launches on app start, monitors for crashes, and shuts down on app termination.
@MainActor
final class ContextDaemonLifecycle: ObservableObject {

    @Published var isRunning: Bool = false
    @Published var lastError: String?

    private var process: Process?
    private var socketPath: String
    private var dbPath: String
    private var daemonBinaryPath: String?

    init(socketPath: String? = nil, dbPath: String? = nil) {
        self.socketPath = socketPath ?? ContextDaemonLifecycle.defaultSocketPath()
        self.dbPath = dbPath ?? ContextDaemonLifecycle.defaultDBPath()
        self.daemonBinaryPath = ContextDaemonLifecycle.findDaemonBinary()
    }

    // MARK: - Lifecycle

    func start() {
        guard let binaryPath = daemonBinaryPath else {
            lastError = "cmuxd-context binary not found"
            return
        }

        guard !isRunning else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = [
            "-socket", socketPath,
            "-db", dbPath
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.isRunning = false
                // Auto-restart on unexpected termination
                if process.terminationStatus != 0 && process.terminationStatus != 15 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.start()
                    }
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
            self.isRunning = true
            self.lastError = nil
        } catch {
            self.lastError = "Failed to start daemon: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        process = nil
        isRunning = false

        // Clean up stale socket
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - Binary discovery

    static func findDaemonBinary() -> String? {
        let candidates = [
            // Built alongside the app
            Bundle.main.bundlePath + "/Contents/Resources/cmuxd-context",
            Bundle.main.bundlePath + "/Contents/MacOS/cmuxd-context",
            // Development locations
            "/usr/local/bin/cmuxd-context",
            NSHomeDirectory() + "/.local/bin/cmuxd-context",
            // Built from source
            NSHomeDirectory() + "/PycharmProjects/cmux_team/daemon/context/cmuxd-context",
            "/tmp/cmuxd-context",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    // MARK: - Default paths

    static func defaultSocketPath() -> String {
        if let env = ProcessInfo.processInfo.environment["CMUX_CONTEXT_SOCKET_PATH"] {
            return env
        }
        return NSHomeDirectory() + "/.config/cmux/context.sock"
    }

    static func defaultDBPath() -> String {
        if let env = ProcessInfo.processInfo.environment["CMUX_CONTEXT_DB_PATH"] {
            return env
        }
        return NSHomeDirectory() + "/.config/cmux/context.db"
    }
}
