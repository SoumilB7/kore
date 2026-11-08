# Changelog

Notable changes to Kore, newest first. Versions follow [semver](https://semver.org).

## [0.3.2] - 2026-11-17

### Added
- Move a Claude login between your Mac and a box from the account popup: ⋯ › Move to the box, and
  Move back here. A login is moved, never copied: the box checks the file it got, and only then
  is the Mac's copy deleted. Nothing is run on a login while two copies exist.
- The same login on your Mac and a box shows an amber point, with Keep here or Keep on the box.
  The copy that refreshed last is kept.
- Arsenal: at Act unlimited, a chat can ask another chat a question and get its reply, or fetch a
  file from it, without you in between. Asks and fetches are rate-limited, and secret files are
  refused.
- Phone: a new look across every screen, with landscape and accessibility support. A chat's background
  agents and commands show as symbols on its row.

### Fixed
- Box chats get Kore's tools whatever their Arsenal tier. The tools act once Arsenal is on.
- The message ticks on a chat's right edge light the message you're reading, in chats full of
  messages from other chats and after a compaction.
- Box links and terminals no longer mix up connections after one closes, and a closing link's
  goodbye reaches a client that's still sending.
- Phone: leaving KoreNet is logged, and its tailnet sign-in is kept across updates.

## [0.3.1] - 2026-11-17

### Fixed
- Phone: no more crash right after connecting, when the new chat sheet opened.
- Phone: a permission card shows the command it asks to run.
- Chats open at their end, and nothing is clipped on the left.
- The install line runs on the Mac's built-in bash again. 0.3.0's stopped at "unbound variable".
- Phone: the bar's buttons sit on the bar row, not under the title.

### Added
- Phone: type by voice, and paste files into a message.
- Phone: send while a chat is working; the message waits in line, and the Mac holds it while the
  chat compacts.
- Phone: Revert to here, and tables that fit the screen without cutting a word.
- Phone: close a box window.
- Phone logs, kept for a day: Kore on the Mac gets them with Get logs, and `kore-host devices logs`
  does the same on a box.
- Arsenal: `kore_close` closes a chat by its id, and refuses while closing it would lose work.

### Changed
- Phone: lighter on battery and data. The tailnet carries less, and drafts reach the Mac every 2 s.

## [0.3.0] - 2026-11-15

### Added
- Boxes: Claude and Codex chats on a Linux server or another Mac, with kore-host. A box window
  has the box's files, terminals, git and Arsenal, and its folders sync two ways with a Mac folder.
- KoreNet: your Mac, your boxes and your phone on one private tailnet. A new device waits on an
  Allow card, and the network icon lists them all.
- Kore for Android: your Mac's and boxes' chats on your phone over KoreNet. Approvals and
  questions wait for you there too.
- Arsenal: a chat can open, message, fork and wait on other Kore chats, up to the tier you allow.
- Copy, cut and paste chats and files across windows and boxes. A transfer bar shows each one and
  can cancel it.
- Roll a chat back to any message, in place.
- Signed releases: every file a release carries is in a SHA256SUMS signed with Kore's release key,
  and the installers and updates check it. Boxes keep themselves on the latest release unless you
  turn off Keep boxes updated.

### Changed
- Chats out of sight keep only their newest turns in memory; transcripts scroll and resize
  lighter.
- Usage shows this Mac and your boxes in one line.
- ⌘Q takes two presses or a hold.

## [0.2.3] - 2026-11-01

### Added
- Tab groups: hold a tab over another to group them; each group has a name, a colour and a
  chip that folds it. Close or ungroup a whole group from its menu.
- Remote control: "/" → Remote control turns on the claude or codex CLI's own remote control
  for a chat, with a Remote chip while it's on. It ends on an account switch.
- File tree: ⌘- and ⇧-click multi-select; cut, copy, paste and duplicate; undo and redo for
  file changes; Open in Terminal; Find in Folder; the open file is revealed in the tree.
- A usage mark from 80% of a plan limit, stepping every 5%, that can be dismissed until the
  next step or reset.
- Click a command's box to scroll and select its full input and output.
- A local link that lets an app you allow, once per run, follow and act on your chats.

### Changed
- Plain URLs in replies are links.
- A window follows its folder when the folder is renamed, and offers Locate… if it's gone.
- A sub-agent tab's prompt scrolls with its timeline and folds when long.
- Live agents get distinct shapes; usage rows name the folder a chat belongs to.

## [0.1.1] - 2026-10-25

### Fixed
- In full screen, the tab bar moves down with the title bar when it slides in at the top, so
  tabs stay visible and clickable. Window chrome is checked again after entering or leaving
  full screen and when a display changes.

## [0.1.0] - 2026-10-25

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
