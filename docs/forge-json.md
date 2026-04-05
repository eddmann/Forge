# forge.json

A `forge.json` file in the project root configures how Forge manages workspaces for that project. It handles port allocation, process management, Docker Compose integration, custom commands, and workspace lifecycle hooks.

All sections are optional. A project without `forge.json` works exactly as before. The file is committed to the repo but has no effect outside Forge -- all configuration uses standard environment variables so the project still runs normally without it.

## Schema

```jsonc
{
  "ports": { ... },
  "compose": "..." | { ... },
  "processes": { ... },
  "commands": { ... },
  "workspace": { ... }
}
```

---

## ports

Declares TCP ports the project needs, keyed by environment variable name. Forge allocates a non-colliding port for each workspace and injects it as an env var into every shell, process, and lifecycle command.

Each entry can be a plain port number or an object with a `detail` field:

```jsonc
"ports": {
  "PORT": 5173,
  "DB_PORT": { "port": 5432, "detail": "PostgreSQL" },
  "MINIO_PORT": { "port": 9000, "detail": "MinIO S3-compatible storage" }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| key | `string` | yes | Environment variable name (e.g. `PORT`, `DB_PORT`) |
| value | `number` or `object` | yes | Preferred port, or object with `port` and optional `detail` |
| `port` | `number` | yes (object form) | Preferred port number (1024--65535) |
| `detail` | `string` | no | Human-readable label shown in the UI |

**How allocation works:**

1. For each declared port, Forge tries the preferred value first
2. If it's already claimed by another workspace or in use on the machine, it increments until it finds a free one (up to 100 attempts)
3. The allocated port is persisted on the workspace and injected as an env var

Use `${PORT:-5173}` style defaults in your scripts and compose files so the project works both inside and outside Forge.

---

## compose

Integrates a Docker Compose file. Can be a string (path to the file) or a full object:

```jsonc
// String shorthand
"compose": "docker-compose.yml"

// Full object
"compose": {
  "file": "docker/compose.yaml",
  "autoStart": true,
  "services": ["app", "db"]
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `file` | `string` | required | Path to compose file, relative to project root |
| `autoStart` | `boolean` | `true` | Start services automatically when the workspace opens |
| `services` | `string[]` | all | Limit to specific services (omit to include all) |

String shorthand is equivalent to `{ "file": "<path>", "autoStart": true }`.

**What Forge injects:**

- `COMPOSE_PROJECT_NAME` set to `{project}-{workspace}` -- namespaces containers, volumes, and networks so workspaces don't collide
- All `ports` env vars -- so `${DB_PORT:-5432}` in your compose file resolves to the allocated port

**Teardown:** If no explicit `workspace.teardown` is defined, Forge automatically runs `docker compose down` when a workspace is deleted.

---

## processes

Declares background processes managed by Forge. Each entry can be a command string or a full object:

```jsonc
"processes": {
  "dev": "bun run dev",
  "worker": {
    "command": "bun run queue:work",
    "dir": "./api",
    "autoStart": true,
    "autoRestart": true,
    "env": {
      "NODE_ENV": "development"
    }
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `command` | `string` | required | Shell command to run |
| `dir` | `string` | project root | Working directory, relative to project root |
| `autoStart` | `boolean` | `false` | Start automatically when the workspace opens |
| `autoRestart` | `boolean` | `false` | Restart on non-zero exit |
| `env` | `object` | none | Additional environment variables |

String shorthand is equivalent to `{ "command": "<cmd>", "autoStart": false, "autoRestart": false }`.

Processes appear in the inspector's **Processes** drawer with status indicators, port badges, and start/stop/restart controls. Output is captured in a ring buffer and viewable inline.

**Auto-restart** uses exponential backoff (1s, 2s, 4s, ... capped at 30s). Gives up after 5 crashes within 60 seconds.

**Port display:** Processes don't declare their own ports. Forge infers which port a process uses by checking if any `ports` env var appears in the process's `env` or `command` (e.g. `$PORT`).

---

## commands

Declares commands that appear in the inspector's command palette. Each entry can be a command string or a full object:

```jsonc
"commands": {
  "test": "bun run test",
  "seed": {
    "command": "make db-seed",
    "detail": "Reset and seed the database"
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `command` | `string` | required | Shell command to run |
| `detail` | `string` | none | Description shown in the command palette |

String shorthand is equivalent to `{ "command": "<cmd>" }`.

**Precedence:** `forge.json` commands override auto-discovered commands (from package.json, Makefile, etc.) with the same name.

---

## workspace

Lifecycle hooks that run during workspace creation and deletion:

```jsonc
"workspace": {
  "setup": ["bun install", "make db-migrate", "make seed"],
  "teardown": "docker compose down -v"
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `setup` | `string` or `string[]` | none | Commands to run after workspace clone |
| `teardown` | `string` or `string[]` | none | Commands to run before workspace deletion |

Both fields accept a single command string or an array.

**Setup** runs after the clone completes and ports are allocated. All port env vars and `COMPOSE_PROJECT_NAME` are available. Commands run sequentially and stop on first failure.

**Teardown** runs before the workspace directory is deleted. Commands run sequentially but failures don't block deletion. If no teardown is defined and `compose` is configured, Forge automatically runs `docker compose down`.

---

## Examples

### Simple frontend project

```json
{
  "ports": {
    "PORT": 5173
  },
  "processes": {
    "dev": {
      "command": "bun run dev",
      "autoStart": true
    }
  },
  "commands": {
    "test": "bun run test",
    "deploy": {
      "command": "bun run deploy",
      "detail": "Deploy to Cloudflare Workers"
    }
  },
  "workspace": {
    "setup": "bun install"
  }
}
```

### Full-stack project with Docker Compose

```json
{
  "ports": {
    "APP_PORT": { "port": 8000, "detail": "Laravel app" },
    "DB_PORT": { "port": 5432, "detail": "PostgreSQL" },
    "MINIO_PORT": { "port": 9000, "detail": "MinIO S3 storage" },
    "MINIO_CONSOLE_PORT": { "port": 9090, "detail": "MinIO console" }
  },
  "compose": {
    "file": "docker/compose.yaml",
    "autoStart": true
  },
  "commands": {
    "shell": "make shell",
    "logs": "make logs",
    "seed": {
      "command": "make db",
      "detail": "Re-run migrations and seed database"
    }
  },
  "workspace": {
    "setup": [
      "make composer",
      "make db",
      "make bucket"
    ],
    "teardown": "docker compose -f docker/compose.yaml down -v"
  }
}
```

### Minimal -- just commands

```json
{
  "commands": {
    "test": "make test",
    "lint": "make lint"
  }
}
```
