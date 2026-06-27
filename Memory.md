# Project Memory

> Persistent context for the `vegasblackcard/vegasblackcard` repository.
> Claude Code sessions are isolated and share no memory between runs — this file
> is the durable handoff. Read it at the start of a session; update it at the end.

## What this repo is

This is `vegasblackcard`'s GitHub **profile repository** (its `README.md` renders on
the GitHub profile page). It also hosts a small shell tool:

**RC Config — Remote Access Manager**: a lightweight, shell-based tool for
managing SSH remote connections, tunnels, and file syncing.

## Files

| File           | Purpose                                                        |
| -------------- | ------------------------------------------------------------- |
| `README.md`    | GitHub profile page + RC Config quick-start docs              |
| `rc-config.sh` | The tool. `source` it to get the `rc` command.                |
| `.remoterc`    | User config: hosts, tunnels, SSH settings.                    |
| `Memory.md`    | This file — cross-session context.                            |

## Using the tool

```bash
source rc-config.sh
rc hosts                          # List configured hosts
rc connect dev                    # SSH into a host
rc tunnel db dev                  # Open a port-forwarding tunnel
rc sync staging ./app /opt/app    # Rsync files
rc check                          # Validate config, SSH key, host entries
rc help | version
```

## Current state (as of 2026-06-27)

- The RC Config work is **complete and merged into `main`** (commit `f3a439e`).
- `main` history: RC config support → hardening for safe sourcing/host parsing →
  config `check` command + config-load/retry bug fixes.
- No open PRs; no work in progress.

### Key behaviors baked into `rc-config.sh`
- `rc help/version/check` work **without** a `.remoterc` present (config is no
  longer loaded on every invocation).
- `rc connect` only retries on SSH connection failures (exit 255); a non-zero
  exit from the *remote* command is passed through, not retried.
- Unknown commands report the error and show help.

## Working agreements / notes

- Designated dev branch for Claude sessions: `claude/previous-session-status-xvqmn6`.
- Sessions cannot read each other's transcripts (e.g. `claude.ai/code/session_...`
  links are private and return 403). To carry knowledge forward, put it **here**.
- Keep this file current: append durable facts, decisions, and gotchas at the end
  of each session.
