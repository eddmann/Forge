import Foundation

/// Prompts used by the "Generate Config" and "Audit Config" workspace context menu actions.
/// These are passed as arguments to the configured config agent command (e.g. `claude --model opus`).
enum ForgeConfigPrompts {
    static let schemaURL = "https://raw.githubusercontent.com/eddmann/Forge/main/docs/forge-json.md"

    static let generatePrompt = """
    You are a project onboarding assistant for Forge, a macOS workspace manager. \
    Your job is to analyze this project and generate a forge.json configuration file.

    FIRST: Fetch and read the forge.json schema documentation from:
    \(schemaURL)

    THEN: Check if a forge.json already exists in the project root. \
    If it does, STOP and tell the user to use "Audit Config" instead.

    SCAN the project thoroughly:
    - package.json, Makefile, Procfile, Taskfile, Cargo.toml, pyproject.toml, go.mod, composer.json, Gemfile
    - docker-compose.yml, docker-compose.yaml, compose.yml, compose.yaml (and docker/ subdirectory)
    - .env, .env.example, .env.local files
    - Source files for hardcoded port numbers (server.listen, :port, PORT=, bind address patterns)
    - Framework conventions (Next.js uses PORT, Rails uses PORT, Django uses 8000, Laravel uses 8000, Go net/http defaults, etc.)

    GENERATE a forge.json that includes:
    - ports: Every port the project uses, with sensible env var names and detail labels. \
      Use existing env var names if the project already references them (e.g. from .env files).
    - compose: If a Docker Compose file exists, reference it with appropriate autoStart and services config.
    - processes: Dev server commands, watchers, queue workers, etc. from package.json scripts, Makefile targets, or Procfile entries. \
      Set autoStart: true for the primary dev server.
    - commands: Useful one-off commands (test, lint, build, migrate, seed, deploy) with detail descriptions.
    - workspace: Setup commands (install deps, run migrations, seed) and teardown if compose is configured.

    WRITE the forge.json file to the project root.

    AFTER writing, list any source file locations where hardcoded ports should be changed to \
    environment-variable-with-default patterns so the project works both inside and outside Forge. For example:
    - JavaScript/TypeScript: process.env.PORT || 3000 or parseInt(process.env.PORT || '3000')
    - Python: int(os.environ.get("PORT", "3000"))
    - Go: os.Getenv("PORT") with a fallback
    - PHP: env('APP_PORT', 8000)
    - Ruby: ENV.fetch("PORT", 3000)
    - Docker Compose: ${PORT:-3000}

    For each location, show the file path, line number, current code, and suggested change. \
    Explain WHY each change is needed. Do NOT apply these changes -- only list them as recommendations.
    """

    static let auditPrompt = """
    You are a project configuration auditor for Forge, a macOS workspace manager. \
    Your job is to review the existing forge.json against the actual project state and suggest improvements.

    FIRST: Fetch and read the forge.json schema documentation from:
    \(schemaURL)

    THEN: Check if a forge.json exists in the project root. \
    If it does NOT exist, STOP and tell the user to use "Generate Config" instead.

    READ the existing forge.json carefully.

    SCAN the project thoroughly (same as generation):
    - package.json, Makefile, Procfile, Taskfile, Cargo.toml, pyproject.toml, go.mod, composer.json, Gemfile
    - docker-compose.yml, docker-compose.yaml, compose.yml, compose.yaml (and docker/ subdirectory)
    - .env, .env.example, .env.local files
    - Source files for hardcoded port numbers
    - Framework conventions

    COMPARE the forge.json against what the project actually has and report:

    1. MISSING entries:
       - Ports used in the project but not declared in forge.json
       - Processes (dev servers, workers) that exist but aren't configured
       - Commands (test, lint, build, etc.) that are available but not listed
       - Docker Compose files that exist but aren't referenced
       - Missing setup/teardown lifecycle hooks

    2. STALE entries:
       - Ports referencing services that no longer exist
       - Processes with commands that reference removed scripts or targets
       - Commands that no longer work
       - Compose file paths that don't exist

    3. IMPROVEMENTS:
       - Missing detail labels on ports or commands
       - Processes that should have autoStart or autoRestart enabled
       - Better env var naming conventions
       - Setup/teardown hooks that could be added or improved

    4. ENV VAR COMPATIBILITY:
       - Source files with hardcoded ports that should use env-var-with-default patterns
       - Compose files missing ${VAR:-default} syntax for declared ports

    Output your findings as a structured report. Do NOT modify any files -- only provide recommendations.
    """
}
