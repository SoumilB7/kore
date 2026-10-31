import Foundation
import KoreCore
import KorePhone
import KoreUI

// Kore Phone: Kore as `Sources/Kore/main.swift` starts it, with the phone remote installed.
Disclaim.execIfAsked()
if let status = CLIExecutable.headless(CommandLine.arguments) { exit(status) }
Disclaim.trampoline = Bundle.main.executablePath
UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 900])
MainActor.assumeIsolated { KorePhone.install() }
KoreApp.main()
