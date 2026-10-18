import Foundation

/// Runs user storylines inside the app (phase 12): `kore-storylines` installs it, then starts
/// Kore as usual. The engine (storylines, steps, waits, the report and the runner) lands here.
@MainActor
package enum StorylineHost {
    /// Called by `kore-storylines` before `KoreApp.main()`, with the process's arguments.
    package static func install(arguments: [String]) {}
}
