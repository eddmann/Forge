import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterPHP
import TreeSitterPython
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

enum LanguageID: String, CaseIterable {
    case swift, typescript, tsx, javascript, python, go, rust
    case json, yaml, html, css, markdown, bash, php
}

struct LanguageBinding {
    let id: LanguageID
    let language: Language
    let highlightsQuery: Query?
}

enum LanguageRegistry {
    static func binding(for filePath: String, contentSniff: String? = nil) -> LanguageBinding? {
        guard let id = detect(filePath: filePath, content: contentSniff) else { return nil }
        return cached(id)
    }

    static func detect(filePath: String, content: String?) -> LanguageID? {
        let lower = (filePath as NSString).lastPathComponent.lowercased()
        let ext = (lower as NSString).pathExtension

        switch ext {
        case "swift": return .swift
        case "ts", "mts", "cts": return .typescript
        case "tsx": return .tsx
        case "js", "mjs", "cjs", "jsx": return .javascript
        case "py", "pyi": return .python
        case "go": return .go
        case "rs": return .rust
        case "json", "jsonc": return .json
        case "yml", "yaml": return .yaml
        case "html", "htm": return .html
        case "css": return .css
        case "md", "markdown": return .markdown
        case "sh", "bash", "zsh": return .bash
        case "php", "phtml", "php3", "php4", "php5", "phps": return .php
        default: break
        }

        if lower == "package.swift" { return .swift }
        if lower == "dockerfile" || lower.hasPrefix("dockerfile.") { return nil }

        if let content, let shebang = content.split(whereSeparator: \.isNewline).first, shebang.hasPrefix("#!") {
            let line = String(shebang)
            if line.contains("python") { return .python }
            if line.contains("bash") || line.contains("/sh") || line.contains("zsh") { return .bash }
            if line.contains("node") { return .javascript }
        }
        return nil
    }

    // MARK: - Cache

    private static let lock = NSLock()
    private static var bindings: [LanguageID: LanguageBinding] = [:]

    private static func cached(_ id: LanguageID) -> LanguageBinding? {
        lock.lock(); defer { lock.unlock() }
        if let existing = bindings[id] { return existing }
        guard let language = makeLanguage(id) else { return nil }
        let query = loadHighlightsQuery(for: id, language: language)
        let binding = LanguageBinding(id: id, language: language, highlightsQuery: query)
        bindings[id] = binding
        return binding
    }

    private static func makeLanguage(_ id: LanguageID) -> Language? {
        let pointer: OpaquePointer? = switch id {
        case .swift: tree_sitter_swift()
        case .typescript: tree_sitter_typescript()
        case .tsx: tree_sitter_tsx()
        case .javascript: tree_sitter_javascript()
        case .python: tree_sitter_python()
        case .go: tree_sitter_go()
        case .rust: tree_sitter_rust()
        case .json: tree_sitter_json()
        case .yaml: tree_sitter_yaml()
        case .html: tree_sitter_html()
        case .css: tree_sitter_css()
        case .markdown: tree_sitter_markdown()
        case .bash: tree_sitter_bash()
        case .php: tree_sitter_php()
        }
        guard let pointer else { return nil }
        return Language(language: pointer)
    }

    /// SPM resource bundles ship as `<PackageName>_<TargetName>.bundle` inside the host app's
    /// Resources directory. Each grammar bundles its `queries/` folder containing `highlights.scm`.
    private static func loadHighlightsQuery(for id: LanguageID, language: Language) -> Query? {
        let bundleName = switch id {
        case .swift: "TreeSitterSwift_TreeSitterSwift"
        case .typescript: "TreeSitterTypeScript_TreeSitterTypeScript"
        case .tsx: "TreeSitterTypeScript_TreeSitterTSX"
        case .javascript: "TreeSitterJavaScript_TreeSitterJavaScript"
        case .python: "TreeSitterPython_TreeSitterPython"
        case .go: "TreeSitterGo_TreeSitterGo"
        case .rust: "TreeSitterRust_TreeSitterRust"
        case .json: "TreeSitterJSON_TreeSitterJSON"
        case .yaml: "TreeSitterYAML_TreeSitterYAML"
        case .html: "TreeSitterHTML_TreeSitterHTML"
        case .css: "TreeSitterCSS_TreeSitterCSS"
        case .markdown: "TreeSitterMarkdown_TreeSitterMarkdown"
        case .bash: "TreeSitterBash_TreeSitterBash"
        case .php: "TreeSitterPHP_TreeSitterPHP"
        }
        guard
            let bundleURL = Bundle.main.url(forResource: bundleName, withExtension: "bundle"),
            let bundle = Bundle(url: bundleURL),
            let queryURL = bundle.url(forResource: "highlights", withExtension: "scm", subdirectory: "queries")
        else {
            return nil
        }
        return try? language.query(contentsOf: queryURL)
    }
}
