# Changelog

Notable changes to Kore, newest first. Versions follow [semver](https://semver.org).

## [0.3.7] - 2026-11-22

### Added
- Claude chats have Full access, as Codex chats do: edits and every command without asking (Claude's
  bypass permissions). Only you put a chat in it: phones and links stop at Auto, and Arsenal never
  raises a chat past the one asking. Picking it starts Claude again in it, between turns.

### Changed
- Kore makes no Keychain call at all. KoreNet's identity and tailnet keys live in files only you
  can read, in Kore's own support folder; this Mac gets a new identity key, never reading the old one. Boxes
  set up over SSH take the new key by themselves; phones show "Key changed · Pair again" and
  pair again through Add device.
- A Claude API key typed in Kore goes to a file only you can read, which Claude's helper prints. A key saved by
  an older Kore asks once: "Enter your API key again: Kore no longer uses the Keychain".
- Claude logins aren't copied between devices any more: "Sign in on mybox" runs Claude's own
  sign-in on the box, its page opened here; "Sign in here" brings a moved one back the same
  way. Nothing is logged out. Codex logins move as before.
- Update a box before its Mac: a box on 0.3.6 can't take the Mac's new key; its row says "update
  kore-host on <box>". A box claimed over the tailnet with no SSH says what to run there.
- Kore's own tailnet needs signing in again after the key change (its old state can't be opened);
  the Devices line says so, and the old node stays in the Tailscale admin console until removed.
- "Sign in on mybox" signs in to an account of its own on the box, never the box's main login.

### Fixed
- Set up on a box again no longer locks its Mac out: the box keeps the grant tied to that Mac, and
  takes the Mac's new key on a grant issued again.
- A phone whose Mac's key changed shows "Key changed · Pair again" instead of retrying forever.
- Two Kore processes making a key at once agree on one; a secrets file others can read names its fix.
- `/rename <name>` is in Claude chats' command menu on the Mac, a box and the phone, and renames
  the chat in Kore and Claude together, without waking a sleeping box chat.
- Auto asks you before more of what it shouldn't run alone: removals of the working folder or a
  parent, removals by path, `env`, `xargs`, `find -delete`, subshells and `sh -c`, downloads into a
  shell by any route, and removals of files Kore can't see (from `$(…)`). Those used to end as an
  "Auto stopped" card with only OK; now you get Run once. Always allow keeps the exact line for
  sudo, shells and interpreters, never `sudo bash *`.
- A chat can't allow commands in a chat it started. Chats made from the phone or by another chat
  never start in Full access, and a Full access chat moved to a box runs there in Auto.
- Picking a lower mode while Full access restarts Claude sticks, and the pill shows the real mode.
- Box chats: a rollback from the Mac no longer loses a message the phone sent at that moment; a
  message held during a rollback isn't shown twice; a rename while the CLI sleeps isn't undone
  when it starts; settings changed on a chat this Mac holds wait for it.
- A turn that ended before the chat showed anything no longer crashes Kore or kore-host.
- Phone: a failed send keeps your text and files (uploads again when they expired); selecting text
  while output streams holds still; a timed-out action is never sent later; the folder browser
  retries; "Not connected" before the first welcome.
- The table Copy button sits beside the table's corner, never over a cell; a tab's "Stop turn?"
  shows at once and Stop works on the first click; an empty `/rename` leaves "/rename " to finish.

## [0.3.6] - 2026-11-21

### Added
- Tables get a Copy button in their corner while you hover; it copies what selecting the table
  copies, and takes no room.

### Fixed
- Switching tabs no longer redraws every chat kept open in the background; switches are a
  little faster.
- Always allow works in box chats: the rule lands in the box project's settings and the box
  stops asking for that kind of command. Not for removals of the folder, home or system paths.

## [0.3.5] - 2026-11-21

### Added
- Arsenal has an Act device tier: a chat can fetch files from another of your devices.
- A box answers its own chats' Arsenal calls, without the Mac; the tier is kept on both sides.
- Phone: create a folder on a box from New → Window, open History from +, upload files to box
  chats, and see their images, diffs and earlier messages.
- Phone: select part of a message, answer, code block or table cell; Message… opens the menu.
- ⌘+ and ⌘− scale the whole window, file explorer included.
- `kore send` reaches a closed chat in its folder: it reopens the chat, then sends.
- Arsenal can answer another chat's Auto asks card: Run once or Always allow, from a chat at Auto
  with Act unlimited or above. Removing the working folder, a home or system path stays yours.

### Changed
- Allowing a command on the phone is a plain tap; the fingerprint is only for raising a mode
  or an Arsenal tier.
- Older releases stay on GitHub when a new one is published.
- The same action has the same words on the Mac, the box and the phone.
- Copies, moves and forks keep the chat's settings: model, effort, mode, fast, plan, auto-compact
  point, login and Arsenal tier; a move takes the draft too.

### Fixed
- Auto asks far less often. A script a chat only writes (heredoc text) no longer counts, and a
  removal whose path the same command sets, or that sits under `$HOME` or `$TMPDIR`, is judged as
  the path it is. Your home folder, system paths and unknown variables still ask.
- Queued messages are sent in the order you queued them.
- `/rename` renames the chat in Kore too, on every device, and a chat never shows an empty title.
- A rollback reaches every device showing the chat, and a moved or copied chat resumes from it.
- "On mybox" shows only for a login Kore actually moved there.
- Box chats show the context meter, copied ones too.
- Box chats keep model, effort, mode, plan and fast mode in step on every device, through
  restarts; queued messages come back to you when a box chat closes or the box restarts, and
  stale cards clear.
- Slash commands work in a box chat whose CLI is asleep.
- Box cards follow Auto's asks as the Mac's do.
- The phone follows new output to the end, with ↓ New when you've scrolled up.
- The phone shows the reason when something is refused, and no Group or Board in box windows.

## [0.3.4] - 2026-11-20

### Changed
- Always allow on an Auto asks card keeps the kind of command (`sudo apt install …`) in the
  project's `.claude/settings.local.json`, and Auto stops asking about it in every chat there.
  Removing the working folder, home or system folders is never covered.

### Fixed
- Kore no longer asks for your login keychain password over and over. It reads a Claude login
  from the Keychain only when you click Move, Move back or Keep; usage and switching go through
  Claude as before. Seeing the same login on two devices now goes by its account, not its token.
- A question with one answer holds one pick: choosing an option after Other clears Other, and
  Other's words are sent only when Other is the pick. On the phone too.

## [0.3.3] - 2026-11-19

### Added
- Auto asks before a risky command (rm -r/-f on a variable, home or system path, sudo, Keychain
  reads, curl into a shell): Run once, Deny, Always allow this command, or Always ask for these in
  your settings. Only you can run it; a chat can only deny. Removals Auto never runs say why.
- A message another chat sent that Claude held shows as a card: Let it in or Deny.
- Move a Codex login between your Mac and a box, and move logins between two Macs once they pair
  with an Allow card.
- Phone: account usage per login (5 h and week) on each device and in a chat's sheet.
- Phone: close windows and tabs, open a chat from History in this window, tap an image to see it,
  pick several photos at once, and see a chat's current step while it works.
- A chat running only a background command shows `>_` in its CLI's colour.
- Box chats get the `kore` command, and can ask a Mac chat a question.

### Fixed
- A box listens for your phone after a reboot, without waiting on Tailscale.
- Box chats' Kore tools answer as a Mac chat's do: same waits, same errors.
- Copy, Fork and Revert work while zoomed in, and a code block's Copy stays in view.
- A tab comes back where you left it; a window resize keeps your place.
- The message ticks stay put as the box you type in grows.
- Tab names keep at least four characters before the overflow menu takes over.
- Rolling back keeps the context meter.
- Chats you can't see do far less work while they stream.
- A phone reconnecting to a box gets its welcome before anything else.

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
