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

/// Snapshot of a managed process's display state for caching across workspace switches.
struct ProcessSnapshot {
    let name: String
    let command: String
    let workingDirectory: String
    let source: ManagedProcess.ProcessSource
    let status: ManagedProcess.ProcessStatus
    let outputLines: [String]
    let port: Int?
    let portDetail: String?
}

/// Manages lifecycle of processes defined in forge.json for a workspace.
class ProcessManager: ObservableObject {
    static let shared = ProcessManager()

    private struct LoadedProcessConfig {
        let processes: [ManagedProcess]
        let composeFilePath: String?
        let composeWorkingDirectory: String?
    }

    @Published var processes: [ManagedProcess] = []
    private var runningProcesses: [UUID: Process] = [:]
    private var outputPipes: [UUID: Pipe] = [:]
    private var restartCounts: [UUID: (count: Int, firstCrashTime: Date)] = [:]
    private let maxCrashesBeforeGiveUp = 5
    private let crashWindowSeconds: TimeInterval = 60

    /// Stored compose context for periodic state sync.
    private var composeFilePath: String?
    private var composeWorkingDirectory: String?
    private var dockerSyncTimer: Timer?
    private static let dockerSyncInterval: TimeInterval = 60

    /// Per-workspace cache of process snapshots (output buffers + status) keyed by workspace scope key.
    private var processCache: [String: [ProcessSnapshot]] = [:]
    /// Currently active scope key.
    private var activeScopeKey: String?

    /// Workspace context for building shell-equivalent environment.
    private var workspaceName: String?
    private var projectName: String?
    private var allocatedPorts: [String: Int] = [:]
    private var configGeneration = 0
    private let configLoadQueue = DispatchQueue(label: "forge.process-config-load", qos: .utility)

    /// Build the base environment for running processes in this workspace.
    /// Matches what a workspace shell terminal would see.
    private func workspaceEnvironment() -> [String: String] {
        var env = ShellEnvironment.buildEnvironment()
        if let workspaceName, let projectName {
            env["COMPOSE_PROJECT_NAME"] = "\(projectName)-\(workspaceName)"
        }
        for (key, port) in allocatedPorts {
            env[key] = String(port)
        }
        return env
    }

    /// Save a snapshot of the current processes for later restoration.
    func saveCurrentState() {
        guard let key = activeScopeKey, !processes.isEmpty else { return }
        processCache[key] = processes.map { proc in
            ProcessSnapshot(
                name: proc.name,
                command: proc.command,
                workingDirectory: proc.workingDirectory,
                source: proc.source,
                status: runningProcesses[proc.id] != nil ? .running : proc.status,
                outputLines: proc.outputBuffer.lines,
                port: proc.port,
                portDetail: proc.portDetail
            )
        }
    }

    /// Restore cached process snapshots for the given scope key, returning true if cache was used.
    @discardableResult
    func restoreCachedState(forKey key: String) -> Bool {
        guard let snapshots = processCache[key], !snapshots.isEmpty else { return false }
        processes = snapshots.map { snap in
            var proc = ManagedProcess(
                name: snap.name,
                command: snap.command,
                workingDirectory: snap.workingDirectory,
                source: snap.source,
                autoStart: false,
                autoRestart: false,
                env: [:]
            )
            proc.status = snap.status
            proc.outputBuffer.append(contentsOf: snap.outputLines)
            proc.port = snap.port
            proc.portDetail = snap.portDetail
            return proc
        }
        return true
    }

    /// Load processes from forge.json for the given workspace path.
    func loadConfig(from workspacePath: String, allocatedPorts: [String: Int], portDetails: [String: String] = [:], scopeKey: String? = nil, workspaceName: String? = nil, projectName: String? = nil) {
        saveCurrentState()
        stopSyncTimer()
        configGeneration += 1
        let generation = configGeneration
        activeScopeKey = scopeKey
        self.allocatedPorts = allocatedPorts
        self.workspaceName = workspaceName
        self.projectName = projectName
        let restoredCachedState = scopeKey.map { restoreCachedState(forKey: $0) } ?? false
        if !restoredCachedState {
            processes = []
        }
        composeFilePath = nil
        composeWorkingDirectory = nil

        configLoadQueue.async { [weak self] in
            guard let self else { return }
            let loadedConfig = buildLoadedConfig(
                from: workspacePath,
                allocatedPorts: allocatedPorts,
                portDetails: portDetails
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard configGeneration == generation, activeScopeKey == scopeKey else { return }
                composeFilePath = loadedConfig.composeFilePath
                composeWorkingDirectory = loadedConfig.composeWorkingDirectory
                processes = loadedConfig.processes
                syncState(expectedGeneration: generation)
                startSyncTimer()
            }
        }
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

        var environment = workspaceEnvironment()
        // Per-process env from forge.json wins over defaults
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
        guard let index = processes.firstIndex(where: { $0.id == processID }) else { return }

        // For docker compose, use docker compose stop (works for both locally- and externally-started containers)
        if processes[index].source == .docker {
            let stopProcess = Process()
            stopProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
            let serviceName = processes[index].name
            stopProcess.arguments = ["-c", "docker compose stop \(serviceName)"]
            stopProcess.currentDirectoryURL = URL(fileURLWithPath: processes[index].workingDirectory)
            stopProcess.environment = workspaceEnvironment()
            stopProcess.standardOutput = Pipe()
            stopProcess.standardError = Pipe()
            try? stopProcess.run()
            stopProcess.waitUntilExit()
        }

        if let process = runningProcesses[processID] {
            process.terminate()
            runningProcesses.removeValue(forKey: processID)
        }
        restartCounts.removeValue(forKey: processID)
        processes[index].status = .stopped
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
        saveCurrentState()
        configGeneration += 1
        stopAll()
        stopSyncTimer()
        processes.removeAll()
        restartCounts.removeAll()
        composeFilePath = nil
        composeWorkingDirectory = nil
        activeScopeKey = nil
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

    // MARK: - Process State Sync

    private func startSyncTimer() {
        stopSyncTimer()
        dockerSyncTimer = Timer.scheduledTimer(
            withTimeInterval: Self.dockerSyncInterval,
            repeats: true
        ) { [weak self] _ in
            self?.syncState(expectedGeneration: self?.configGeneration)
        }
    }

    private func stopSyncTimer() {
        dockerSyncTimer?.invalidate()
        dockerSyncTimer = nil
    }

    /// Refresh the status of all processes to match actual system state.
    func syncState() {
        syncState(expectedGeneration: configGeneration)
    }

    private func syncState(expectedGeneration: Int?) {
        syncStandaloneProcesses(expectedGeneration: expectedGeneration)
        syncDockerState(expectedGeneration: expectedGeneration)
    }

    /// Check managed standalone processes and update status if they've exited externally.
    private func syncStandaloneProcesses(expectedGeneration: Int?) {
        guard isCurrentGeneration(expectedGeneration) else { return }
        for i in processes.indices where processes[i].source == .process {
            let id = processes[i].id
            if let process = runningProcesses[id] {
                if !process.isRunning {
                    runningProcesses.removeValue(forKey: id)
                    outputPipes.removeValue(forKey: id)
                    processes[i].status = process.terminationStatus == 0 ? .stopped : .crashed
                }
            }
        }
    }

    /// Query `docker compose ps` and update docker service statuses to match actual container state.
    private func syncDockerState(expectedGeneration: Int?) {
        guard isCurrentGeneration(expectedGeneration) else { return }
        guard let composeFile = composeFilePath,
              let workDir = composeWorkingDirectory else { return }

        let env = workspaceEnvironment()
        let generation = expectedGeneration ?? configGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "docker compose -f \"\(composeFile)\" ps --format json 2>/dev/null"]
            process.currentDirectoryURL = URL(fileURLWithPath: workDir)

            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                return
            }
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard !data.isEmpty,
                  let output = String(data: data, encoding: .utf8) else { return }

            // Parse running service names from JSON output.
            // docker compose ps --format json outputs one JSON object per line.
            var runningServices: Set<String> = []
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("{") else { continue }
                guard let lineData = trimmed.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let service = obj["Service"] as? String,
                      let state = obj["State"] as? String else { continue }
                if state == "running" {
                    runningServices.insert(service)
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                guard self.isCurrentGeneration(generation),
                      self.composeFilePath == composeFile,
                      self.composeWorkingDirectory == workDir
                else { return }
                for i in self.processes.indices where self.processes[i].source == .docker {
                    let name = self.processes[i].name
                    let managedByUs = self.runningProcesses[self.processes[i].id] != nil

                    if runningServices.contains(name) {
                        if self.processes[i].status != .running {
                            self.processes[i].status = .running
                        }
                    } else if !managedByUs {
                        if self.processes[i].status == .running {
                            self.processes[i].status = .stopped
                        }
                    }
                }
            }
        }
    }

    private func buildLoadedConfig(from workspacePath: String, allocatedPorts: [String: Int], portDetails: [String: String]) -> LoadedProcessConfig {
        guard let config = ForgeConfig.load(from: workspacePath) else {
            return LoadedProcessConfig(processes: [], composeFilePath: nil, composeWorkingDirectory: nil)
        }

        var loaded: [ManagedProcess] = []
        var composeFilePath: String?
        var composeWorkingDirectory: String?

        if let processConfigs = config.processes {
            for (name, processConfig) in processConfigs.sorted(by: { $0.key < $1.key }) {
                let dir = if let relativeDir = processConfig.dir {
                    (workspacePath as NSString).appendingPathComponent(relativeDir)
                } else {
                    workspacePath
                }

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

        if let compose = config.compose {
            let resolvedComposeFile = (workspacePath as NSString).appendingPathComponent(compose.file)
            if FileManager.default.fileExists(atPath: resolvedComposeFile) {
                composeFilePath = resolvedComposeFile
                composeWorkingDirectory = workspacePath

                let services = discoverComposeServices(at: resolvedComposeFile, filter: compose.services)
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
                    proc.port = nil
                    loaded.append(proc)
                }
            }
        }

        return LoadedProcessConfig(
            processes: loaded,
            composeFilePath: composeFilePath,
            composeWorkingDirectory: composeWorkingDirectory
        )
    }

    private func isCurrentGeneration(_ generation: Int?) -> Bool {
        guard let generation else { return true }
        return generation == configGeneration
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
