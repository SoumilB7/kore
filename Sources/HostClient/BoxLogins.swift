import Foundation
import KoreCore
import LinkProtocol

/// A box's side of a login move, over its link (1.14, `LinkLogins`): what `LoginMove` calls on
/// the other device. Only on KoreNet (the session the login is sealed in), and only with a box
/// that takes it; a box's refusal comes back as the engine's own failure.
package struct BoxLogins: LoginMove.Remote {
    package let connection: HostConnection
    package let cli: String
    /// The login's name on the box: what it's placed under (in), or which goes (out).
    package let login: String
    /// This Mac's name, for the box's "from MacBook" line.
    package let host: String
    /// What the CLI shows of the account (Claude's minimal `.claude.json`), sent with the login.
    package let profile: String?
    /// A Keep: the login replaces the box's copy of the same sign-in (`login`) rather than
    /// being refused as one it holds already.
    package let force: Bool

    package init(connection: HostConnection, cli: String, login: String, host: String, profile: String? = nil, force: Bool = false) {
        (self.connection, self.cli, self.login, self.host, self.profile, self.force) = (connection, cli, login, host, profile, force)
    }

    /// Why the box can't take a login now: unreachable, not on KoreNet, or too old; nil: it can.
    @MainActor
    package static func unready(_ connection: HostConnection) -> LoginMove.Failure? {
        guard connection.isOnline else { return .unreachable }
        guard connection.route?.isNet == true, connection.netPeer != nil else { return .refused("not on KoreNet") }
        guard connection.caps.contains(LinkLogins.cap) else { return .tooOld }
        return nil
    }

    package func prepareImport(moveId: String, data: Data, sha: String) async throws {
        _ = try await send(.accountImport, ControlArgs(
            force: force ? true : nil, text: profile, provider: cli, login: login, data: data.base64EncodedString(), phase: MovePhase.prepare.rawValue,
            moveId: moveId, host: host, sha: sha))
    }

    package func commitImport(moveId: String) async throws -> Bool? {
        try await send(.accountImport, ControlArgs(force: force ? true : nil, provider: cli, login: login, phase: MovePhase.commit.rawValue, moveId: moveId)).signedIn
    }

    package func abortImport(moveId: String) async throws {
        _ = try await send(.accountImport, ControlArgs(provider: cli, phase: MovePhase.abort.rawValue, moveId: moveId))
    }

    package func prepareExport(moveId: String) async throws -> (data: Data, sha: String) {
        let result = try await send(.accountExport, ControlArgs(provider: cli, login: login, phase: MovePhase.prepare.rawValue, moveId: moveId))
        guard let data = result.data.flatMap({ Data(base64Encoded: $0) }), let sha = result.sha else { throw LoginMove.Failure.sentWrong }
        return (data, sha)
    }

    package func commitExport(moveId: String) async throws {
        _ = try await send(.accountExport, ControlArgs(provider: cli, phase: MovePhase.commit.rawValue, moveId: moveId))
    }

    package func abortExport(moveId: String) async throws {
        _ = try await send(.accountExport, ControlArgs(provider: cli, phase: MovePhase.abort.rawValue, moveId: moveId))
    }

    /// Each of the box's logins' fingerprints under `key`; nil when the box can't say.
    @MainActor
    package static func fingerprints(_ connection: HostConnection, cli: String, key: Data) async -> [LoginPrint]? {
        guard unready(connection) == nil else { return nil }
        let result = await connection.loginCommand(.accountFingerprints, ControlArgs(provider: cli, key: key.base64EncodedString()))
        return result.ok ? result.prints ?? [] : nil
    }

    private func send(_ kind: ControlKind, _ args: ControlArgs) async throws -> LoginMoveResult {
        let connection = connection
        if let why = await MainActor.run(body: { Self.unready(connection) }) { throw why }
        let result = await connection.loginCommand(kind, args)
        guard result.ok else { throw Self.failure(result) }
        return result
    }

    /// The box's refusal as the engine's failure: its words where they name one.
    static func failure(_ result: LoginMoveResult) -> LoginMove.Failure {
        let words = result.message ?? ""
        switch words {
        case "sentWrong": return .sentWrong
        case "notSignedIn": return .notSignedIn
        case "notALogin": return .notALogin
        case "occupied": return .occupied
        case "busy": return .busy
        case "notThere": return .notThere
        default: break
        }
        if words.hasPrefix("inUse:"), let n = Int(words.dropFirst(6)) { return .inUse(n) }
        if result.code == .deniedControl { return .refused(words) }
        // No answer (the link dropped before it): the box may have done it or not.
        if result.code == nil || result.code == .unknown { return .unreachable }
        return .refused(words)
    }
}

extension HostConnection {
    /// One 1.14 command: the box's raw `LoginMoveResult`, or the link's own failure.
    package func loginCommand(_ kind: ControlKind, _ args: ControlArgs) async -> LoginMoveResult {
        let (result, raw) = await commandRaw { id in HostWire.command(id: id, .control(kind, args)) }
        if let raw, let decoded = try? JSONDecoder().decode(LoginMoveResult.self, from: raw) { return decoded }
        return LoginMoveResult(id: result.id, ok: result.ok, code: result.code, message: result.message)
    }

    /// The boxes held now (each alias's one link).
    package static var linked: [HostConnection] { Array(open.values) }
}
