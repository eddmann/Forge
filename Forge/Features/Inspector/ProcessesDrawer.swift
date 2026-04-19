import SwiftUI

// MARK: - Processes Drawer

struct ProcessesDrawer: View {
    @Binding var expanded: Bool
    @ObservedObject var processManager: ProcessManager

    var body: some View {
        VStack(spacing: 0) {
            // Divider above header
            Rectangle()
                .fill(Color(nsColor: NSColor(white: 1.0, alpha: 0.08)))
                .frame(height: 0.5)

            // Header — always visible, click to toggle
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))

                    Image(systemName: "gearshape.2")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    Text("Processes")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)

                    if !processManager.processes.isEmpty {
                        Text("\(processManager.processes.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(3)

                        let runningCount = processManager.processes.filter { $0.status == .running }.count
                        if runningCount > 0 {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                        }
                    }

                    Spacer()

                    if expanded, !processManager.processes.isEmpty {
                        Button(action: { processManager.syncState() }) {
                            Image(systemName: "arrow.trianglehead.2.clockwise")
                                .font(.system(size: 9))
                                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh process state")

                        let hasRunning = processManager.processes.contains { $0.status == .running }
                        Button(action: {
                            if hasRunning {
                                processManager.stopAll()
                            } else {
                                processManager.startAutoStartProcesses()
                            }
                        }) {
                            Image(systemName: hasRunning ? "stop.fill" : "play.fill")
                                .font(.system(size: 9))
                                .foregroundColor(Color(nsColor: TerminalAppearanceStore.shared.config.theme.accent))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expandable process list
            if expanded {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(processManager.processes) { process in
                            ProcessRow(
                                process: process,
                                onStart: { processManager.start(process.id) },
                                onStop: { processManager.stop(process.id) },
                                onRestart: { processManager.restart(process.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 360)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Process Row

private struct ProcessRow: View {
    let process: ManagedProcess
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void

    @State private var isHovered = false
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            HStack(spacing: 8) {
                // Status dot
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)

                // Name
                Text(process.name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                // Port badge
                if let port = process.port {
                    Text(":\(port)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        .help(process.portDetail ?? "Port \(port)")
                }

                // Source badge
                Text(process.source.rawValue)
                    .font(.system(size: 9))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(3)

                // Controls
                if isHovered {
                    if process.status == .running {
                        Button(action: onRestart) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                                .foregroundColor(Color(nsColor: TerminalAppearanceStore.shared.config.theme.accent))
                        }
                        .buttonStyle(.borderless)

                        Button(action: onStop) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.red.opacity(0.8))
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Button(action: onStart) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                                .foregroundColor(Color(nsColor: TerminalAppearanceStore.shared.config.theme.accent))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHovered ? Color.white.opacity(0.05) : .clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { showLog.toggle() } }

            // Expandable log tail
            if showLog, !process.outputBuffer.isEmpty {
                ScrollView {
                    Text(process.outputBuffer.lines.suffix(20).joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.2))
                .cornerRadius(4)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }
    }

    private var statusColor: Color {
        switch process.status {
        case .running: .green
        case .stopped: .gray
        case .crashed: .red
        }
    }
}
