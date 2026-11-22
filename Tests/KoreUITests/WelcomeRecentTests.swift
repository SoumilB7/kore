import Foundation
import Testing

@testable import KoreUI

/// The Welcome's Recent: Remove from Recent forgets a row only, and a box's Recent is its
/// folders, one row each (old recents moved into their folders, newest first).
@MainActor
struct WelcomeRecentTests {
    private func defaults() -> UserDefaults {
        let name = "kore-welcome-recent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func macRemoveForgetsTheRowOnly() {
        let a = URL(fileURLWithPath: "/tmp/a"), b = URL(fileURLWithPath: "/tmp/b")
        #expect(AppModel.forgetting(URL(fileURLWithPath: "/tmp/./a/"), in: [b, a]) == [b])
        #expect(AppModel.forgetting(URL(fileURLWithPath: "/tmp/c"), in: [b, a]) == [b, a])
    }

    @Test func boxRecentsMigrateIntoFolders() {
        let folders = ["/srv/onfinance", "/srv/kore", "/srv/kore/app"]
        let old = ["/srv/onfinance/slack", "/srv/kore/app/src", "/srv/onfinance", "/srv/kore/x", "/tmp/gone", "/srv/onfinance/ncdex"]
        #expect(BoxBinding.migrated(old, into: folders) == ["/srv/onfinance", "/srv/kore/app", "/srv/kore"])
        // "/srv/korea" isn't inside "/srv/kore".
        #expect(BoxBinding.migrated(["/srv/korea"], into: ["/srv/kore"]) == [])

        let store = defaults()
        store.set(old, forKey: "boxRecents.mybox")
        #expect(BoxBinding.recentFolders("mybox", folders: folders + ["/srv/new"], defaults: store) == ["/srv/onfinance", "/srv/kore/app", "/srv/kore", "/srv/new"])
        #expect(BoxBinding.recents("mybox", defaults: store) == ["/srv/onfinance", "/srv/kore/app", "/srv/kore"], "written back tidy")
    }

    @Test func boxRemoveForgetsUntilOpenedAgain() {
        let store = defaults()
        let folders = ["/srv/a", "/srv/b"]
        BoxBinding.opened(alias: "mybox", folder: "/srv/b", defaults: store)
        BoxBinding.forget(alias: "mybox", folder: "/srv/b", defaults: store)
        #expect(BoxBinding.recentFolders("mybox", folders: folders, defaults: store) == ["/srv/a"])
        #expect(BoxBinding.recents("mybox", defaults: store).isEmpty)
        BoxBinding.opened(alias: "mybox", folder: "/srv/b", defaults: store)
        #expect(BoxBinding.recentFolders("mybox", folders: folders, defaults: store) == ["/srv/b", "/srv/a"])
    }
}
