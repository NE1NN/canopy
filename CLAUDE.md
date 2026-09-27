# Canopy

Terminal-first git worktree manager for macOS, driven by AI agents through the `canopy` CLI.
The design lives in `docs/superpowers/specs/2026-09-27-canopy-design.md`.

## Commands

- `make build`, `make test`, `make lint`, `make format`
- `make app` builds `build/Canopy Dev.app` (data in `~/.canopy-dev`)
- `make e2e` drives a dev build through the CLI against a temporary `CANOPY_HOME`
- `make signing-cert` once per machine before `make app`

Use `make test`, not bare `swift test`: Command Line Tools need extra search paths for Swift Testing.

## Layout

- `Sources/CanopyCore`: all logic, no UI. Most tests target this.
- `Sources/CanopyApp`: SwiftUI and AppKit. Keep logic out of views.
- `Sources/CanopyCLI`: the `canopy` client. Talks to the app over `CANOPY_HOME/canopy.sock`.

## Conventions

- Swift 6 language mode with strict concurrency. No warnings.
- Conventional commit prefixes: `feat`, `fix`, `chore`, `docs`, `test`, `refactor`.
- One PR per plan milestone, squash-merged after review.
- Markdown: one sentence per line. No em dashes.
