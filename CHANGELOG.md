# Changelog

Notable changes to Kore, newest first. Versions follow [semver](https://semver.org).

## [0.3.10] - 2026-11-26

### Added
- Copy and paste a chat: Copy or Cut on a tab's right-click or a History row, then Paste Chat (or
  ⌘V outside a text field) in any window, on this Mac or a box. The phone can do it too: Copy on a
  chat or a History row, Paste chat on a window of any device; the Mac makes the copy. A copy the
  phone asked for starts at Manual at most, with Arsenal and Plan's allow switch off, and stays
  there through restarts and moves until you pick a higher mode on the Mac.
- Resume after a close: chats that were working when Kore quit or crashed are offered once, in
  one quiet line, when their window opens again. Resume sends each picked chat a short note to
  carry on ("Resume with sub-agents" when some were running).
- File copies and sync with a box run over KoreNet with `kore pipe`, so a box needs no SSH for
  them; with Tailscale gone, box SSH and sync follow Kore's tailnet.
- Phone: long-press a chat to Pin it; pins are the phone's own and sit at the top of that
  device's list.
- Arsenal arranges tabs: a chat can group, move, fold, rename and show the tabs in its own window
  (`kore_arrange`, `kore_show_tab`), and its list of chats shows each window's tab order, front
  tab and groups. Your own groups stay unless you asked for the change.
- Arsenal sets a chat's auto-compact point (50 to 90 %, or off), as the context wheel does
  (`kore_set_compact`).
- Box chats add Claude accounts on the box itself, each signed in its own folder there; a box's
  Codex keeps its one login.
- Terminal keys work as in Terminal.app: ⌘←/⌘→ to the line's start and end, ⌘⌫ deletes to the
  line's start, ⌘K clears, ⌥-click moves the cursor on the prompt's line, and ⌥ types what the
  keyboard layout puts on a key. ⌘C copies the selection as shown. Text typed or pasted while a
  shell is still starting waits for its prompt instead of echoing twice. A program in the terminal
  can't read your clipboard.
- Box host keys in Set up: a new key shows its fingerprint with Trust · Copy · Check again; a
  changed key says it could be an attack and offers no Trust; an alias that now points at a new
  address says so.

### Changed
- Kore asks its questions in its own card over the window (unsaved files, closing a busy tab,
  removing things), and hover tips are Kore's own; no more macOS alerts.
- A chat left idle for 10 minutes rests its CLI and gives its memory back; the next message or a
  key typed in its composer starts it again on the same session, transcript kept.
- A box's name is your Devices rename, else the box's own name, never its SSH alias. Its row
  shows the route in use ("· Kore's tailnet", "· Tailscale" or "· SSH (alias)"); the hover shows
  the node and address, and ⋯ can Forget the SSH route.
- Devices has one +: Add a box or Add a phone (which turns KoreNet on first if it's off). Kore's
  tailnet and "Update boxes automatically" sit at the pane's foot.
- The agent map lists one line per agent, with counts of running and done ones, and a failed
  agent says why at its end. Clicking a tab closes the map.
- New tabs open after the front tab's group instead of splitting it; a group stays whole.
- History marks the chat the current tab shows. A usage window not begun yet keeps its row at 0 %,
  "Starts with your next message".
- A background command's output in the terminal is shown whole and only grows, instead of
  redrawing from the top.
- A code block's Copy is always there, faint until you point at the block.
- Phone: question cards show whole, with a scrollbar instead of fades; hold an option to read it
  in full.
- Phone: links stay up for a few minutes while the app is off screen, so coming back is instant.
- Arsenal's list says when a chat can't be driven because it was told Always allow and the caller
  wasn't.

### Fixed
- Past box sessions opened from History show their history at once, not an empty chat until a
  send.
- Arsenal opening a chat, or a box chat landing on this Mac, can no longer come up in a freer
  mode than its history or the chat that asked for it.
- Long chats jump less while you read and while an answer streams, and the message rail lights
  the message you're on after a send.
- A trackpad pinch no longer snaps the page back, and the editor keeps its sideways scroll when
  zoomed.
- Numbered lists that start past 1 ("5.", "6.") stay lists, on the Mac and the phone.
- Panes floating over a narrow window close on a click elsewhere, and their icon's first press
  opens them.
- "Always ask for these in my settings" with an added Claude login writes to the settings that
  login reads, and no longer parts its linked settings file from the main one.
- Right-clicking the empty end of the tab strip opens its menu again.
- A box host key is compared by the key itself, so a reordered or hashed known_hosts no longer
  looks like a new key.
- A dead SSH link to a box ends with a line saying so instead of waiting.
- TODO(Resource): terminal busy on a slow shell start; box probe line.

## [0.3.9] - 2026-11-24

### Changed
- Kore's own tailnet and your boxes stay connected whatever happens to Tailscale or SSH:
  - a box tells the Mac every node it has, and the Mac tries them all, online ones first;
  - when a box's Tailscale stops, the Mac follows it onto Kore's tailnet in seconds and back
    when Tailscale returns;
  - a link that stops answering is noticed in about 15 s while its window is open, then SSH
    takes over;
  - SSH itself rides Kore's tailnet when Tailscale is gone, so plain SSH, Tailscale IPs,
    MagicDNS, Tailscale SSH, jump hosts and other ports all keep working;
  - "Reconnecting…" says which route it's trying, and stops with "Can't reach <box> · tried the
    tailnet and SSH" instead of spinning.
- Kore's tailnet sign-in shows on the first page (Welcome and the title row) with Sign in right
  there, and the network icon gets a dot while a device needs it. A sign-in that's removed or
  expires says so within seconds.
- Arsenal on shows the chat's logo, spinner and `>_` in Arsenal blue again (not tab corners), in
  History too, closed chats included.

### Fixed
- Setting up a box no longer hangs on boxes where kore-host's start inherited a socket, and
  kore-host keeps running on boxes without systemd linger.
- A box starting before its Tailscale waits for it instead of starting a second node.
- Phone: box chats render Markdown (tables, bold, lists, code, links) and links open on a tap.
- Phone: taking a photo or picking a file no longer drops the link, and the attachment is never
  lost, even if Android closes the app meanwhile.
- Phone: a box that changes tailnets is redialled at once, not after minutes.

## [0.3.8] - 2026-11-23

### Added
- Right-click a Recent folder on the Welcome screen: Remove from Recent (this Mac and boxes).
- `scripts/live-check.sh`: a short look at every screen, the network paths and a box, one line each.

### Changed
- New box… on a box without Tailscale: `kore-host join` prints Kore's tailnet sign-in page and
  waits for it, then the claim code; on the Mac the box's row follows it to "Ready · Kore's
  tailnet: signed in as …", opening the page here if the box asks.
- Kore's own tailnet is the main connection on your Mac and boxes; Tailscale takes over only while
  it runs. Kore's tailnet signs in once (during box setup, or "Sign in to Kore's tailnet" on the
  Mac), then waits stopped while Tailscale runs, so a quit switches with no sign-in. One node each,
  named "<host>-kore".
- Kore's tailnet shows its state everywhere: a box's row, its card and this Mac's row say "signed
  in as …", or "signed out · Sign in" the moment it signs out or its key expires.
- Arsenal on marks the tab with blue corners, like option popups; the logo, spinner and `>_` keep
  their own colours.
- The message rail is 0.3.6's again: a short run of ticks around the message you read, the same
  size in any window, never lighting the last message while you read further up; a tick for
  earlier history lands on that message.
- Copying part of one paragraph, point or cell gives just the text you selected: no list number,
  no `**`, backticks or link address. Across two or more points or blocks it's Markdown. Links copy
  as their text everywhere, tables included.
- A box's Recent lists its folders, one row each, like this Mac's.
- A box's card counts only what Fix does; a newer CLI on the box, skills, MCP servers and default
  models are quiet notes. Downloads time out with one line saying why.

### Fixed
- Files on a box open like files here: spreadsheets, documents, slides, PDFs, video and large
  images preview instead of "This file is binary" (a box needs kore-host 0.3.8). Over 50 MB, the
  tab offers Download. Box images near 1 MB no longer drop the link.
- A message rail click no longer snaps back to the end while an answer streams after a send, and
  a jump to a far message lands on it instead of short of it.
- A box whose Tailscale stops moves to Kore's tailnet instead of waiting.
- After a key change, a box that doesn't know this Mac's new key keeps the link on SSH, takes the
  key there, then moves back to the tailnet, instead of dropping it.
- Tabs, tab groups and some settings weren't saved after Kore was installed or updated (it took
  itself for a dev build); groups on box windows are kept too.
- Adding a box over SSH no longer says "try again" once before it goes through.
- A box's card checks again after an install, and says why it couldn't read a CLI's account.
- The Welcome "+" list no longer flickers or covers "This Mac"; the first Recent row isn't cut off.

## [0.3.7] - 2026-11-22

### Added
- Shift-click selects a run of tabs, Cmd-click picks single ones; right-click groups them ("Group
  N Tabs", "Add N Tabs to Group"), closes them (Cmd-W, Cmd-Shift-T brings all back) or drags them together.
- `kore new --folder <path>` (Arsenal's Act device tier) opens a chat in another folder or box folder,
  and `--silent` opens or wakes a chat without moving your focus; the chat picks which from what you asked.
- Chats with Arsenal on show their CLI logo, working spinner and terminal cue in Arsenal's blue.
- Claude chats have Full access, as Codex chats do: edits and every command without asking (Claude's
  bypass permissions). Only you put a chat in it: phones and links stop at Auto, and Arsenal never
  raises a chat past the one asking. Picking it starts Claude again in it, between turns.
- Your Mac (full control of a box) can put box chats in Full access; phones and other chats stop
  at Auto. A box running kore-host as root says Full access can't run there.
- Builds and tests run by chats count as "Kore Dev", not Kore, in Battery and Activity Monitor;
  a dev build of the app is "Kore Dev" with its own settings, chats and keys.

### Changed
- When the installed Tailscale quits or signs out, Kore and kore-host move to their own tailnet
  beside it, and back when it returns; boxes and phones follow without a new Allow.
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
- Full access is never remembered as the default mode for new chats; Auto and the rest still are.
- Auto no longer holds a chat on Kore's own list: Claude's own check decides; if a chat stops because a command was refused, a card offers Run once / Always allow.

### Fixed
- The message rail maps the whole chat: its ticks follow where each message is, so the right
  side no longer jumps or bunches while you scroll a long chat.
- A fork is named "<chat> (fork)", then "(fork 2)", "(fork 3)"…, and keeps that name.
- A phone whose Mac moved between Tailscale and Kore's own tailnet dials the node that's online,
  not "Asleep".
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
- "/" commands: `/config` and `/heapdump` refused from the phone and boxes; Codex `/plan` from the
  link checked like the plan switch; typed `/model`, `/effort`, `/fast` move Kore's pickers; `/clear`
  starts a fresh chat on Claude's new session; Codex gains `/review`, `/init`, `/goal clear`; commands
  that don't work in Kore are no longer listed; the phone sends Codex skills as `$name`.
- Usage bars show "outside Kore" only when the plan rose with no Kore request from that login on
  this Mac, a box or a paired Mac.
- A chat in a window you can't see no longer draws while it streams: several streaming chats cost
  about twice one, not nine times.

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
