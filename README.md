# Ralph

Autonomous AI coding loop that works through tasks in a PRD file until all are complete.

```
✓ [1/4] Create user authentication completed [00:45]
✓ [2/4] Add database migrations completed [01:12]
⠸ [3/4] Write API endpoints [00:23]
```

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/USER/ralph/main/install.sh | bash
```

Or manually:
```bash
curl -fsSL https://raw.githubusercontent.com/USER/ralph/main/ralph.sh -o /usr/local/bin/ralph
chmod +x /usr/local/bin/ralph
```

### Requirements

- `jq` - JSON parsing
- `claude` or `opencode` CLI - AI agent

## Usage

```bash
ralph -a claude --prd specs/prd.md
ralph -a opencode --prd tasks.json -n 0   # unlimited iterations
ralph --prd PRD.md --safe                  # prompt for permissions
```

### Options

| Flag | Description |
|------|-------------|
| `-a, --agent <name>` | AI engine: `claude`, `opencode` (default: claude) |
| `-m, --model <name>` | Model to use (e.g., sonnet, opus) |
| `--prd <file>` | PRD file path (`.json` or `.md`) |
| `-n, --max-iterations <n>` | Max tasks to run, 0 = unlimited (default: 2) |
| `--log-lines <n>` | Number of log lines to display (default: 50) |
| `--safe` | Disable auto-permissions (prompts user) |
| `--prompt <file>` | Override prompt template with file contents |
| `-h, --help` | Show help |

## PRD Formats

### Markdown (recommended)

```
# My Project PRD

## Tasks

- [ ] Create user authentication with JWT
- [ ] Add password reset flow
- [ ] Write unit tests for auth module
- [x] Setup project structure (completed)
```

### JSON

```json
[
  {
    "name": "Create user authentication",
    "description": "Implement login/logout with JWT tokens",
    "done": false
  },
  {
    "name": "Setup project structure",
    "done": true
  }
]
```

**Note:** All JSON tasks must have a `done` field (boolean).

## How It Works

1. Ralph reads your PRD file and finds the first incomplete task
2. Sends the task to the AI agent (Claude or OpenCode)
3. Agent implements the task, writes tests, runs linting
4. Agent marks the task complete in the PRD
5. Repeats until all tasks are done or max iterations reached

## Testing

```bash
# Install bats
brew install bats-core  # macOS
sudo apt install bats   # Ubuntu

# Run tests
bats tests/ralph.bats
```

## License

MIT
