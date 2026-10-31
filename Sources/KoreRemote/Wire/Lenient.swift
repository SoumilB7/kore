import Foundation

/// An enum on the wire that reads a value it doesn't know as `unknown`, so a newer phone or host
/// never breaks an older one (`protocol/src/schema.ts`, "Enums are lenient").
package protocol LenientEnum: RawRepresentable, Codable, Sendable, Equatable where RawValue == String {
    static var unknown: Self { get }
}

extension LenientEnum {
    package init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
