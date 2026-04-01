import Foundation

/// Connects to an OpenCode HTTP/SSE server running alongside the TUI.
/// Receives real-time events and can send control commands (abort, approve, answer).
@MainActor
class OpenCodeClient {
    let port: Int
    let tabID: UUID
    private var eventTask: Task<Void, Never>?
    private var connected = false
    private var retryCount = 0
    private let maxRetries = 30  // 30 retries × 2s = 60s max wait for OpenCode to start

    init(port: Int, tabID: UUID) {
        self.port = port
        self.tabID = tabID
    }

    // MARK: - SSE Connection

    func connect() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in
            await self?.eventLoop()
        }
    }

    func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        connected = false
        retryCount = 0
    }

    private func eventLoop() async {
        while !Task.isCancelled, retryCount < maxRetries {
            do {
                try await streamEvents()
            } catch {
                connected = false
                retryCount += 1
                // Backoff: 2s between retries
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func streamEvents() async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/event")!
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 300  // Long-lived SSE connection

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        connected = true
        retryCount = 0

        var eventType = ""
        var dataBuffer = ""

        for try await line in bytes.lines {
            if Task.isCancelled { break }

            if line.isEmpty {
                // End of SSE event — process it
                if !eventType.isEmpty, !dataBuffer.isEmpty {
                    processSSEEvent(type: eventType, data: dataBuffer)
                }
                eventType = ""
                dataBuffer = ""
            } else if line.hasPrefix("event:") {
                eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                dataBuffer += data
            }
        }
    }

    private func processSSEEvent(type: String, data: String) {
        guard let jsonData = data.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return }

        AgentEventLogger.shared.log(source: "opencode-sse", session: nil, agent: "opencode", event: type, data: payload)

        switch type {
        case "session.status":
            if let status = (payload["status"] as? [String: Any])?["type"] as? String {
                AgentEventStore.shared.handleAgentEvent(
                    sessionID: nil, agent: "opencode", event: "status",
                    data: ["status": status]
                )
            }

        case "permission.asked":
            AgentEventStore.shared.handleAgentEvent(
                sessionID: nil, agent: "opencode", event: "permission",
                data: payload
            )

        case "message.part.updated", "message.part.delta":
            // Forward as generic event for future UI consumption
            AgentEventStore.shared.handleAgentEvent(
                sessionID: nil, agent: "opencode", event: type,
                data: payload
            )

        default:
            break
        }
    }

    // MARK: - REST Control

    func abort(sessionID: String) async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/session/\(sessionID)/abort")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
    }

    func approvePermission(permissionID: String, reply: String) async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/permission/\(permissionID)/reply")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONSerialization.data(withJSONObject: ["reply": reply])
        request.httpBody = body
        _ = try await URLSession.shared.data(for: request)
    }

    func answerQuestion(questionID: String, answer: String) async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/question/\(questionID)/reply")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONSerialization.data(withJSONObject: ["reply": answer])
        request.httpBody = body
        _ = try await URLSession.shared.data(for: request)
    }
}
