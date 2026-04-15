import Foundation

/// A single RPC method handler. Every entry in `ForgeRPC.methods` conforms to this.
///
/// Methods are dispatched on the main actor since most of them touch app state
/// (`ProjectStore`, `TerminalSessionManager`, `AgentStore`, etc.) — keeping the
/// dispatch site `@MainActor` removes the need for ad-hoc dispatching inside
/// every handler. `handle` is `async` so long-running handlers can suspend
/// (e.g. `await Task.detached { ... }.value`) without pinning the main thread
/// for their entire duration.
@MainActor
protocol ForgeRPCMethod {
    /// Dotted method name as it appears on the wire (e.g. `"system.ping"`).
    static var name: String { get }

    /// Process the request params and return the result payload. Throw
    /// `ForgeRPCError` for client-visible failures.
    static func handle(params: [String: Any]) async throws -> [String: Any]
}

/// Stable, client-visible error codes. New codes can be added without breaking
/// existing clients; codes are strings so consumers don't depend on numeric
/// stability.
enum ForgeRPCError: Error {
    case methodNotFound(String)
    case invalidParams(String)
    case notFound(String)
    case notSupported(String)
    case internalError(String)

    var code: String {
        switch self {
        case .methodNotFound: "method_not_found"
        case .invalidParams: "invalid_params"
        case .notFound: "not_found"
        case .notSupported: "not_supported"
        case .internalError: "internal_error"
        }
    }

    var message: String {
        switch self {
        case let .methodNotFound(name): "Unknown method: \(name)"
        case let .invalidParams(detail),
             let .notFound(detail),
             let .notSupported(detail),
             let .internalError(detail):
            detail
        }
    }
}

/// Central dispatch table for all Forge RPC methods.
///
/// Adding a new method:
/// 1. Implement a struct conforming to `ForgeRPCMethod` in `RPCMethods/<Namespace>Methods.swift`
/// 2. Append `Self.self` to the `methods` dictionary below
/// 3. Add a sugar CLI subcommand in `Tools/forge/main.swift` if it's commonly invoked
@MainActor
enum ForgeRPC {
    static let protocolVersion = 1

    static let methods: [String: ForgeRPCMethod.Type] = [
        // system.*
        SystemPing.name: SystemPing.self,
        SystemIdentify.name: SystemIdentify.self,
        SystemCapabilities.name: SystemCapabilities.self,
        // app.*
        AppNotify.name: AppNotify.self,
        AppTree.name: AppTree.self,
        AppLog.name: AppLog.self,
        // workspace.*
        WorkspaceList.name: WorkspaceList.self,
        WorkspaceCurrent.name: WorkspaceCurrent.self,
        WorkspaceSelect.name: WorkspaceSelect.self,
        // terminal.*
        TerminalList.name: TerminalList.self,
        TerminalReadScreen.name: TerminalReadScreen.self,
        TerminalSendText.name: TerminalSendText.self,
        TerminalSendKey.name: TerminalSendKey.self,
        TerminalOpenAgent.name: TerminalOpenAgent.self,
        // agent.*
        AgentEvent.name: AgentEvent.self
    ]

    /// Dispatch a parsed JSON-RPC envelope. Returns the wire response dict that
    /// should be written back to the client.
    static func dispatch(envelope: [String: Any]) async -> [String: Any] {
        guard let method = envelope["method"] as? String else {
            return errorResponse(.invalidParams("Missing 'method' field"))
        }
        guard let handler = methods[method] else {
            return errorResponse(.methodNotFound(method))
        }
        let params = envelope["params"] as? [String: Any] ?? [:]
        do {
            let result = try await handler.handle(params: params)
            return ["ok": true, "result": result]
        } catch let error as ForgeRPCError {
            return errorResponse(error)
        } catch {
            return errorResponse(.internalError(error.localizedDescription))
        }
    }

    private static func errorResponse(_ error: ForgeRPCError) -> [String: Any] {
        ["ok": false, "error": ["code": error.code, "message": error.message]]
    }
}
