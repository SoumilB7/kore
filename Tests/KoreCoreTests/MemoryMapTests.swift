import Foundation
import Testing

@testable import KoreCore

/// The memory map names what the process's dirty memory is: here, heap a test wrote to.
@Suite("memory map")
struct MemoryMapTests {
    @Test func heapWrittenToShowsAsHeap() {
        let before = MemoryMap.parts()
        let size = 64 << 20
        let block = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16_384)
        defer { block.deallocate() }
        // Touch every page, so it is dirty.
        for offset in stride(from: 0, to: size, by: 4096) { block.storeBytes(of: UInt8(1), toByteOffset: offset, as: UInt8.self) }
        let after = MemoryMap.parts()
        #expect(after.heap >= before.heap + (48 << 20))
        #expect(after.layers < 64 << 20 && after.images < 64 << 20)
    }
}
