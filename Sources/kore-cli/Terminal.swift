import Foundation

let dim = "\u{1B}[2m", bold = "\u{1B}[1m", yellow = "\u{1B}[33m", reset = "\u{1B}[0m"

func out(_ s: String) {
    FileHandle.standardOutput.write(Data(s.utf8))
}

func fail(_ s: String) -> Never {
    out(s + "\n")
    exit(1)
}

/// Lines typed on stdin, read on a background thread.
func inputLines() -> AsyncStream<String> {
    AsyncStream { continuation in
        Thread {
            while let line = readLine() { continuation.yield(line) }
            continuation.finish()
        }.start()
    }
}

/// Requests waiting for the user's next line (permission prompts, questions).
actor PromptQueue<Request: Sendable & Identifiable> where Request.ID: Sendable {
    private var queue: [Request] = []
    func push(_ r: Request) { queue.append(r) }
    func remove(_ id: Request.ID) { queue.removeAll { $0.id == id } }
    func pop() -> Request? { queue.isEmpty ? nil : queue.removeFirst() }
}

/// "2" → the second option's label, anything else → itself.
func pickOption(_ answer: String, from labels: [String]) -> String {
    Int(answer).flatMap { labels.indices.contains($0 - 1) ? labels[$0 - 1] : nil } ?? answer
}
