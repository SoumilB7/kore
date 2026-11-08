import Foundation

// The usage popup's reading as it crosses from a box (link 1.5): a `type` tag per case, written
// out so renaming a case never changes the wire.

private struct TagKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension PlanAccount.Access: Codable {
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: TagKey.self)
        switch self {
        case .plan: try c.encode("plan", forKey: TagKey("type"))
        case .signedOut: try c.encode("signedOut", forKey: TagKey("type"))
        case .perToken(let how):
            try c.encode("perToken", forKey: TagKey("type"))
            try c.encode(how, forKey: TagKey("how"))
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: TagKey.self)
        switch try c.decode(String.self, forKey: TagKey("type")) {
        case "plan": self = .plan
        case "perToken": self = .perToken(try c.decodeIfPresent(String.self, forKey: TagKey("how")) ?? "")
        default: self = .signedOut
        }
    }
}

extension PlanResetOutcome: Codable {
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: TagKey.self)
        let type: String
        switch self {
        case .reset: type = "reset"
        case .nothingToReset: type = "nothingToReset"
        case .noCredit: type = "noCredit"
        case .alreadyRedeemed: type = "alreadyRedeemed"
        case .other(let outcome):
            type = "other"
            try c.encode(outcome, forKey: TagKey("outcome"))
        }
        try c.encode(type, forKey: TagKey("type"))
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: TagKey.self)
        let type = try c.decode(String.self, forKey: TagKey("type"))
        switch type {
        case "reset": self = .reset
        case "nothingToReset": self = .nothingToReset
        case "noCredit": self = .noCredit
        case "alreadyRedeemed": self = .alreadyRedeemed
        default: self = .other(try c.decodeIfPresent(String.self, forKey: TagKey("outcome")) ?? type)
        }
    }
}
