# Canopy

A terminal-first git worktree manager for macOS.
Each worktree is a row in the sidebar, each row has tabs, and each tab holds a grid of terminals.
Agents drive it through the `canopy` CLI: create rows, open terminals, run commands, and read screens.

## Build

Requires macOS 15 or later and Swift 6.2 or later. Command Line Tools are enough; Xcode is not required.

```
make signing-cert   # once per machine
make app            # build/Canopy Dev.app
make install        # ~/Applications/Canopy.app and ~/.local/bin/canopy
```

## Develop

```
make test
make lint
```
