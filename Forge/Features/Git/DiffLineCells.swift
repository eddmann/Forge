import AppKit
import SwiftUI

// MARK: - Row Height Constants

enum DiffCellMetrics {
    static func lineRowHeight(fontSize: CGFloat) -> CGFloat {
        ceil(fontSize * 1.4) + 2
    }

    static func hunkHeaderHeight(fontSize: CGFloat) -> CGFloat {
        ceil(fontSize * 1.2) + 6
    }
}

// MARK: - Unified Line Cell

final class UnifiedLineCellView: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("unified-line")

    private let commentButton = NSButton()
    private let oldLineNumberField = NSTextField(labelWithString: "")
    private let newLineNumberField = NSTextField(labelWithString: "")
    private let prefixField = NSTextField(labelWithString: "")
    private let contentField = NSTextField(labelWithString: "")

    private var onComment: (() -> Void)?
    private var showCommentButton = false
    private var trackingAreaInstalled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    private func setupSubviews() {
        // Comment button
        commentButton.bezelStyle = .inline
        commentButton.isBordered = false
        commentButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add comment")
        commentButton.contentTintColor = .white
        commentButton.wantsLayer = true
        commentButton.layer?.backgroundColor = NSColor.systemBlue.cgColor
        commentButton.layer?.cornerRadius = 3
        commentButton.isHidden = true
        commentButton.target = self
        commentButton.action = #selector(commentTapped)

        for view in [commentButton, oldLineNumberField, newLineNumberField, prefixField, contentField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        // Line number fields
        for field in [oldLineNumberField, newLineNumberField] {
            field.alignment = .right
            field.textColor = .tertiaryLabelColor
            field.isSelectable = false
        }

        prefixField.alignment = .center
        prefixField.isSelectable = false

        contentField.isSelectable = true
        contentField.allowsExpansionToolTips = true
        contentField.lineBreakMode = .byClipping
        contentField.maximumNumberOfLines = 1
        contentField.cell?.truncatesLastVisibleLine = true

        NSLayoutConstraint.activate([
            commentButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            commentButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            commentButton.widthAnchor.constraint(equalToConstant: 16),
            commentButton.heightAnchor.constraint(equalToConstant: 16),

            oldLineNumberField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            oldLineNumberField.centerYAnchor.constraint(equalTo: centerYAnchor),
            oldLineNumberField.widthAnchor.constraint(equalToConstant: 36),

            newLineNumberField.leadingAnchor.constraint(equalTo: oldLineNumberField.trailingAnchor),
            newLineNumberField.centerYAnchor.constraint(equalTo: centerYAnchor),
            newLineNumberField.widthAnchor.constraint(equalToConstant: 36),

            prefixField.leadingAnchor.constraint(equalTo: newLineNumberField.trailingAnchor),
            prefixField.centerYAnchor.constraint(equalTo: centerYAnchor),
            prefixField.widthAnchor.constraint(equalToConstant: 16),

            contentField.leadingAnchor.constraint(equalTo: prefixField.trailingAnchor, constant: 4),
            contentField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            contentField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        // Install a single tracking area with .inVisibleRect — AppKit auto-recalculates
        // the rect when the view moves (critical for NSTableView cell recycling).
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    func configure(
        line: GitDiffLine,
        wordDiffs: [WordDiffSegment]?,
        fontSize: CGFloat,
        showCommentButton: Bool,
        onComment: @escaping () -> Void
    ) {
        self.onComment = onComment
        self.showCommentButton = showCommentButton
        commentButton.isHidden = true

        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let smallFont = NSFont.monospacedSystemFont(ofSize: fontSize - 2, weight: .regular)

        oldLineNumberField.font = smallFont
        oldLineNumberField.stringValue = line.oldLineNumber.map { String($0) } ?? ""

        newLineNumberField.font = smallFont
        newLineNumberField.stringValue = line.newLineNumber.map { String($0) } ?? ""

        prefixField.font = font
        prefixField.stringValue = line.prefix
        prefixField.textColor = prefixColor(for: line.kind)

        if let segments = wordDiffs {
            contentField.attributedStringValue = WordDiffLineView.attributedString(segments: segments, fontSize: fontSize)
        } else {
            contentField.font = font
            contentField.textColor = .labelColor
            contentField.stringValue = line.text
        }

        // Background color
        wantsLayer = true
        layer?.backgroundColor = backgroundColor(for: line.kind).cgColor
    }

    override func mouseEntered(with _: NSEvent) {
        if showCommentButton {
            commentButton.isHidden = false
        }
    }

    override func mouseExited(with _: NSEvent) {
        commentButton.isHidden = true
    }

    @objc private func commentTapped() {
        onComment?()
    }

    private func prefixColor(for kind: GitDiffLineKind) -> NSColor {
        switch kind {
        case .added: .systemGreen
        case .removed: .systemRed
        default: .tertiaryLabelColor
        }
    }

    private func backgroundColor(for kind: GitDiffLineKind) -> NSColor {
        switch kind {
        case .added: NSColor.systemGreen.withAlphaComponent(0.08)
        case .removed: NSColor.systemRed.withAlphaComponent(0.08)
        default: .clear
        }
    }
}

// MARK: - Hunk Header Cell

final class HunkHeaderCellView: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("hunk-header")

    private let headerLabel = NSTextField(labelWithString: "")
    private let additionsLabel = NSTextField(labelWithString: "")
    private let deletionsLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()

    private var onAction: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    private func setupSubviews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.05).cgColor

        for view in [headerLabel, additionsLabel, deletionsLabel, actionButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.maximumNumberOfLines = 1

        additionsLabel.alignment = .right
        deletionsLabel.alignment = .right

        actionButton.bezelStyle = .inline
        actionButton.isBordered = false
        actionButton.target = self
        actionButton.action = #selector(actionTapped)

        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            headerLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: additionsLabel.leadingAnchor, constant: -8),

            deletionsLabel.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -8),
            deletionsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            additionsLabel.trailingAnchor.constraint(equalTo: deletionsLabel.leadingAnchor, constant: -4),
            additionsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 16),
            actionButton.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    func configure(
        hunk: GitDiffHunk,
        index _: Int,
        fontSize: CGFloat,
        staged: Bool,
        onAction: @escaping () -> Void
    ) {
        self.onAction = onAction

        let font = NSFont.monospacedSystemFont(ofSize: fontSize - 2, weight: .regular)
        let statFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)

        headerLabel.font = font
        headerLabel.textColor = NSColor.systemBlue.withAlphaComponent(0.8)
        headerLabel.stringValue = hunk.header.isEmpty ? "@@" : hunk.header

        if hunk.additions > 0 {
            additionsLabel.font = statFont
            additionsLabel.textColor = .systemGreen
            additionsLabel.stringValue = "+\(hunk.additions)"
            additionsLabel.isHidden = false
        } else {
            additionsLabel.isHidden = true
        }

        if hunk.deletions > 0 {
            deletionsLabel.font = statFont
            deletionsLabel.textColor = .systemRed
            deletionsLabel.stringValue = "-\(hunk.deletions)"
            deletionsLabel.isHidden = false
        } else {
            deletionsLabel.isHidden = true
        }

        if staged {
            actionButton.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Unstage hunk")
            actionButton.contentTintColor = .systemOrange
        } else {
            actionButton.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Stage hunk")
            actionButton.contentTintColor = .systemGreen
        }
    }

    /// Hides the stage/unstage button (used in Changes tab where hunk staging isn't available per-hunk).
    func hideActionButton() {
        actionButton.isHidden = true
    }

    @objc private func actionTapped() {
        onAction?()
    }
}

// MARK: - Split Half Cell

final class SplitHalfCellView: NSView {
    private let commentButton = NSButton()
    private let lineNumberField = NSTextField(labelWithString: "")
    private let contentField = NSTextField(labelWithString: "")

    private var onComment: (() -> Void)?
    private var showCommentButton = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    private func setupSubviews() {
        commentButton.bezelStyle = .inline
        commentButton.isBordered = false
        commentButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add comment")
        commentButton.contentTintColor = .white
        commentButton.wantsLayer = true
        commentButton.layer?.backgroundColor = NSColor.systemBlue.cgColor
        commentButton.layer?.cornerRadius = 3
        commentButton.isHidden = true
        commentButton.target = self
        commentButton.action = #selector(commentTapped)

        lineNumberField.alignment = .right
        lineNumberField.textColor = .tertiaryLabelColor
        lineNumberField.isSelectable = false

        contentField.isSelectable = true
        contentField.lineBreakMode = .byTruncatingTail
        contentField.maximumNumberOfLines = 1
        contentField.cell?.truncatesLastVisibleLine = true

        for view in [commentButton, lineNumberField, contentField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            commentButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            commentButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            commentButton.widthAnchor.constraint(equalToConstant: 14),
            commentButton.heightAnchor.constraint(equalToConstant: 14),

            lineNumberField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            lineNumberField.centerYAnchor.constraint(equalTo: centerYAnchor),
            lineNumberField.widthAnchor.constraint(equalToConstant: 32),

            contentField.leadingAnchor.constraint(equalTo: lineNumberField.trailingAnchor, constant: 8),
            contentField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            contentField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    func configure(
        line: GitDiffLine?,
        side: AgentReviewCommentSide,
        fontSize: CGFloat,
        wordDiffs: [WordDiffSegment]?,
        showCommentButton: Bool,
        onComment: @escaping () -> Void
    ) {
        self.onComment = onComment
        self.showCommentButton = showCommentButton
        commentButton.isHidden = true

        guard let line else {
            // Empty side
            lineNumberField.stringValue = ""
            contentField.stringValue = ""
            wantsLayer = true
            layer?.backgroundColor = NSColor.separatorColor.cgColor
            isHidden = false
            return
        }

        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let smallFont = NSFont.monospacedSystemFont(ofSize: fontSize - 2, weight: .regular)

        lineNumberField.font = smallFont
        lineNumberField.stringValue = (side == .old ? line.oldLineNumber : line.newLineNumber).map { String($0) } ?? ""

        if let segments = wordDiffs {
            contentField.attributedStringValue = WordDiffLineView.attributedString(segments: segments, fontSize: fontSize)
        } else {
            contentField.font = font
            contentField.textColor = .labelColor
            contentField.stringValue = line.text
        }

        wantsLayer = true
        layer?.backgroundColor = splitBackgroundColor(for: line.kind).cgColor
    }

    override func mouseEntered(with _: NSEvent) {
        if showCommentButton { commentButton.isHidden = false }
    }

    override func mouseExited(with _: NSEvent) {
        commentButton.isHidden = true
    }

    @objc private func commentTapped() {
        onComment?()
    }

    private func splitBackgroundColor(for kind: GitDiffLineKind) -> NSColor {
        switch kind {
        case .added: NSColor.systemGreen.withAlphaComponent(0.1)
        case .removed: NSColor.systemRed.withAlphaComponent(0.1)
        default: .clear
        }
    }
}

// MARK: - Split Line Cell (contains two halves + divider)

final class SplitLineCellView: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("split-line")

    let leftHalf = SplitHalfCellView()
    let rightHalf = SplitHalfCellView()
    private let divider = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    private func setupSubviews() {
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor

        for view in [leftHalf, divider, rightHalf] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            leftHalf.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftHalf.topAnchor.constraint(equalTo: topAnchor),
            leftHalf.bottomAnchor.constraint(equalTo: bottomAnchor),

            divider.leadingAnchor.constraint(equalTo: leftHalf.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            rightHalf.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            rightHalf.topAnchor.constraint(equalTo: topAnchor),
            rightHalf.bottomAnchor.constraint(equalTo: bottomAnchor),
            rightHalf.trailingAnchor.constraint(equalTo: trailingAnchor),

            leftHalf.widthAnchor.constraint(equalTo: rightHalf.widthAnchor)
        ])
    }

    func configure(
        left: GitDiffLine?,
        right: GitDiffLine?,
        leftWordDiffs: [WordDiffSegment]?,
        rightWordDiffs: [WordDiffSegment]?,
        fontSize: CGFloat,
        showCommentButton: Bool,
        onComment: @escaping (GitDiffLine, AgentReviewCommentSide) -> Void
    ) {
        leftHalf.configure(
            line: left, side: .old, fontSize: fontSize,
            wordDiffs: leftWordDiffs, showCommentButton: showCommentButton,
            onComment: { if let left { onComment(left, .old) } }
        )
        rightHalf.configure(
            line: right, side: .new, fontSize: fontSize,
            wordDiffs: rightWordDiffs, showCommentButton: showCommentButton,
            onComment: { if let right { onComment(right, .new) } }
        )
    }
}

// MARK: - SwiftUI Hosting Cell

final class SwiftUIHostingCellView: NSView {
    static let commentReuseIdentifier = NSUserInterfaceItemIdentifier("swiftui-comment")
    static let draftReuseIdentifier = NSUserInterfaceItemIdentifier("swiftui-draft")

    private var hostingView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func configure(content: some View) {
        hostingView?.removeFromSuperview()

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)

        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        hostingView = hosting
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        guard let hosting = hostingView else { return 44 }
        let fittingSize = hosting.fittingSize
        // Constrain to width to get the proper height
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: fittingSize.height)
        return max(hosting.fittingSize.height, 44)
    }
}
