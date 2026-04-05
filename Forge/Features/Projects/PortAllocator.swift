import Darwin
import Foundation

// MARK: - Port Allocator

/// Allocates non-colliding ports for workspace environments.
/// Checks both Forge's internal registry (other workspaces) and actual machine availability.
enum PortAllocator {
    private static let maxAttempts = 100
    private static let minPort = 1024
    private static let maxPort = 65535

    /// Allocate ports for a workspace based on forge.json port declarations.
    /// Returns a mapping of env var name to allocated port.
    static func allocatePorts(
        requested: [String: PortConfig],
        existingClaims: [String: Int]
    ) -> (allocated: [String: Int], failures: [String]) {
        var allocated: [String: Int] = [:]
        var failures: [String] = []
        // Collect all ports already claimed by other workspaces
        var takenPorts = Set(allClaimedPorts())

        for (envVar, portConfig) in requested.sorted(by: { $0.key < $1.key }) {
            let preferredPort = portConfig.port

            // If this workspace already has a valid claim, keep it
            if let existing = existingClaims[envVar],
               !takenPorts.contains(existing),
               isPortAvailable(existing)
            {
                allocated[envVar] = existing
                takenPorts.insert(existing)
                continue
            }

            if let port = findAvailablePort(from: preferredPort, excluding: takenPorts) {
                allocated[envVar] = port
                takenPorts.insert(port)
            } else {
                failures.append(envVar)
            }
        }

        return (allocated, failures)
    }

    /// Find the next available port starting from `preferred`, skipping any in `excluding`.
    private static func findAvailablePort(from preferred: Int, excluding: Set<Int>) -> Int? {
        var candidate = max(preferred, minPort)
        var attempts = 0

        while attempts < maxAttempts, candidate <= maxPort {
            if !excluding.contains(candidate), isPortAvailable(candidate) {
                return candidate
            }
            candidate += 1
            attempts += 1
        }

        return nil
    }

    /// Check if a TCP port is available on the machine by attempting to bind to it.
    static func isPortAvailable(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var opt: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout.size(ofValue: opt)))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = UInt32(INADDR_ANY).bigEndian

        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    /// Re-validate existing port allocations. Returns ports that are still available
    /// and a list of env vars whose ports have been taken.
    static func revalidate(
        allocatedPorts: [String: Int]
    ) -> (valid: [String: Int], conflicts: [String]) {
        let otherClaims = Set(allClaimedPorts())
        var valid: [String: Int] = [:]
        var conflicts: [String] = []

        for (envVar, port) in allocatedPorts {
            if !otherClaims.contains(port), isPortAvailable(port) {
                valid[envVar] = port
            } else {
                conflicts.append(envVar)
            }
        }

        return (valid, conflicts)
    }

    /// Collect all ports claimed by active workspaces across all projects.
    private static func allClaimedPorts() -> [Int] {
        ProjectStore.shared.workspaces
            .filter { $0.status == .active }
            .flatMap(\.allocatedPorts.values)
    }
}
