/// The "/word" the caret is in, or Codex's "$word": what the slash menu filters by. It starts
/// the draft or follows whitespace and holds no other "/" or "$", so a path isn't one.
struct SlashToken: Equatable {
    /// From the sigil to the caret: what a pick replaces.
    let range: Range<String.Index>
    let sigil: Character
    /// What's typed between the sigil and the caret, lowercased.
    let query: String

    /// The token ending at `caret` in `text`; `skills` lets "$" start one (Codex).
    init?(in text: String, caret: String.Index, skills: Bool) {
        guard let caret = String.Index(caret, within: text) else { return nil }
        var start = caret
        while start > text.startIndex, !text[text.index(before: start)].isWhitespace {
            start = text.index(before: start)
        }
        guard start < caret else { return nil }
        let sigil = text[start]
        guard sigil == "/" || (skills && sigil == "$") else { return nil }
        let typed = text[text.index(after: start)..<caret]
        guard !typed.contains(where: { $0 == "/" || $0 == "$" }) else { return nil }
        range = start..<caret
        self.sigil = sigil
        query = typed.lowercased()
    }

    /// `text` with the token replaced by `insertion`, one space kept between the words it
    /// parted, and where the caret goes (after the insertion).
    func replacing(in text: String, with insertion: String) -> (text: String, caret: Int) {
        let before = text[..<range.lowerBound]
        var after = text[range.upperBound...]
        let spaced = before.isEmpty || before.last?.isWhitespace == true || insertion.last == " "
        if spaced, after.first == " " { after = after.dropFirst() }
        let head = before + insertion
        return (String(head + after), head.count)
    }
}
