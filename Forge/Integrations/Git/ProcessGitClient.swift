import Foundation

final class ProcessGitClient: GitClient {
    static let shared = ProcessGitClient()

    private let executableURL = URL(fileURLWithPath: "/usr/bin/git")

    private init() {}

    func run(in directory: String, args: [String]) -> GitCommandResult {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            return GitCommandResult(
                success: process.terminationStatus == 0,
                stdout: stdout,
                stderr: stderr
            )
        } catch {
            return GitCommandResult(
                success: false,
                stdout: "",
                stderr: error.localizedDescription
            )
        }
    }

    func runAsync(in directory: String, args: [String], completion: @escaping (GitCommandResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            completion(self.run(in: directory, args: args))
        }
    }

    func runWithStdin(in directory: String, args: [String], stdin stdinContent: String) -> GitCommandResult {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        do {
            try process.run()

            // Write stdin content and close
            if let data = stdinContent.data(using: .utf8) {
                inPipe.fileHandleForWriting.write(data)
            }
            inPipe.fileHandleForWriting.closeFile()

            // Read pipes concurrently before waitUntilExit to prevent deadlock
            var outData = Data()
            var errData = Data()
            let group = DispatchGroup()

            group.enter()
            DispatchQueue.global().async {
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            group.wait()
            process.waitUntilExit()

            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            return GitCommandResult(
                success: process.terminationStatus == 0,
                stdout: stdout,
                stderr: stderr
            )
        } catch {
            return GitCommandResult(
                success: false,
                stdout: "",
                stderr: error.localizedDescription
            )
        }
    }
}
