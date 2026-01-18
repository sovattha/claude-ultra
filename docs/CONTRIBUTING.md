# Contributing to Claude Ultra

Thank you for your interest in contributing to Claude Ultra! This document provides guidelines and instructions for contributing.

## Getting Started

1. Fork the repository
2. Clone your fork locally
3. Create a feature branch from `main`

```bash
git checkout -b feat/your-feature-name
```

## Development Workflow

### Prerequisites

- Bash 4.0+
- [Claude CLI](https://github.com/anthropics/claude-code) installed and configured
- tmux (for parallel mode)
- Git

### Running the Pipeline

```bash
# Fast mode (recommended for development)
./claude-ultra.sh --fast

# With custom task file
TASK_FILE=my-tasks.md ./claude-ultra.sh --fast
```

### Running Tests

Always use non-interactive mode to prevent blocking:

```bash
# Vitest (preferred)
npm test -- --run

# Jest
npm test -- --watchAll=false --ci

# Generic fallback
CI=true npm test
```

## Code Style

### Bash Scripts

- Use `set -uo pipefail` at the start
- Quote all variables: `"$var"` not `$var`
- Use lowercase for local variables, UPPERCASE for exports/constants
- Functions should be max 50 lines
- Add comments for complex logic only

### General Principles

- **TDD**: Write tests first (RED → GREEN → REFACTOR)
- **Clean Architecture**: Separate concerns, pure functions when possible
- **KISS**: Keep it simple, avoid over-engineering
- **DRY**: Don't repeat yourself, but don't abstract prematurely

## Commit Convention

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
type(scope): description
```

### Types

| Type | Description |
|------|-------------|
| `feat` | New feature |
| `fix` | Bug fix |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `docs` | Documentation only changes |
| `test` | Adding or updating tests |
| `chore` | Maintenance tasks |

### Examples

```bash
feat(parallel): add conflict detection between tasks
fix(fast-mode): prevent infinite loop on timeout
docs(readme): add installation instructions
refactor(merge): simplify conflict resolution logic
```

## Pull Request Process

1. **Create a focused PR**: One feature or fix per PR
2. **Update documentation**: If your change affects usage, update relevant docs
3. **Test your changes**: Ensure all tests pass
4. **Follow the template**: Fill out the PR description completely

### PR Checklist

- [ ] Tests added/updated and passing
- [ ] Documentation updated if needed
- [ ] Commit messages follow convention
- [ ] No secrets or credentials in code
- [ ] Code follows project style

## Project Structure

```
claude-ultra/
├── claude-ultra.sh      # Main pipeline script
├── TODO.md              # Task list
├── CLAUDE.md            # Claude Code guidance
├── ARCHITECTURE.md      # Architecture decisions
├── docs/
│   ├── CHANGELOG.md     # Version history
│   ├── CONTRIBUTING.md  # This file
│   ├── architecture.md  # Detailed architecture
│   ├── personas.md      # Persona descriptions
│   ├── parallel-mode.md # Parallel mode docs
│   └── troubleshooting.md
└── logs/                # Runtime logs (gitignored)
```

## Control Files

| File | Purpose |
|------|---------|
| `TODO.md` | Task list with `- [ ]` / `- [x]` format |
| `@fix_plan.md` | Priority fixes (optional) |
| `@AGENT.md` | Custom agent configuration (optional) |
| `@agent-task.md` | Per-worktree task in parallel mode |

## Security

- Never commit secrets or API keys
- Validate all inputs
- Use environment variables for sensitive configuration
- Report security vulnerabilities privately

## Questions?

- Check [troubleshooting.md](./troubleshooting.md) for common issues
- Open an issue for bugs or feature requests
- Start a discussion for questions

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.
