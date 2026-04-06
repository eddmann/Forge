import Darwin
import Foundation

enum WorkspaceCloner {
    struct CloneResult {
        var fullClone: Bool
    }

    struct CreateResult {
        let workspace: Workspace
        let setupFailed: LifecycleResult?
    }

    // MARK: - Create Workspace

    static func createWorkspace(
        projectID: UUID,
        projectName: String,
        projectPath: String,
        parentBranch: String,
        progress: ((String) -> Void)? = nil
    ) throws -> CreateResult {
        let existingNames = ProjectStore.shared.workspaces.map(\.name)
        let name = WorkspaceNaming.generateUnique(existing: existingNames)

        let destDirName = "\(projectName)-\(name)"
        let destPath = ForgeStore.shared.clonesDir.appendingPathComponent(destDirName).path

        progress?("Cloning repository…")
        let result = try cloneProject(source: projectPath, dest: destPath)

        // Pre-seed Codex trust for this workspace (Codex doesn't walk parent dirs)
        AgentSetup.shared.trustCodexProject(path: destPath)

        // Make the selected branch the base for the workspace branch.
        progress?("Checking out \(parentBranch)…")
        try checkoutWorkspaceBaseBranch(in: destPath, parentBranch: parentBranch)

        // Create and checkout workspace branch
        let branchName = "forge/\(name)"
        progress?("Creating branch \(branchName)…")
        let (branchExists, _) = runGitSync(in: destPath, args: ["rev-parse", "--verify", "refs/heads/\(branchName)"])
        if !branchExists {
            try runGitOrThrow(in: destPath, args: ["checkout", "-b", branchName])
        } else {
            try runGitOrThrow(in: destPath, args: ["checkout", branchName])
        }

        // Set origin to the project directory so the workspace can fetch updates
        progress?("Configuring remote…")
        setOriginToProject(projectPath: projectPath, workspacePath: destPath)

        // Read forge.json: allocate ports and run setup
        var allocatedPorts: [String: Int] = [:]
        var portDetails: [String: String] = [:]
        let config = ForgeConfig.load(from: destPath)
        if let requestedPorts = config?.ports, !requestedPorts.isEmpty {
            let result = PortAllocator.allocatePorts(
                requested: requestedPorts,
                existingClaims: [:]
            )
            allocatedPorts = result.allocated
            // Collect detail strings from port configs
            for (envVar, portConfig) in requestedPorts {
                if let detail = portConfig.detail {
                    portDetails[envVar] = detail
                }
            }
        }

        // Run setup commands with allocated ports in the environment
        var setupResult: LifecycleResult?
        if let setup = config?.workspace?.setup {
            progress?("Running setup scripts…")
            let portEnv = allocatedPorts.mapValues(String.init)
            setupResult = runLifecycleCommands(
                setup.commands, in: destPath, env: portEnv,
                workspaceName: name, projectName: projectName,
                stopOnFailure: true
            )
        }

        let workspace = Workspace(
            projectID: projectID,
            name: name,
            path: destPath,
            branch: branchName,
            parentBranch: parentBranch,
            fullClone: result.fullClone,
            allocatedPorts: allocatedPorts,
            portDetails: portDetails
        )
        return CreateResult(
            workspace: workspace,
            setupFailed: setupResult?.success == false ? setupResult : nil
        )
    }

    private static func checkoutWorkspaceBaseBranch(in repositoryPath: String, parentBranch: String) throws {
        let currentBranch = Git.shared.currentBranch(in: repositoryPath)
        if currentBranch == parentBranch {
            return
        }

        let (hasLocalBranch, _) = runGitSync(
            in: repositoryPath,
            args: ["rev-parse", "--verify", "refs/heads/\(parentBranch)"]
        )
        if hasLocalBranch {
            try runGitOrThrow(in: repositoryPath, args: ["checkout", parentBranch])
            return
        }

        let remoteRef = "refs/remotes/origin/\(parentBranch)"
        let (hasRemoteBranch, _) = runGitSync(
            in: repositoryPath,
            args: ["rev-parse", "--verify", remoteRef]
        )
        if hasRemoteBranch {
            try runGitOrThrow(
                in: repositoryPath,
                args: ["checkout", "-B", parentBranch, "origin/\(parentBranch)"]
            )
            return
        }

        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Selected branch '\(parentBranch)' was not found in the cloned repository."]
        )
    }

    // MARK: - Delete Workspace

    @discardableResult
    static func deleteWorkspace(_ workspace: Workspace, progress: ((String) -> Void)? = nil) -> LifecycleResult? {
        // Run teardown commands from forge.json before removing files
        var teardownResult: LifecycleResult?
        let portEnv = workspace.allocatedPorts.mapValues(String.init)
        let projectName = ProjectStore.shared.projects.first { $0.id == workspace.projectID }?.name
        if let config = ForgeConfig.load(from: workspace.path) {
            if let teardown = config.workspace?.teardown {
                progress?("Running teardown scripts…")
                teardownResult = runLifecycleCommands(
                    teardown.commands, in: workspace.path, env: portEnv,
                    workspaceName: workspace.name, projectName: projectName
                )
            } else if config.compose != nil {
                // Auto compose down if no explicit teardown
                progress?("Stopping docker compose…")
                let composeFile = config.compose!.file
                let fullPath = (workspace.path as NSString).appendingPathComponent(composeFile)
                if FileManager.default.fileExists(atPath: fullPath) {
                    teardownResult = runLifecycleCommands(
                        ["docker compose -f \(composeFile) down"],
                        in: workspace.path, env: portEnv,
                        workspaceName: workspace.name, projectName: projectName
                    )
                }
            }
        }

        AgentSetup.shared.untrustCodexProject(path: workspace.path)
        if FileManager.default.fileExists(atPath: workspace.path) {
            try? FileManager.default.removeItem(atPath: workspace.path)
        }
        return teardownResult?.success == false ? teardownResult : nil
    }

    // MARK: - Merge Workspace into Project

    static func mergeWorkspaceIntoProject(_ workspace: Workspace, projectPath: String) throws -> String {
        // 1. Check workspace has no uncommitted changes
        let (wsClean, wsStatus) = runGitSync(in: workspace.path, args: ["status", "--porcelain"])
        if wsClean {
            let trimmed = wsStatus.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                throw MergeError.dirtyWorkspace(workspace.name)
            }
        }

        // 2. Check project has no uncommitted changes
        let (projClean, projStatus) = runGitSync(in: projectPath, args: ["status", "--porcelain"])
        if projClean {
            let trimmed = projStatus.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                throw MergeError.dirtyProject
            }
        }

        // 3. Checkout the source branch in the project
        let currentBranch = Git.shared.currentBranch(in: projectPath) ?? ""
        if currentBranch != workspace.parentBranch {
            let (checkoutOk, checkoutOutput) = runGitSync(in: projectPath, args: ["checkout", workspace.parentBranch])
            if !checkoutOk {
                throw MergeError.checkoutFailed(workspace.parentBranch, checkoutOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        // 4. Add workspace as temp remote, fetch, merge
        let remoteName = "forge-\(workspace.name)"

        defer {
            // Always clean up the temp remote
            _ = runGitSync(in: projectPath, args: ["remote", "remove", remoteName])
        }

        try configurePathRemote(in: projectPath, name: remoteName, path: workspace.path)
        try runGitOrThrow(in: projectPath, args: ["fetch", remoteName, workspace.branch])

        let ref = "\(remoteName)/\(workspace.branch)"

        // Try fast-forward first to avoid unnecessary merge commits
        let (ffOk, _) = runGitSync(in: projectPath, args: ["merge", "--ff-only", ref])
        if ffOk {
            return "Merged '\(workspace.name)' into '\(workspace.parentBranch)'"
        }

        // Branches diverged — rebase workspace commits onto the project branch then fast-forward
        let tempBranch = "forge-rebase-\(workspace.name)"
        defer { _ = runGitSync(in: projectPath, args: ["branch", "-D", tempBranch]) }

        _ = runGitSync(in: projectPath, args: ["checkout", "-b", tempBranch, ref])
        let (rebaseOk, rebaseOutput) = runGitSync(in: projectPath, args: ["rebase", workspace.parentBranch])
        if !rebaseOk {
            _ = runGitSync(in: projectPath, args: ["rebase", "--abort"])
            _ = runGitSync(in: projectPath, args: ["checkout", workspace.parentBranch])
            throw MergeError.conflict(rebaseOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        _ = runGitSync(in: projectPath, args: ["checkout", workspace.parentBranch])
        let (mergeOk, mergeOutput) = runGitSync(in: projectPath, args: ["merge", "--ff-only", tempBranch])
        if !mergeOk {
            throw MergeError.conflict(mergeOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return "Merged '\(workspace.name)' into '\(workspace.parentBranch)'"
    }

    enum MergeError: LocalizedError {
        case dirtyWorkspace(String)
        case dirtyProject
        case checkoutFailed(String, String)
        case conflict(String)

        var errorDescription: String? {
            switch self {
            case let .dirtyWorkspace(name):
                "Workspace '\(name)' has uncommitted changes. Commit or stash them first."
            case .dirtyProject:
                "Project has uncommitted changes. Commit or stash them first."
            case let .checkoutFailed(branch, detail):
                "Failed to checkout '\(branch)': \(detail)"
            case let .conflict(detail):
                "Merge conflict — merge was aborted.\n\(detail)"
            }
        }
    }

    // MARK: - Rename Workspace

    static func renameWorkspace(_ workspace: Workspace, to newName: String) -> Workspace {
        var updated = workspace
        updated.name = newName
        return updated
    }

    // MARK: - Clone with Tiered Fallbacks

    private static func cloneProject(source: String, dest: String) throws -> CloneResult {
        guard !FileManager.default.fileExists(atPath: dest) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteFileExistsError,
                userInfo: [NSLocalizedDescriptionKey: "Destination already exists: \(dest)"]
            )
        }

        // Check if source is a git worktree (.git is a file, not a directory)
        let gitPath = (source as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        let isWorktree = FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) && !isDir.boolValue

        if !isWorktree {
            // Try APFS CoW clone via copyfile()
            if tryCopyfileClone(source: source, dest: dest) {
                return CloneResult(fullClone: false)
            }

            // Fallback: cp -c -R (macOS CoW copy)
            if tryCpCow(source: source, dest: dest) {
                return CloneResult(fullClone: false)
            }

            // Clean up any partial attempt
            try? FileManager.default.removeItem(atPath: dest)
        }

        // Final fallback: git clone
        try gitClone(source: source, dest: dest)
        return CloneResult(fullClone: true)
    }

    private static func tryCopyfileClone(source: String, dest: String) -> Bool {
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)
        let result = source.withCString { src in
            dest.withCString { dst in
                copyfile(src, dst, nil, flags)
            }
        }
        return result == 0
    }

    private static func tryCpCow(source: String, dest: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-c", "-R", source, dest]
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

    private static func gitClone(source: String, dest: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["clone", "--local", source, dest]
        process.environment = ["GIT_TERMINAL_PROMPT": "0", "PATH": ShellEnvironment.resolvedPath]
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "git clone failed: \(stderr)"]
            )
        }

        // git clone --local already sets origin to source path — no fixup needed
    }

    /// Set the workspace's origin remote to the project directory so it can fetch updates.
    private static func setOriginToProject(projectPath: String, workspacePath: String) {
        let normalizedPath = (projectPath as NSString).standardizingPath
        let (hasOrigin, _) = runGitSync(in: workspacePath, args: ["remote", "get-url", "origin"])
        if hasOrigin {
            _ = runGitSync(in: workspacePath, args: ["remote", "set-url", "origin", normalizedPath])
        } else {
            _ = runGitSync(in: workspacePath, args: ["remote", "add", "origin", normalizedPath])
        }
        // Fetch so origin/main is up to date for workspace diff
        _ = runGitSync(in: workspacePath, args: ["fetch", "origin", "--no-tags"])
    }

    // MARK: - Git Helpers

    private static func configurePathRemote(in repositoryPath: String, name: String, path: String) throws {
        let normalizedPath = (path as NSString).standardizingPath
        let (hasRemote, _) = runGitSync(in: repositoryPath, args: ["remote", "get-url", name])
        if hasRemote {
            try runGitOrThrow(in: repositoryPath, args: ["remote", "set-url", name, normalizedPath])
        } else {
            try runGitOrThrow(in: repositoryPath, args: ["remote", "add", name, normalizedPath])
        }
    }

    private static func runGitSync(in directory: String, args: [String]) -> (success: Bool, output: String) {
        let result = Git.shared.run(in: directory, args: args)
        return (result.success, result.output)
    }

    private static func runGitOrThrow(in directory: String, args: [String]) throws {
        _ = try Git.shared.runOrThrow(in: directory, args: args)
    }

    // MARK: - Lifecycle Command Helpers

    struct LifecycleResult {
        let success: Bool
        let failedCommand: String?
        let errorOutput: String?
    }

    /// Run workspace lifecycle commands (setup/teardown) synchronously.
    /// Each command runs via /bin/sh with the same environment a workspace
    /// shell would have (allocated ports, COMPOSE_PROJECT_NAME, FORGE_SOCKET, etc.).
    @discardableResult
    static func runLifecycleCommands(
        _ commands: [String],
        in directory: String,
        env: [String: String] = [:],
        workspaceName: String? = nil,
        projectName: String? = nil,
        stopOnFailure: Bool = false
    ) -> LifecycleResult {
        for command in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = URL(fileURLWithPath: directory)

            // Start from the same base environment that workspace shells use
            // (includes FORGE_SOCKET, HOME, LANG, SHELL, resolved PATH, etc.)
            var environment = ShellEnvironment.buildEnvironment()
            // Compose project name requires both workspace and project name
            if let workspaceName, let projectName {
                environment["COMPOSE_PROJECT_NAME"] = "\(projectName)-\(workspaceName)"
            }
            // Caller-provided env (typically allocated ports) wins over defaults
            for (key, value) in env {
                environment[key] = value
            }
            process.environment = environment
            process.standardOutput = Pipe()
            let errPipe = Pipe()
            process.standardError = errPipe

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if stopOnFailure {
                        return LifecycleResult(success: false, failedCommand: command, errorOutput: stderr)
                    }
                }
            } catch {
                if stopOnFailure {
                    return LifecycleResult(success: false, failedCommand: command, errorOutput: error.localizedDescription)
                }
            }
        }
        return LifecycleResult(success: true, failedCommand: nil, errorOutput: nil)
    }
}
