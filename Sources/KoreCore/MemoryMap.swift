import Darwin

/// This process's dirty memory grouped by the tag the kernel keeps on each region, as
/// `footprint` groups it: what a spike is made of. Drawn layers (CoreAnimation's backing
/// stores) and decoded images don't live in the malloc heap, so heap tools never see them.
public enum MemoryMap {
    public struct Parts: Sendable, Equatable {
        /// CoreAnimation backing stores: each drawn text block, view and layer (`VM_MEMORY_LAYERKIT`).
        public var layers: UInt64 = 0
        /// Images ImageIO decoded (`VM_MEMORY_IMAGEIO`).
        public var images: UInt64 = 0
        /// The malloc heap: nano, tiny, small, medium and large.
        public var heap: UInt64 = 0
        public var other: UInt64 = 0
    }

    private static let heapTags: Set<Int32> = [
        VM_MEMORY_MALLOC, VM_MEMORY_MALLOC_SMALL, VM_MEMORY_MALLOC_LARGE, VM_MEMORY_MALLOC_LARGE_REUSED,
        VM_MEMORY_MALLOC_HUGE, VM_MEMORY_MALLOC_TINY, VM_MEMORY_MALLOC_NANO, VM_MEMORY_MALLOC_MEDIUM,
    ]

    /// One walk of the address space: a few thousand regions, a millisecond or so. For
    /// diagnostics, not a timer.
    public static func parts() -> Parts {
        var parts = Parts()
        var address: vm_address_t = 0
        var depth: natural_t = 0
        let page = UInt64(getpagesize())
        while true {
            var size: vm_size_t = 0
            var info = vm_region_submap_info_data_64_t()
            var count = mach_msg_type_number_t(MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    vm_region_recurse_64(mach_task_self_, &address, &size, &depth, $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { break }
            if info.is_submap != 0 {
                depth += 1
                continue
            }
            let dirty = (UInt64(info.pages_dirtied) + UInt64(info.pages_swapped_out)) * page
            switch Int32(info.user_tag) {
            case VM_MEMORY_LAYERKIT: parts.layers += dirty
            case VM_MEMORY_IMAGEIO: parts.images += dirty
            case let tag where heapTags.contains(tag): parts.heap += dirty
            default: parts.other += dirty
            }
            address += size
        }
        return parts
    }
}
