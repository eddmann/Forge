#if DEBUG
    import Foundation

    /// Static demo data — realistic project names, workspace names, file statuses, and diffs.
    enum DemoData {
        // MARK: - Projects

        static let projectIDs = (
            api: UUID(uuidString: "A0000001-0000-0000-0000-000000000001")!,
            web: UUID(uuidString: "A0000002-0000-0000-0000-000000000002")!,
            infra: UUID(uuidString: "A0000003-0000-0000-0000-000000000003")!,
            ml: UUID(uuidString: "A0000004-0000-0000-0000-000000000004")!
        )

        static let workspaceIDs = (
            charmander: UUID(uuidString: "B0000001-0000-0000-0000-000000000001")!,
            squirtle: UUID(uuidString: "B0000002-0000-0000-0000-000000000002")!,
            pikachu: UUID(uuidString: "B0000003-0000-0000-0000-000000000003")!,
            eevee: UUID(uuidString: "B0000004-0000-0000-0000-000000000004")!,
            snorlax: UUID(uuidString: "B0000005-0000-0000-0000-000000000005")!
        )

        static let tabIDs = (
            tab1: UUID(uuidString: "C0000001-0000-0000-0000-000000000001")!,
            tab2: UUID(uuidString: "C0000002-0000-0000-0000-000000000002")!,
            tab3: UUID(uuidString: "C0000003-0000-0000-0000-000000000003")!
        )

        static func projects() -> [Project] {
            let now = Date()
            let calendar = Calendar.current

            return [
                Project(
                    id: projectIDs.api,
                    name: "acme-api",
                    path: "/Users/demo/projects/acme-api",
                    defaultBranch: "main",
                    createdAt: calendar.date(byAdding: .day, value: -14, to: now)!,
                    lastActiveAt: now
                ),
                Project(
                    id: projectIDs.web,
                    name: "acme-web",
                    path: "/Users/demo/projects/acme-web",
                    defaultBranch: "main",
                    createdAt: calendar.date(byAdding: .day, value: -30, to: now)!,
                    lastActiveAt: calendar.date(byAdding: .hour, value: -3, to: now)!
                ),
                Project(
                    id: projectIDs.infra,
                    name: "acme-infra",
                    path: "/Users/demo/projects/acme-infra",
                    defaultBranch: "main",
                    createdAt: calendar.date(byAdding: .day, value: -60, to: now)!,
                    lastActiveAt: calendar.date(byAdding: .day, value: -2, to: now)!
                ),
                Project(
                    id: projectIDs.ml,
                    name: "acme-ml",
                    path: "/Users/demo/projects/acme-ml",
                    defaultBranch: "main",
                    createdAt: calendar.date(byAdding: .day, value: -90, to: now)!,
                    lastActiveAt: calendar.date(byAdding: .day, value: -10, to: now)!
                )
            ]
        }

        static func workspaces() -> [Workspace] {
            [
                Workspace(
                    id: workspaceIDs.charmander,
                    projectID: projectIDs.api,
                    name: "charmander",
                    path: "/Users/demo/.forge/clones/acme-api-charmander",
                    branch: "forge/charmander",
                    parentBranch: "main",
                    status: .active,
                    createdAt: Date()
                ),
                Workspace(
                    id: workspaceIDs.squirtle,
                    projectID: projectIDs.api,
                    name: "squirtle",
                    path: "/Users/demo/.forge/clones/acme-api-squirtle",
                    branch: "forge/squirtle",
                    parentBranch: "main",
                    status: .merged,
                    createdAt: Calendar.current.date(byAdding: .day, value: -3, to: Date())!
                ),
                Workspace(
                    id: workspaceIDs.pikachu,
                    projectID: projectIDs.web,
                    name: "pikachu",
                    path: "/Users/demo/.forge/clones/acme-web-pikachu",
                    branch: "forge/pikachu",
                    parentBranch: "main",
                    status: .active,
                    createdAt: Date()
                ),
                Workspace(
                    id: workspaceIDs.eevee,
                    projectID: projectIDs.web,
                    name: "eevee",
                    path: "/Users/demo/.forge/clones/acme-web-eevee",
                    branch: "forge/eevee",
                    parentBranch: "main",
                    status: .active,
                    createdAt: Calendar.current.date(byAdding: .hour, value: -5, to: Date())!
                ),
                Workspace(
                    id: workspaceIDs.snorlax,
                    projectID: projectIDs.infra,
                    name: "snorlax",
                    path: "/Users/demo/.forge/clones/acme-infra-snorlax",
                    branch: "forge/snorlax",
                    parentBranch: "main",
                    status: .active,
                    createdAt: Calendar.current.date(byAdding: .day, value: -1, to: Date())!
                )
            ]
        }

        // MARK: - File Statuses

        static func fileStatuses() -> [FileStatus] {
            [
                FileStatus(path: "src/handlers/auth.ts", indexStatus: .modified, workTreeStatus: nil, originalPath: nil),
                FileStatus(path: "src/handlers/barcode.ts", indexStatus: .modified, workTreeStatus: nil, originalPath: nil),
                FileStatus(path: "src/middleware/rateLimit.ts", indexStatus: .added, workTreeStatus: nil, originalPath: nil),
                FileStatus(path: "src/handlers/session.ts", indexStatus: nil, workTreeStatus: .modified, originalPath: nil),
                FileStatus(path: "src/utils/crypto.ts", indexStatus: nil, workTreeStatus: .modified, originalPath: nil),
                FileStatus(path: "tests/auth.test.ts", indexStatus: nil, workTreeStatus: .added, originalPath: nil),
                FileStatus(path: "README.md", indexStatus: nil, workTreeStatus: nil, originalPath: nil),
                FileStatus(path: ".env.example", indexStatus: nil, workTreeStatus: nil, originalPath: nil)
            ]
        }

        // MARK: - Diff

        static func sampleDiff() -> GitDiffResult {
            let hunks = [
                GitDiffHunk(
                    id: "hunk-1",
                    oldStart: 1,
                    oldCount: 8,
                    newStart: 1,
                    newCount: 10,
                    header: "import { Request, Response } from 'express'",
                    rawHeader: "@@ -1,8 +1,10 @@",
                    lines: [
                        GitDiffLine(id: "1-1", kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "import { Request, Response } from 'express'", rawLine: " import { Request, Response } from 'express'", hasTrailingNewline: true),
                        GitDiffLine(id: "1-2", kind: .context, oldLineNumber: 2, newLineNumber: 2, text: "import { verify } from 'jsonwebtoken'", rawLine: " import { verify } from 'jsonwebtoken'", hasTrailingNewline: true),
                        GitDiffLine(id: "1-3", kind: .added, oldLineNumber: nil, newLineNumber: 3, text: "import { rateLimit } from '../middleware/rateLimit'", rawLine: "+import { rateLimit } from '../middleware/rateLimit'", hasTrailingNewline: true),
                        GitDiffLine(id: "1-4", kind: .added, oldLineNumber: nil, newLineNumber: 4, text: "import { sanitize } from '../utils/crypto'", rawLine: "+import { sanitize } from '../utils/crypto'", hasTrailingNewline: true),
                        GitDiffLine(id: "1-5", kind: .context, oldLineNumber: 3, newLineNumber: 5, text: "", rawLine: " ", hasTrailingNewline: true),
                        GitDiffLine(id: "1-6", kind: .context, oldLineNumber: 4, newLineNumber: 6, text: "const JWT_SECRET = process.env.JWT_SECRET!", rawLine: " const JWT_SECRET = process.env.JWT_SECRET!", hasTrailingNewline: true),
                        GitDiffLine(id: "1-7", kind: .context, oldLineNumber: 5, newLineNumber: 7, text: "", rawLine: " ", hasTrailingNewline: true),
                        GitDiffLine(id: "1-8", kind: .removed, oldLineNumber: 6, newLineNumber: nil, text: "export async function authenticate(req: Request, res: Response) {", rawLine: "-export async function authenticate(req: Request, res: Response) {", hasTrailingNewline: true),
                        GitDiffLine(id: "1-9", kind: .added, oldLineNumber: nil, newLineNumber: 8, text: "export const authenticate = rateLimit(async (req: Request, res: Response) => {", rawLine: "+export const authenticate = rateLimit(async (req: Request, res: Response) => {", hasTrailingNewline: true),
                        GitDiffLine(id: "1-10", kind: .context, oldLineNumber: 7, newLineNumber: 9, text: "  const token = req.headers.authorization?.split(' ')[1]", rawLine: "   const token = req.headers.authorization?.split(' ')[1]", hasTrailingNewline: true),
                        GitDiffLine(id: "1-11", kind: .context, oldLineNumber: 8, newLineNumber: 10, text: "", rawLine: " ", hasTrailingNewline: true)
                    ]
                ),
                GitDiffHunk(
                    id: "hunk-2",
                    oldStart: 15,
                    oldCount: 7,
                    newStart: 17,
                    newCount: 12,
                    header: "  try {",
                    rawHeader: "@@ -15,7 +17,12 @@",
                    lines: [
                        GitDiffLine(id: "2-1", kind: .context, oldLineNumber: 15, newLineNumber: 17, text: "  try {", rawLine: "   try {", hasTrailingNewline: true),
                        GitDiffLine(id: "2-2", kind: .removed, oldLineNumber: 16, newLineNumber: nil, text: "    const decoded = verify(token, JWT_SECRET)", rawLine: "-    const decoded = verify(token, JWT_SECRET)", hasTrailingNewline: true),
                        GitDiffLine(id: "2-3", kind: .removed, oldLineNumber: 17, newLineNumber: nil, text: "    req.user = decoded", rawLine: "-    req.user = decoded", hasTrailingNewline: true),
                        GitDiffLine(id: "2-4", kind: .added, oldLineNumber: nil, newLineNumber: 18, text: "    const decoded = verify(sanitize(token), JWT_SECRET)", rawLine: "+    const decoded = verify(sanitize(token), JWT_SECRET)", hasTrailingNewline: true),
                        GitDiffLine(id: "2-5", kind: .added, oldLineNumber: nil, newLineNumber: 19, text: "    if (!decoded.sub || !decoded.exp) {", rawLine: "+    if (!decoded.sub || !decoded.exp) {", hasTrailingNewline: true),
                        GitDiffLine(id: "2-6", kind: .added, oldLineNumber: nil, newLineNumber: 20, text: "      return res.status(401).json({ error: 'Invalid token claims' })", rawLine: "+      return res.status(401).json({ error: 'Invalid token claims' })", hasTrailingNewline: true),
                        GitDiffLine(id: "2-7", kind: .added, oldLineNumber: nil, newLineNumber: 21, text: "    }", rawLine: "+    }", hasTrailingNewline: true),
                        GitDiffLine(id: "2-8", kind: .added, oldLineNumber: nil, newLineNumber: 22, text: "    req.user = decoded", rawLine: "+    req.user = decoded", hasTrailingNewline: true),
                        GitDiffLine(id: "2-9", kind: .context, oldLineNumber: 18, newLineNumber: 23, text: "    return next()", rawLine: "     return next()", hasTrailingNewline: true),
                        GitDiffLine(id: "2-10", kind: .context, oldLineNumber: 19, newLineNumber: 24, text: "  } catch {", rawLine: "   } catch {", hasTrailingNewline: true),
                        GitDiffLine(id: "2-11", kind: .removed, oldLineNumber: 20, newLineNumber: nil, text: "    return res.status(401).json({ error: 'Unauthorized' })", rawLine: "-    return res.status(401).json({ error: 'Unauthorized' })", hasTrailingNewline: true),
                        GitDiffLine(id: "2-12", kind: .added, oldLineNumber: nil, newLineNumber: 25, text: "    return res.status(401).json({ error: 'Token verification failed' })", rawLine: "+    return res.status(401).json({ error: 'Token verification failed' })", hasTrailingNewline: true),
                        GitDiffLine(id: "2-13", kind: .context, oldLineNumber: 21, newLineNumber: 26, text: "  }", rawLine: "   }", hasTrailingNewline: true)
                    ]
                )
            ]

            let fileDiff = GitFileDiff(
                oldPath: "src/handlers/auth.ts",
                newPath: "src/handlers/auth.ts",
                change: .modified,
                isBinary: false,
                hunks: hunks,
                patch: "",
                similarity: nil
            )

            return GitDiffResult(
                files: [fileDiff],
                rawPatch: "",
                stats: GitDiffStats(filesChanged: 1, insertions: 8, deletions: 3)
            )
        }

        // MARK: - Additional File Diffs

        /// Multiple file diffs for the changes tab / workspace diff view.
        static func fileDiffs() -> [GitFileDiff] {
            [
                sampleDiff().files.first!, // auth.ts (reuse existing)
                barcodeDiff(),
                rateLimitDiff()
            ]
        }

        private static func barcodeDiff() -> GitFileDiff {
            let hunks = [
                GitDiffHunk(
                    id: "barcode-hunk-1",
                    oldStart: 1,
                    oldCount: 6,
                    newStart: 1,
                    newCount: 9,
                    header: "import { createCanvas } from 'canvas'",
                    rawHeader: "@@ -1,6 +1,9 @@",
                    lines: [
                        GitDiffLine(id: "b-1", kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "import { createCanvas } from 'canvas'", rawLine: " import { createCanvas } from 'canvas'"),
                        GitDiffLine(id: "b-2", kind: .added, oldLineNumber: nil, newLineNumber: 2, text: "import { validateInput } from '../utils/validation'", rawLine: "+import { validateInput } from '../utils/validation'"),
                        GitDiffLine(id: "b-3", kind: .added, oldLineNumber: nil, newLineNumber: 3, text: "import { BarcodeFormat } from '../types'", rawLine: "+import { BarcodeFormat } from '../types'"),
                        GitDiffLine(id: "b-4", kind: .context, oldLineNumber: 2, newLineNumber: 4, text: "", rawLine: " "),
                        GitDiffLine(id: "b-5", kind: .removed, oldLineNumber: 3, newLineNumber: nil, text: "export function generateBarcode(data: string) {", rawLine: "-export function generateBarcode(data: string) {"),
                        GitDiffLine(id: "b-6", kind: .added, oldLineNumber: nil, newLineNumber: 5, text: "export function generateBarcode(data: string, format: BarcodeFormat = 'code128') {", rawLine: "+export function generateBarcode(data: string, format: BarcodeFormat = 'code128') {"),
                        GitDiffLine(id: "b-7", kind: .added, oldLineNumber: nil, newLineNumber: 6, text: "  validateInput(data, format)", rawLine: "+  validateInput(data, format)"),
                        GitDiffLine(id: "b-8", kind: .context, oldLineNumber: 4, newLineNumber: 7, text: "  const canvas = createCanvas(200, 80)", rawLine: "   const canvas = createCanvas(200, 80)"),
                        GitDiffLine(id: "b-9", kind: .context, oldLineNumber: 5, newLineNumber: 8, text: "  const ctx = canvas.getContext('2d')", rawLine: "   const ctx = canvas.getContext('2d')"),
                        GitDiffLine(id: "b-10", kind: .context, oldLineNumber: 6, newLineNumber: 9, text: "", rawLine: " ")
                    ]
                )
            ]

            return GitFileDiff(
                oldPath: "src/handlers/barcode.ts",
                newPath: "src/handlers/barcode.ts",
                change: .modified,
                isBinary: false,
                hunks: hunks,
                patch: "",
                similarity: nil
            )
        }

        private static func rateLimitDiff() -> GitFileDiff {
            let hunks = [
                GitDiffHunk(
                    id: "rate-hunk-1",
                    oldStart: 0,
                    oldCount: 0,
                    newStart: 1,
                    newCount: 18,
                    header: "",
                    rawHeader: "@@ -0,0 +1,18 @@",
                    lines: [
                        GitDiffLine(id: "r-1", kind: .added, oldLineNumber: nil, newLineNumber: 1, text: "import { Request, Response, NextFunction } from 'express'", rawLine: "+import { Request, Response, NextFunction } from 'express'"),
                        GitDiffLine(id: "r-2", kind: .added, oldLineNumber: nil, newLineNumber: 2, text: "", rawLine: "+"),
                        GitDiffLine(id: "r-3", kind: .added, oldLineNumber: nil, newLineNumber: 3, text: "const windowMs = 15 * 60 * 1000 // 15 minutes", rawLine: "+const windowMs = 15 * 60 * 1000 // 15 minutes"),
                        GitDiffLine(id: "r-4", kind: .added, oldLineNumber: nil, newLineNumber: 4, text: "const maxRequests = 100", rawLine: "+const maxRequests = 100"),
                        GitDiffLine(id: "r-5", kind: .added, oldLineNumber: nil, newLineNumber: 5, text: "const hits = new Map<string, { count: number; resetAt: number }>()", rawLine: "+const hits = new Map<string, { count: number; resetAt: number }>()"),
                        GitDiffLine(id: "r-6", kind: .added, oldLineNumber: nil, newLineNumber: 6, text: "", rawLine: "+"),
                        GitDiffLine(id: "r-7", kind: .added, oldLineNumber: nil, newLineNumber: 7, text: "export function rateLimit(handler: Function) {", rawLine: "+export function rateLimit(handler: Function) {"),
                        GitDiffLine(id: "r-8", kind: .added, oldLineNumber: nil, newLineNumber: 8, text: "  return async (req: Request, res: Response, next: NextFunction) => {", rawLine: "+  return async (req: Request, res: Response, next: NextFunction) => {"),
                        GitDiffLine(id: "r-9", kind: .added, oldLineNumber: nil, newLineNumber: 9, text: "    const key = req.ip ?? 'unknown'", rawLine: "+    const key = req.ip ?? 'unknown'"),
                        GitDiffLine(id: "r-10", kind: .added, oldLineNumber: nil, newLineNumber: 10, text: "    const now = Date.now()", rawLine: "+    const now = Date.now()"),
                        GitDiffLine(id: "r-11", kind: .added, oldLineNumber: nil, newLineNumber: 11, text: "    const entry = hits.get(key)", rawLine: "+    const entry = hits.get(key)"),
                        GitDiffLine(id: "r-12", kind: .added, oldLineNumber: nil, newLineNumber: 12, text: "", rawLine: "+"),
                        GitDiffLine(id: "r-13", kind: .added, oldLineNumber: nil, newLineNumber: 13, text: "    if (entry && entry.resetAt > now && entry.count >= maxRequests) {", rawLine: "+    if (entry && entry.resetAt > now && entry.count >= maxRequests) {"),
                        GitDiffLine(id: "r-14", kind: .added, oldLineNumber: nil, newLineNumber: 14, text: "      return res.status(429).json({ error: 'Too many requests' })", rawLine: "+      return res.status(429).json({ error: 'Too many requests' })"),
                        GitDiffLine(id: "r-15", kind: .added, oldLineNumber: nil, newLineNumber: 15, text: "    }", rawLine: "+    }"),
                        GitDiffLine(id: "r-16", kind: .added, oldLineNumber: nil, newLineNumber: 16, text: "", rawLine: "+"),
                        GitDiffLine(id: "r-17", kind: .added, oldLineNumber: nil, newLineNumber: 17, text: "    hits.set(key, { count: (entry?.count ?? 0) + 1, resetAt: now + windowMs })", rawLine: "+    hits.set(key, { count: (entry?.count ?? 0) + 1, resetAt: now + windowMs })"),
                        GitDiffLine(id: "r-18", kind: .added, oldLineNumber: nil, newLineNumber: 18, text: "    return handler(req, res, next)", rawLine: "+    return handler(req, res, next)")
                    ]
                )
            ]

            return GitFileDiff(
                oldPath: nil,
                newPath: "src/middleware/rateLimit.ts",
                change: .added,
                isBinary: false,
                hunks: hunks,
                patch: "",
                similarity: nil
            )
        }

        // MARK: - Workspace Commits

        static func workspaceCommits() -> [WorkspaceCommit] {
            let now = Date()
            let calendar = Calendar.current
            return [
                WorkspaceCommit(
                    hash: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",
                    message: "Add rate limiting middleware with sliding window",
                    author: "forge/charmander",
                    date: calendar.date(byAdding: .hour, value: -2, to: now)!
                ),
                WorkspaceCommit(
                    hash: "b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1",
                    message: "Wrap auth handler with rate limiter",
                    author: "forge/charmander",
                    date: calendar.date(byAdding: .hour, value: -1, to: now)!
                ),
                WorkspaceCommit(
                    hash: "c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2",
                    message: "Add token claim validation and input sanitization",
                    author: "forge/charmander",
                    date: calendar.date(byAdding: .minute, value: -30, to: now)!
                ),
                WorkspaceCommit(
                    hash: "d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3",
                    message: "Add barcode format validation and type safety",
                    author: "forge/charmander",
                    date: calendar.date(byAdding: .minute, value: -10, to: now)!
                )
            ]
        }

        // MARK: - Summaries

        static func summaries() -> [UUID: String] {
            [
                workspaceIDs.charmander: "Add rate limiting and token validation to auth handler",
                workspaceIDs.pikachu: "Migrate search page from REST to GraphQL endpoint",
                workspaceIDs.eevee: "Fix responsive layout breakpoints on dashboard view",
                workspaceIDs.snorlax: "Add Terraform module for Redis cluster provisioning"
            ]
        }
    }
#endif
