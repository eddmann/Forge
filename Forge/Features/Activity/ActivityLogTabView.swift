import SwiftUI

struct ActivityLogTabView: View {
    let workspaceID: UUID
    @ObservedObject private var store = ActivityLogStore.shared
    @ObservedObject private var appearance = TerminalAppearanceStore.shared

    var body: some View {
        let events = store.events(for: workspaceID).reversed() as [ActivityEvent]

        VStack(spacing: 0) {
            activityToolbar(eventCount: events.count)
            Divider().opacity(0.3)

            if events.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                            ActivityEventRow(
                                event: event,
                                isFirst: index == 0,
                                isLast: index == events.count - 1
                            )
                        }
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.config.theme.background))
    }

    // MARK: - Toolbar

    private func activityToolbar(eventCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Text("Activity")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)

            if eventCount > 0 {
                Text("\(eventCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Color(nsColor: NSColor.controlBackgroundColor))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 36, weight: .thin))
                .foregroundColor(.secondary.opacity(0.4))
            Text("No activity yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Text("Activity will appear here as you work in this workspace.")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.6))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Event Row

private struct ActivityEventRow: View {
    let event: ActivityEvent
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Timeline column
            VStack(spacing: 0) {
                // Line above dot
                Rectangle()
                    .fill(isFirst ? Color.clear : Color.secondary.opacity(0.15))
                    .frame(width: 1.5)
                    .frame(height: 12)

                // Dot
                ZStack {
                    Circle()
                        .fill(event.kind.color.opacity(0.15))
                        .frame(width: 24, height: 24)
                    Image(systemName: event.kind.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(event.kind.color)
                }

                // Line below dot
                Rectangle()
                    .fill(isLast ? Color.clear : Color.secondary.opacity(0.15))
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 40)

            // Content
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(event.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)

                    Spacer()

                    Text(relativeTime(event.timestamp))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.5))
                }

                if event.isPending {
                    Text("Summarising...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.5))
                        .italic()
                } else if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(3)
                        .lineSpacing(2)
                }
            }
            .padding(.vertical, 8)
            .padding(.trailing, 20)
        }
        .padding(.leading, 16)
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        } else if interval < 86400 {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, h:mm a"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Event Kind Display

extension ActivityEventKind {
    var icon: String {
        switch self {
        case .workspaceCreated: "plus.circle.fill"
        case .workspaceMerged: "arrow.triangle.merge"
        case .agentSessionStart: "play.circle.fill"
        case .agentSnapshot: "text.bubble.fill"
        case .agentSessionEnd: "checkmark.circle.fill"
        case .reviewSent: "paperplane.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .workspaceCreated: .green
        case .workspaceMerged: .purple
        case .agentSessionStart: .blue
        case .agentSnapshot: .secondary
        case .agentSessionEnd: .gray
        case .reviewSent: .orange
        }
    }
}
