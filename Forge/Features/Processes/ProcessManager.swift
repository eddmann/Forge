import Combine
import Foundation

// MARK: - Managed Process

/// Represents a running or configured process from forge.json or Docker Compose.
struct ManagedProcess: Identifiable {
    let id = UUID()
    let name: String
    let command: String
    let workingDirectory: String
    let source: ProcessSource
    let autoStart: Bool
    let autoRestart: Bool
    let env: [String: String]
    var port: Int?
    var portDetail: String?

    var status: ProcessStatus = .stopped
    var outputBuffer: RingBuffer<String> = RingBuffer(capacity: 1000)

    enum ProcessSource: String {
        case process
        case docker
    }

    enum ProcessStatus: String {
        case running
        case stopped
        case crashed
    }
}

/// Fixed-capacity ring buffer for process output lines.
struct RingBuffer<Element> {
    private var storage: [Element] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func append(_ element: Element) {
        if storage.count >= capacity {
            storage.removeFirst()
        }
        storage.append(element)
    }

    mutating func append(contentsOf elements: [Element]) {
        for element in elements {
            append(element)
        }
    }

    var lines: [Element] {
        storage
    }

    var count: Int {
        storage.count
    }

    var isEmpty: Bool {
        storage.isEmpty
    }

    mutating func clear() {
        storage.removeAll()
    }
}

// MARK: - Process Manager

/// Manages lifecycle of processes defined in forge.json for a workspace.
class ProcessManager: ObservableObject {
    static let shared = ProcessManager()

    @Published var processes: [ManagedProcess] = []
    private var runningProcesses: [UUID: Process] = [:]
    private var outputPipes: [UUID: Pipe] = [:]
    private var restartCounts: [UUID: (count: Int, firstCrashTime: Date)] = [:]
    private let maxCrashesBeforeGiveUp = 5
    private let crashWindowSeconds: TimeInterval = 60

    /// Load processes from forge.json for the given workspace path.
    func loadConfig(from workspacePath: String, allocatedPorts: [String: Int], portDetails: [String: String] = [:]) {
        var loaded: [ManagedProcess] = []

        guard let config = ForgeConfig.load(from: workspacePath) else {
            processes = []
            return
        }

        // Standalone processes
        if let processConfigs = config.processes {
            for (name, processConfig) in processConfigs.sorted(by: { $0.key < $1.key }) {
                let dir = if let relativeDir = processConfig.dir {
                    (workspacePath as NSString).appendingPathComponent(relativeDir)
                } else {
                    workspacePath
                }

                // Resolve which port this process uses by checking its env vars against allocated ports
                let resolved = resolvePort(for: processConfig, allocatedPorts: allocatedPorts, portDetails: portDetails)

                var proc = ManagedProcess(
                    name: name,
                    command: processConfig.command,
                    workingDirectory: dir,
                    source: .process,
                    autoStart: processConfig.autoStart,
                    autoRestart: processConfig.autoRestart,
                    env: processConfig.env ?? [:]
                )
                proc.port = resolved?.port
                proc.portDetail = resolved?.detail
                loaded.append(proc)
            }
        }

        // Docker Compose services
        if let compose = config.compose {
            let composeFile = (workspacePath as NSString).appendingPathComponent(compose.file)
            if FileManager.default.fileExists(atPath: composeFile) {
                let services = discoverComposeServices(at: composeFile, filter: compose.services)
                for service in services {
                    var proc = ManagedProcess(
                        name: service,
                        command: "docker compose -f \(compose.file) up \(service)",
                        workingDirectory: workspacePath,
                        source: .docker,
                        autoStart: compose.autoStart,
                        autoRestart: false,
                        env: [:]
                    )
                    // Try to find a port for this service from allocated ports
                    proc.port = nil // Docker ports resolved at runtime
                    loaded.append(proc)
                }
            }
        }

        processes = loaded
    }

    /// Start a specific process by ID.
    func start(_ processID: UUID) {
        guard let index = processes.firstIndex(where: { $0.id == processID }),
              processes[index].status != .running else { return }

        let managed = processes[index]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", managed.command]
        process.currentDirectoryURL = URL(fileURLWithPath: managed.workingDirectory)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ShellEnvironment.resolvedPath
        for (key, value) in managed.env {
            environment[key] = value
        }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        outputPipes[processID] = pipe

        // Read output asynchronously
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            let newLines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
            DispatchQueue.main.async {
                guard let self,
                      let idx = self.processes.firstIndex(where: { $0.id == processID }) else { return }
                self.processes[idx].outputBuffer.append(contentsOf: newLines)
            }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self,
                      let idx = self.processes.firstIndex(where: { $0.id == processID }) else { return }
                self.runningProcesses.removeValue(forKey: processID)
                self.outputPipes.removeValue(forKey: processID)

                if proc.terminationStatus != 0, self.processes[idx].autoRestart {
                    self.processes[idx].status = .crashed
                    self.handleAutoRestart(processID)
                } else {
                    self.processes[idx].status = .stopped
                }
            }
        }

        do {
            try process.run()
            runningProcesses[processID] = process
            processes[index].status = .running
        } catch {
            processes[index].status = .crashed
            processes[index].outputBuffer.append("Failed to start: \(error.localizedDescription)")
        }
    }

    /// Stop a specific process by ID.
    func stop(_ processID: UUID) {
        guard let process = runningProcesses[processID] else { return }

        // For docker compose, use docker compose stop
        if let index = processes.firstIndex(where: { $0.id == processID }),
           processes[index].source == .docker
        {
            let stopProcess = Process()
            stopProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
            let serviceName = processes[index].name
            stopProcess.arguments = ["-c", "docker compose stop \(serviceName)"]
            stopProcess.currentDirectoryURL = URL(fileURLWithPath: processes[index].workingDirectory)
            stopProcess.environment = ["PATH": ShellEnvironment.resolvedPath]
            stopProcess.standardOutput = Pipe()
            stopProcess.standardError = Pipe()
            try? stopProcess.run()
            stopProcess.waitUntilExit()
        }

        process.terminate()
        runningProcesses.removeValue(forKey: processID)
        restartCounts.removeValue(forKey: processID)

        if let index = processes.firstIndex(where: { $0.id == processID }) {
            processes[index].status = .stopped
        }
    }

    /// Restart a specific process.
    func restart(_ processID: UUID) {
        stop(processID)
        restartCounts.removeValue(forKey: processID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.start(processID)
        }
    }

    /// Start all processes marked with autoStart.
    func startAutoStartProcesses() {
        for process in processes where process.autoStart && process.status != .running {
            start(process.id)
        }
    }

    /// Stop all running processes.
    func stopAll() {
        for process in processes where process.status == .running {
            stop(process.id)
        }
    }

    /// Clear all processes (e.g. when switching workspaces).
    func clear() {
        stopAll()
        processes.removeAll()
        restartCounts.removeAll()
    }

    // MARK: - Auto-Restart

    private func handleAutoRestart(_ processID: UUID) {
        let now = Date()

        if let info = restartCounts[processID] {
            // Check if we're within the crash window
            if now.timeIntervalSince(info.firstCrashTime) < crashWindowSeconds {
                if info.count >= maxCrashesBeforeGiveUp {
                    // Too many crashes, give up
                    if let idx = processes.firstIndex(where: { $0.id == processID }) {
                        processes[idx].outputBuffer.append("Process crashed too many times, giving up on auto-restart.")
                    }
                    restartCounts.removeValue(forKey: processID)
                    return
                }
                restartCounts[processID] = (count: info.count + 1, firstCrashTime: info.firstCrashTime)
            } else {
                // Outside crash window, reset counter
                restartCounts[processID] = (count: 1, firstCrashTime: now)
            }
        } else {
            restartCounts[processID] = (count: 1, firstCrashTime: now)
        }

        let crashCount = restartCounts[processID]?.count ?? 1
        // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s cap
        let delay = min(pow(2.0, Double(crashCount - 1)), 30.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.start(processID)
        }
    }

    // MARK: - Compose Discovery

    /// Parse a Docker Compose file to extract service names.
    private func discoverComposeServices(at path: String, filter: [String]?) -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return [] }

        // Simple YAML parsing: find lines matching "  servicename:" under "services:"
        var services: [String] = []
        var inServices = false
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "services:" || trimmed.hasPrefix("services:") {
                inServices = true
                continue
            }
            if inServices {
                // A service name is a line with exactly 2-space indent ending with ":"
                if line.hasPrefix("  "), !line.hasPrefix("    "),
                   trimmed.hasSuffix(":"), !trimmed.hasPrefix("#")
                {
                    let name = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        services.append(name)
                    }
                }
                // Another top-level key means we left services
                if !line.hasPrefix(" "), !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                    break
                }
            }
        }

        if let filter {
            return services.filter { filter.contains($0) }
        }
        return services
    }

    // MARK: - Port Resolution

    /// Try to determine which allocated port a process would use
    /// by checking env var names referenced in its command or env config.
    private func resolvePort(
        for config: ProcessConfig,
        allocatedPorts: [String: Int],
        portDetails: [String: String]
    ) -> (port: Int, detail: String?)? {
        // Check if any allocated port env vars appear in the process's extra env
        if let processEnv = config.env {
            for (envVar, port) in allocatedPorts {
                if processEnv.keys.contains(envVar) {
                    return (port, portDetails[envVar])
                }
            }
        }

        // Check if the command references a port env var (e.g. $PORT or ${PORT})
        let command = config.command
        for (envVar, port) in allocatedPorts {
            if command.contains("$\(envVar)") || command.contains("${\(envVar)}") {
                return (port, portDetails[envVar])
            }
        }

        return nil
    }
}
