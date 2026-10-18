import AppKit
import SwiftUI

/// KORE_GALLERY=markdown: `MarkdownView` over a reply with every block type, then two streaming
/// states (a half-written fence and a half-written table) beside their raw text. Also logs the
/// parse time of a 5,000-line reply to stderr (`MARKDOWN …`).
@MainActor
enum DevMarkdownGallery {
    static func showIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["KORE_GALLERY"] == "markdown" else { return false }
        benchmark()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 2300), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.title = "Markdown"
        window.contentView = NSHostingView(
            rootView: Page().background(Theme.background).environment(\.colorScheme, .dark))
        window.orderFront(nil)
        DevSnapshot.captureIfRequested()
        return true
    }

    private struct Page: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 24) {  // lint:allow gallery layout
                label("Reply (streaming: false)")
                MarkdownView(text: reply)
                label("Streaming: an open fence (the cut lands inside it, so it stays hidden)")
                streaming(openFence)
                label("Streaming: a half-written table (after the last blank line, so not yet shown)")
                streaming(halfTable)
            }
            .padding(24)  // lint:allow gallery layout
            .frame(width: 760, alignment: .topLeading)  // lint:allow gallery layout
        }

        private func label(_ text: String) -> some View {
            Text(text).font(TextStyle.eyebrow).foregroundStyle(Theme.accent)
        }

        private func streaming(_ raw: String) -> some View {
            HStack(alignment: .top, spacing: 16) {  // lint:allow gallery layout
                Text(raw)
                    .font(TextStyle.codeSmall)
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 300, alignment: .leading)  // lint:allow gallery layout
                MarkdownView(text: raw, streaming: true)
            }
        }
    }

    static let reply = """
        # Heading 1
        ## Heading 2
        ### Heading 3
        #### Heading 4
        ##### Heading 5
        ###### Heading 6

        A paragraph with **bold**, *italic*, ~~struck~~, `inline code`, and a [link](https://example.com).
        A soft line break joins this sentence to the one above.

        Second paragraph, right under the first.

        - First item
        - Second item with `code`
          - Nested item
            - Third level
        - Back at the top

        1. Install
        2. Configure
        3. Run

        - [x] Parser
        - [ ] Gallery

        ```swift
        func greet(_ name: String) -> String {
            return "Hello, \\(name)! This line is long enough that the block has to scroll sideways to show it all."
        }
        ```

        | File | Lines | Status |
        |---|---|---|
        | MarkdownParser.swift | 420 | new |
        | MarkdownView.swift | 210 | new |

        > A block quote, with a list:
        > - quoted item

        ---

        After the rule.
        """

    static let openFence = """
        Settled paragraph with **bold**.

        - one
        - two

        ```swift
        let a = 1

        let b = 2
        """

    static let halfTable = """
        Here is the table:

        | Name | Value |
        |---|---|
        | a | 1 |
        | b
        """

    /// Parse time for a 5,000-line reply: a full parse, one streamed append, and the settled cut.
    private static func benchmark() {
        let lines = reply.split(separator: "\n", omittingEmptySubsequences: false)
        var big = ""
        var count = 0
        while count < 5000 {
            big += reply + "\n\n"
            count += lines.count + 1
        }
        let clock = ContinuousClock()
        let document = MarkdownDocument()
        let full = clock.measure { document.update(big[...]) }
        let grown = big + "One more streamed paragraph.\n"
        let append = clock.measure { document.update(grown[...]) }
        let cut = clock.measure { _ = MarkdownParser.settled(grown) }
        FileHandle.standardError.write(Data(
            "MARKDOWN \(count) lines, \(big.utf8.count) bytes, \(document.blocks.count) blocks: full parse \(full), append \(append), settled cut \(cut)\n".utf8))
    }
}
