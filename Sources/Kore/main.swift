import Foundation
import KoreCore
import KoreUI

// Started as a CLI's or a shell's trampoline, this becomes that program and goes no further.
Disclaim.execIfAsked()
Disclaim.trampoline = Bundle.main.executablePath
KoreApp.main()
