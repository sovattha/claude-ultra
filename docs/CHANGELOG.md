# Changelog

All notable changes to Claude Ultra are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-01-14

### Changed
- Removed sequential mode, simplified to fast-only pipeline

### Added
- `--persistent`/`--no-stop` option to prevent auto-stop

### Fixed
- Initialize `diff_summary` before conditional block in fast-mode
- Prevent infinite loops in auxiliary Claude calls (timeout fix)
- Improve error handling in `run_step` to avoid false positives
- Improve test runner detection and prevent interactive blocking

### Documentation
- Add test running instructions to prevent watch mode blocking

### Chore
- Add `logs/` to `.gitignore`

## [1.0.1] - 2026-01-12

### Added
- Enforce mocking of DB/network connections in test prompts
- `SKIP_TESTS` option to bypass test execution
- Autonomous mode with spec, validation, rollback and reporting (enterprise)

### Fixed
- Add timeout and non-interactive mode for `npm test`

## [1.0.0] - 2026-01-04

### Added
- Fast mode for single-call task completion (`--fast`)
- Parallel mode with Git worktrees and tmux (`--parallel`)
- `--resume` mode to recover interrupted parallel agents
- Auto-merge orphan branches and completed agents
- Lock mechanism to prevent race conditions in parallel mode
- `CLAUDE.md` for Claude Code guidance

### Fixed
- Detect commits made by Claude in fast mode
- Use `@agent-task.md` in worktrees to prevent `TODO.md` overwrite

## [0.1.0] - 2026-01-02

### Added
- Initial release with claude-ultra pipeline
- 8-persona workflow (PO, Architect, Implementer, Refactorer, QA, Security, Documenter, Committer)
- TDD-first approach with Clean Architecture principles
- Bilingual documentation (EN/FR)
- Credit section for inspirations

[Unreleased]: https://github.com/sovattha/claude-ultra/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/sovattha/claude-ultra/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/sovattha/claude-ultra/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/sovattha/claude-ultra/compare/v0.1.0...v1.0.0
[0.1.0]: https://github.com/sovattha/claude-ultra/releases/tag/v0.1.0
