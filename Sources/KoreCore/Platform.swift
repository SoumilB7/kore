import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// The few system calls and fields whose names differ between macOS and Linux, under one name.

enum Posix {
    static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.read(fd, buffer, count)
        #elseif canImport(Glibc)
        Glibc.read(fd, buffer, count)
        #else
        Musl.read(fd, buffer, count)
        #endif
    }

    static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.write(fd, buffer, count)
        #elseif canImport(Glibc)
        Glibc.write(fd, buffer, count)
        #else
        Musl.write(fd, buffer, count)
        #endif
    }

    static func open(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 {
        #if canImport(Darwin)
        Darwin.open(path, flags, mode)
        #elseif canImport(Glibc)
        Glibc.open(path, flags, mode)
        #else
        Musl.open(path, flags, mode)
        #endif
    }

    @discardableResult
    static func close(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.close(fd)
        #elseif canImport(Glibc)
        Glibc.close(fd)
        #else
        Musl.close(fd)
        #endif
    }
}

extension stat {
    /// The last change of the file's contents.
    var modified: timespec {
        #if canImport(Darwin)
        st_mtimespec
        #else
        st_mtim
        #endif
    }

    /// When it was made; Linux's `stat` has no birth time, so its last status change stands in.
    var born: timespec {
        #if canImport(Darwin)
        st_birthtimespec
        #else
        st_ctim
        #endif
    }
}

#if !canImport(ObjectiveC)
/// No autorelease pool off Apple's platforms: the body runs as it is.
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result { try body() }
#endif
