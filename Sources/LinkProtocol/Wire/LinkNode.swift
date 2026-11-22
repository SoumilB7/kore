import Foundation

/// Phase 18 step 5a: who a box is on KoreNet, told to an owner Mac after the welcome on any route
/// (`net.node`). The Mac pins the box's identity key from it over SSH (the SSH host key and the
/// grant's proof vouch for the box), enrolls itself once with `attach --proto 2`, and finds the
/// box among its own tailnet peers by `nodeKey` (never by the address the box claims).
package enum NetNodeWire {
    package static let type = "net.node"

    package struct Node: Codable, Equatable, Sendable {
        package var t = NetNodeWire.type
        /// The box's KoreNet device id.
        package var device: UUID
        /// Its P-256 identity key, SPKI DER.
        package var identityKey: Data
        package var name: String
        /// Whether the box is on KoreNet now (`kore-host net on`).
        package var on: Bool
        /// Its tailnet node key while it's on and Tailscale runs.
        package var nodeKey: String?
        /// The Mac's own device id here, once it enrolled (the grant names it).
        package var enrolled: UUID?
        /// The box's system (`linux`, `macos`): the lines its owner is shown depend on it. Nil
        /// from a box before it said.
        package var os: String?
        /// Its tailnet while it's on: `tailscale` (installed) or `kore` (Kore's own).
        package var tailnet: String?
        /// Kore's own tailnet there, in use or kept signed in beside Tailscale. Nil from a box
        /// before it said, or one with no `kore-tailnet`.
        package var own: Own?
        /// Every tailnet node this box has, the one it listens on first: its installed
        /// Tailscale's and Kore's own (`<host>-kore`, signed in beside it or carrying it), so a
        /// Mac knows both before the box moves between them. Nil from a box before it said.
        package var nodeKeys: [String]?

        package init(
            device: UUID, identityKey: Data, name: String, on: Bool, nodeKey: String? = nil, enrolled: UUID? = nil, os: String? = nil, tailnet: String? = nil,
            own: Own? = nil, nodeKeys: [String]? = nil
        ) {
            self.own = own
            self.nodeKeys = nodeKeys
            self.os = os
            self.tailnet = tailnet
            self.device = device
            self.identityKey = identityKey
            self.name = name
            self.on = on
            self.nodeKey = nodeKey
            self.enrolled = enrolled
        }
    }

    /// Kore's own tailnet on a device: signed in (as whom), or signed out and why, with its
    /// sign-in page once it has one. Said again the moment it changes.
    package struct Own: Codable, Equatable, Sendable {
        package enum State: String, Codable, Sendable {
            case signedIn = "in"
            case signedOut = "out"
        }

        /// Why it's signed out.
        package enum Why: String, Codable, Sendable {
            /// Never signed in on this device.
            case never
            /// Its node key expired.
            case expired
            /// Signed out or removed from the tailnet (the admin console, a logout).
            case loggedOut = "logged-out"
            /// Its sealed state couldn't be opened (the key changed): signed in afresh.
            case unreadable
        }

        package var state: State
        package var login: String?
        package var why: Why?
        /// Its sign-in page (`https://login.tailscale.com/…`) while one waits.
        package var page: String?

        package init(state: State, login: String? = nil, why: Why? = nil, page: String? = nil) {
            self.state = state
            self.login = login
            self.why = why
            self.page = page
        }

        package static func signedIn(_ login: String?) -> Own { Own(state: .signedIn, login: login) }
        package static func signedOut(_ why: Why, page: String? = nil) -> Own { Own(state: .signedOut, why: why, page: page) }

        package var signedIn: Bool { state == .signedIn }

        /// The one line it gets: "Kore's tailnet: signed in as you@x.com", "Kore's tailnet: signed out".
        package var line: String {
            switch state {
            case .signedIn: return "Kore's tailnet: signed in" + (login.map { " as \($0)" } ?? "")
            case .signedOut:
                switch why {
                case .never?: return "Kore's tailnet: not signed in"
                case .expired?: return "Kore's tailnet: signed out · key expired"
                case .unreadable?: return "Kore's tailnet: signed out · its saved sign-in couldn't be opened"
                case .loggedOut?, nil: return "Kore's tailnet: signed out"
                }
            }
        }

        /// `kore-host tailnet`'s lines (`own: in|out`, `login:`, `why:`, `page:`).
        package var report: [String] {
            var lines = ["own: " + state.rawValue]
            if let login { lines.append("login: " + login) }
            if let why { lines.append("why: " + why.rawValue) }
            if let page { lines.append("page: " + page) }
            return lines
        }

        /// Those lines read back; nil when there's no `own:` (`own: none`: no `kore-tailnet` there).
        package static func parse(report output: String) -> Own? {
            var fields: [String: String] = [:]
            for line in output.split(whereSeparator: \.isNewline) {
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields[line[..<colon].trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let state = fields["own"].flatMap(State.init(rawValue:)) else { return nil }
            return Own(
                state: state, login: fields["login"].flatMap { $0.isEmpty ? nil : $0 }, why: fields["why"].flatMap(Why.init(rawValue:)),
                page: fields["page"].flatMap { $0.hasPrefix("https://") ? $0 : nil })
        }

        /// What a running node's status says (nil: still starting, nothing to say yet). A
        /// signed-in node whose key has expired is signed out. Running with no login is a start
        /// from its cached state that its control server hasn't answered yet (it may say removed
        /// or expired): nothing yet. Running with a sign-in page is one its control server asks to
        /// sign in again (its key ran out there): signed out, that page.
        package static func heard(running: Bool, needsLogin: Bool, login: String?, page: String?, keyExpiry: Date?, before: Own?, now: Date) -> Own? {
            if running {
                if let keyExpiry, keyExpiry <= now { return .signedOut(.expired, page: page) }
                if page == nil {
                    guard let login, !login.isEmpty else { return nil }
                    return .signedIn(login)
                }
            }
            guard needsLogin || page != nil else { return nil }
            // It was signed in and now isn't: logged out, removed, or its key ran out.
            let why: Why
            switch before {
            case let was? where was.signedIn: why = .loggedOut
            case let was?: why = was.why ?? .never
            case nil: why = .never
            }
            return .signedOut(why, page: page)
        }
    }

    package static func decode(_ data: Data) -> Node? { try? JSONDecoder().decode(Node.self, from: data) }
}
