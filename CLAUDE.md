# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claude Ultra is an autonomous CI/CD pipeline powered by Claude AI. It uses expert personas (Product Owner, Architect, Implementer, QA, Security, Documenter, Committer) to process tasks from `TODO.md` with strict TDD and Clean Architecture principles.

## Commands

```bash
# Sequential mode (default) - one task at a time through 8-persona pipeline
./claude-ultra.sh

# Fast mode - single unified call per task (~7x faster)
./claude-ultra.sh --fast

# Parallel mode - N agents on N tasks via Git Worktrees + tmux
./claude-ultra.sh --parallel -a 5

# Parallel + Fast - fastest option for multiple tasks
./claude-ultra.sh -p -f -a 5

# Resume interrupted parallel agents
./claude-ultra.sh -p -f -r
```

## Architecture

**Three execution modes:**
- **Sequential**: 8 personas execute in order (PO → Architect → Implementer → Refactorer → QA → Security → Documenter → Committer)
- **Fast**: All personas combined into single Claude call per loop
- **Parallel**: N isolated Git worktrees, each running its own pipeline, merged via AI Merger Agent

**Key functions in `claude-ultra.sh`:**
- `run_fast_mode()` - Unified prompt execution loop
- `run_parallel_mode()` - Worktree creation, tmux management, agent launching
- `merge_worktree()` / `resolve_conflicts()` - Git merge and AI conflict resolution
- `analyze_task_conflicts()` - Pre-launch conflict detection between tasks

**Control files:**
- `TODO.md` - Task list (`- [ ] task`)
- `@fix_plan.md` - Priority fixes (optional)
- `@AGENT.md` - Custom agent config (optional)
- `@agent-task.md` - Per-worktree task file in parallel mode

## Code Patterns

- All personas are defined as heredoc strings (e.g., `PERSONA_PO`, `FAST_PROMPT`)
- Claude CLI called via `claude -p $CLAUDE_FLAGS --output-format stream-json`
- Usage tracking via `update_usage_from_result()` parsing JSON responses
- Worktrees created in `.worktrees/agent-N/` with branches like `agent-0/task-name`

## Git Commit Convention

Use conventional commits: `type(scope): description`
- Types: feat, fix, refactor, docs, test, chore
- Do NOT add Co-Authored-By or Generated-with footers
