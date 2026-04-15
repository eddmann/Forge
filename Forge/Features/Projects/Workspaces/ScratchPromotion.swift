import Foundation

enum ScratchPromotion {
    enum Error: LocalizedError {
        case scratchNotFound
        case workspaceNotFound
        case destinationExists(String)
        case invalidName
        case moveFailed(String)
        case cloneFailed(String)

        var errorDescription: String? {
            switch self {
            case .scratchNotFound: "Scratch project not found."
            case .workspaceNotFound: "Scratch workspace not found."
            case let .destinationExists(path): "Destination already exists: \(path)"
            case .invalidName: "Project name contains invalid characters."
            case let .moveFailed(detail): "Failed to move scratch directory: \(detail)"
            case let .cloneFailed(detail): "Failed to create workspace from promoted project: \(detail)"
            }
        }
    }

    struct Result {
        let project: Project
        let workspace: WorkspaceCloner.CreateResult
    }

    /// Move the scratch directory to `<parentDir>/<finalName>/`, register it as a normal project,
    /// and create a fresh CoW workspace from its current branch.
    static func promote(
        scratch: Project,
        workspace: Workspace,
        parentDir: URL,
        finalName: String,
        progress: ((String) -> Void)? = nil,
        streamLine: ((String) -> Void)? = nil
    ) throws -> Result {
        let trimmedName = finalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !trimmedName.contains("/"),
              !trimmedName.hasPrefix(".")
        else {
            throw Error.invalidName
        }

        let destURL = parentDir.appendingPathComponent(trimmedName)
        guard !FileManager.default.fileExists(atPath: destURL.path) else {
            throw Error.destinationExists(destURL.path)
        }

        // Untrust Codex on the old path before the move; the new path will be re-trusted by the cloner.
        AgentSetup.shared.untrustCodexProject(path: workspace.path)

        progress?("Moving scratch directory…")
        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: URL(fileURLWithPath: workspace.path), to: destURL)
        } catch {
            // Best effort to restore Codex trust if the move fails.
            AgentSetup.shared.trustCodexProject(path: workspace.path)
            throw Error.moveFailed(error.localizedDescription)
        }

        let defaultBranch = Git.shared.currentBranch(in: destURL.path) ?? scratch.defaultBranch
        let project = Project(
            name: trimmedName,
            path: destURL.path,
            defaultBranch: defaultBranch
        )

        let cloneResult: WorkspaceCloner.CreateResult
        do {
            progress?("Creating workspace…")
            cloneResult = try WorkspaceCloner.createWorkspace(
                projectID: project.id,
                projectName: project.name,
                projectPath: project.path,
                parentBranch: defaultBranch,
                progress: progress,
                streamLine: streamLine
            )
        } catch {
            throw Error.cloneFailed(error.localizedDescription)
        }

        return Result(project: project, workspace: cloneResult)
    }
}
