import Combine
import Darwin
import Dispatch
import Foundation

/// Watches the `.git/HEAD` file of every known project and workspace. When HEAD
/// changes (branch switch, commit, rebase) the watcher debounces briefly and
/// bumps `ProjectStore.gitRefreshTrigger` so sidebar/inspector views re-fetch
/// the current branch and dirty state without requiring a manual refresh.
///
/// One `DispatchSourceFileSystemObject` per repo HEAD with debounced events
/// and auto-restart on delete/rename (git replaces HEAD atomically during many
/// operations, which detaches the source from the old inode).
@MainActor
final class WorkspaceGitWatcher {
    static let shared = WorkspaceGitWatcher()

    /// Identifies a single watch root by its absolute path so we can dedupe
    /// projects and workspaces by their on-disk location.
    private struct Watcher {
        let headPath: String
        let source: DispatchSourceFileSystemObject
        let fileDescriptor: Int32
    }

    private var watchers: [String: Watcher] = [:]
    private var debounceTasks: [String: DispatchWorkItem] = [:]
    private var restartTasks: [String: DispatchWorkItem] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private let debounceInterval: TimeInterval = 0.25
    private let restartDelay: TimeInterval = 1.0

    private init() {}

    /// Wire watcher set to ProjectStore's published arrays. Called once on app launch.
    func start(store: ProjectStore) {
        Publishers.CombineLatest(store.$projects, store.$workspaces)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] projects, workspaces in
                self?.sync(projectPaths: projects.map(\.path), workspacePaths: workspaces.map(\.path))
            }
            .store(in: &cancellables)
    }

    // MARK: - Sync

    private func sync(projectPaths: [String], workspacePaths: [String]) {
        let desired = Set(projectPaths + workspacePaths)
        let current = Set(watchers.keys)

        for path in current.subtracting(desired) {
            stopWatcher(forRoot: path)
        }
        for path in desired.subtracting(current) {
            startWatcher(forRoot: path)
        }
    }

    // MARK: - Lifecycle

    private func startWatcher(forRoot rootPath: String) {
        guard let headPath = headFilePath(forRoot: rootPath) else { return }
        let fd = open(headPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let queue = DispatchQueue(label: "forge.git-head-watcher", qos: .utility)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: queue
        )

        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            let event = source.data
            DispatchQueue.main.async {
                self?.handleEvent(rootPath: rootPath, event: event)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()

        watchers[rootPath] = Watcher(headPath: headPath, source: source, fileDescriptor: fd)
    }

    private func stopWatcher(forRoot rootPath: String) {
        if let watcher = watchers.removeValue(forKey: rootPath) {
            watcher.source.cancel()
        }
        debounceTasks.removeValue(forKey: rootPath)?.cancel()
        restartTasks.removeValue(forKey: rootPath)?.cancel()
    }

    // MARK: - Events

    private func handleEvent(rootPath: String, event: DispatchSource.FileSystemEvent) {
        // git often replaces HEAD atomically (write to tmp, rename) — when our
        // watched inode is renamed/deleted we must reopen against the new file.
        if event.contains(.delete) || event.contains(.rename) {
            if let watcher = watchers.removeValue(forKey: rootPath) {
                watcher.source.cancel()
            }
            scheduleRestart(rootPath: rootPath)
        }
        scheduleRefresh(rootPath: rootPath)
    }

    private func scheduleRefresh(rootPath: String) {
        debounceTasks[rootPath]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.debounceTasks.removeValue(forKey: rootPath)
            ProjectStore.shared.requestGitRefresh()
        }
        debounceTasks[rootPath] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    private func scheduleRestart(rootPath: String) {
        restartTasks[rootPath]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            restartTasks.removeValue(forKey: rootPath)
            // Only restart if the root is still desired (still in watchers map
            // would be wrong — we just removed it; check ProjectStore instead).
            let stillTracked = ProjectStore.shared.projects.contains { $0.path == rootPath }
                || ProjectStore.shared.workspaces.contains { $0.path == rootPath }
            guard stillTracked, watchers[rootPath] == nil else { return }
            startWatcher(forRoot: rootPath)
        }
        restartTasks[rootPath] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay, execute: item)
    }

    // MARK: - Helpers

    /// Resolve the actual HEAD file for a repo root. Handles linked git worktrees
    /// (where `.git` is a file pointing to `.git/worktrees/<name>`), though
    /// Forge's CoW workspaces always have a regular `.git/` directory.
    private func headFilePath(forRoot rootPath: String) -> String? {
        let dotGit = (rootPath as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else {
            return nil
        }
        if isDir.boolValue {
            let head = (dotGit as NSString).appendingPathComponent("HEAD")
            return FileManager.default.fileExists(atPath: head) ? head : nil
        }
        // `.git` is a file — parse `gitdir: <path>` to find the real git dir.
        guard let contents = try? String(contentsOfFile: dotGit, encoding: .utf8) else {
            return nil
        }
        let prefix = "gitdir:"
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            var gitDir = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !gitDir.hasPrefix("/") {
                gitDir = (rootPath as NSString).appendingPathComponent(gitDir)
            }
            let head = (gitDir as NSString).appendingPathComponent("HEAD")
            return FileManager.default.fileExists(atPath: head) ? head : nil
        }
        return nil
    }
}
