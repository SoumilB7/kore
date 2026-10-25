# Changelog

Notable changes to Kore, newest first. Versions follow [semver](https://semver.org).

## [0.1.0] - 2026-11-01

First release.

### Chats
- Claude and Codex chats in tabs, one window per folder; a folder's tabs reopen as they were left.
- The history clock lists every chat the CLIs have for a folder, with search, rename and archive.
- Streaming answers, thinking, tool calls with diffs, and a per-turn summary of changed files.
- Approvals, questions, plan mode and plan approval, in each CLI's own wording.
- Modes, models, effort and fast mode; slash commands.
- Queued messages while a turn runs, retry for failed turns, fork from any message, compaction.
- Unsent drafts and attachments survive closing a tab or quitting; ⇧⌘T reopens closed tabs.
- Continue a chat in the other CLI: Claude to Codex and Codex to Claude.

### Agents and commands
- A live map of sub-agents, with each agent's own transcript.
- Background commands with their output; send a long command to the background, or stop it.

### Files
- Explorer with git status, drag-to-move, and quick open (⌘P) with go to line (⌃G).
- Editor with syntax colour, find, folding, change bars, and autosave that respects edits made
  elsewhere.
- Viewers for Markdown, JSON, CSV/TSV, notebooks, Mermaid, PDF, images, audio/video and hex.
- Folder-wide text search (⇧⌘F).

### Workspace
- Boards: chats, files and terminals split side by side in one window.
- Built-in terminal (⌃\`).
- Accounts: sign in, sign out and switch accounts for both CLIs.
- Usage: plan limits and reset times, read without spending a turn.
- Attachments by paste, drop or `+`, with an image editor for markup.
- Install a missing `claude` or `codex` CLI from a new tab.
- Stay-awake while chats work; a notice when the network drops.
- The `kore` command: `kore <folder>` opens a folder, `kore setup` installs missing CLIs.

[0.1.0]: ../../releases/tag/v0.1.0
