import KoreUI

// Locators for the folder window's own controls (phase 12, §3).

extension Locator {
    /// The `n`-th tab, from the left.
    package static func tab(_ n: Int) -> Locator {
        Locator("tab \(n)") { app in
            guard let tabs = app.workspace?.tabs else { return .failure(LocatorMiss("tab \(n): no workspace")) }
            guard tabs.indices.contains(n - 1) else { return .failure(LocatorMiss("tab \(n): the window has \(tabs.count) tabs")) }
            return .success(StoryID.Tabs.tab(tabs[n - 1].id))
        }
    }

    /// The tab whose title is `title`.
    package static func tab(titled title: String) -> Locator {
        Locator("the “\(title)” tab") { app in
            guard let tabs = app.workspace?.tabs else { return .failure(LocatorMiss("the “\(title)” tab: no workspace")) }
            guard let tab = tabs.first(where: { $0.title == title }) else {
                return .failure(LocatorMiss("the “\(title)” tab: the tabs are \(tabs.map { "“\($0.title)”" }.joined(separator: ", "))"))
            }
            return .success(StoryID.Tabs.tab(tab.id))
        }
    }
}
