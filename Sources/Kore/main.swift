import Foundation
import KoreCore
import KoreUI

// Started as a CLI's or a shell's trampoline, this becomes that program and goes no further.
Disclaim.execIfAsked()
// `--locate-cli claude|codex` (`kore setup`): the binary Kore would run, printed, with no window.
if let status = CLIExecutable.headless(CommandLine.arguments) { exit(status) }
Disclaim.trampoline = Bundle.main.executablePath
// Tooltips (a tab's full name) at 90% of the system's usual second.
UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 900])
KoreApp.main()
