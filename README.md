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
# Folder mode (recommended)
ralph --prd .spec/prds/my-feature

# File mode
ralph --prd tasks.json
ralph --prd PRD.md

# Options
ralph -a opencode --prd .spec/prds/my-feature -n 0   # unlimited iterations
ralph --prd .spec/prds/my-feature --safe              # prompt for permissions
```

### Options

| Flag | Description |
|------|-------------|
| `-a, --agent <name>` | AI engine: `claude`, `opencode` (default: claude) |
| `-m, --model <name>` | Model to use (e.g., sonnet, opus) |
| `--prd <path>` | PRD file or folder (default: PRD.json) |
| `-n, --max-iterations <n>` | Max tasks to run, 0 = unlimited (default: 2) |
| `--log-lines <n>` | Number of log lines to display (default: 50) |
| `--safe` | Disable auto-permissions (prompts user) |
| `--prompt <file>` | Override prompt template with file contents |
| `-h, --help` | Show help |

## PRD Formats

### Folder Mode (Recommended)

Point `--prd` at a folder containing `tasks.json`:

```
.spec/prds/my-feature/
├── prd.md        # Optional: full PRD context
├── tasks.json    # Required: task definitions
└── progress.txt  # Created by ralph
```

### JSON Nested (tasks.json)

```json
{
  "prdName": "my-feature",
  "tasks": [
    {
      "id": "ui-1",
      "category": "ui",
      "description": "Add syntax highlighting",
      "steps": [
        "Shiki package installed",
        "Code renders with highlighting",
        "Supports light and dark themes"
      ],
      "passes": false
    }
  ],
  "context": {
    "patterns": ["src/components/code.tsx"],
    "keyFiles": ["src/app.tsx"],
    "nonGoals": ["Code editing"]
  }
}
```

- `passes`: Set to `true` when all verification steps pass
- `steps`: Verification steps (how to TEST, not how to build)
- `context`: Patterns, key files, and non-goals guide the agent

### JSON Flat

```json
[
  {
    "name": "Create user authentication",
    "description": "Implement login/logout with JWT tokens",
    "passes": false
  },
  {
    "name": "Setup project structure",
    "passes": true
  }
]
```

**Note:** All tasks must have a `passes` field (boolean).

### Markdown

```markdown
# My Project PRD

## Tasks

- [ ] Create user authentication with JWT
- [ ] Add password reset flow
- [ ] Write unit tests for auth module
- [x] Setup project structure (completed)
```

## How It Works

1. Ralph reads your PRD file/folder and finds the first incomplete task
2. Sends the task to the AI agent (Claude or OpenCode)
3. Agent implements the task, writes tests, runs linting
4. Agent marks the task complete in the PRD
5. Repeats until all tasks are done or max iterations reached

### Nested Format Workflow

For `json-nested` format, the agent:
1. Reads `context` for patterns, key files, and non-goals
2. Finds first task with `passes: false`
3. Implements until ALL `steps` are verified
4. Sets `passes: true` when complete
5. Appends learnings to `progress.txt`

If `prd.md` exists in the same folder, the agent reads it for full context.

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
