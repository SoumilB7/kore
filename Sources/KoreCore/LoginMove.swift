import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Moving one CLI login between this Mac and another of the owner's devices, so exactly one
/// device holds it at the end. A login's refresh token is single-use and rotates: held in two
/// places, whichever refreshes second is logged out. So a login is never copied, only moved, in
/// one order (`account-move.html` §8):
///
/// 1. every background use of it on the source is paused, under a lock for that login;
/// 2. no CLI runs on it;
/// 3. it is read in-process (never on a command line);
/// 4. it goes sealed to the target, in the KoreNet session;
/// 5. the target writes it (0600, or its Keychain) where nothing runs it yet;
/// 6. the target checks the bytes (sha256) and that its CLI reads it signed in;
/// 7. only then is the source's copy deleted;
/// 8. no clear copy is left anywhere.
///
/// A failure before 7 removes the target's copy and leaves the source as it was. Kore never runs
/// a CLI's logout: it revokes the login on every device. The engine is the order alone; what
/// reads, writes and sends is the caller's (`Local`, `Remote`), so every branch is testable.
public enum LoginMove {
    /// Why a move didn't happen. The login is where it was, untouched, in every case.
    public enum Failure: Error, Equatable, Sendable {
        /// Another move or a Keep of this login is under way.
        case busy
        /// Chats are using it on the source: how many.
        case inUse(Int)
        /// The source holds no such login.
        case notThere
        /// The target already holds this login (it would be two copies).
        case alreadyThere
        /// macOS's Keychain prompt was denied.
        case keychainDenied
        /// The target isn't reachable, or stopped answering.
        case unreachable
        /// The target can't take a login (its Kore or kore-host is too old).
        case tooOld
        /// The bytes that arrived aren't the ones sent.
        case sentWrong
        /// The target's CLI doesn't read it signed in.
        case notSignedIn
        /// It refreshed on the source while it moved: the copy sent is already stale.
        case changedMeanwhile
        /// Reading, writing or deleting it failed, in the system's words.
        case failed(String)
        /// The target refused, in its words.
        case refused(String)
    }

    /// What's left to tell the other side when it couldn't be told at once (its link dropped).
    /// The caller keeps it and sends it again until it's acknowledged.
    public enum Pending: Equatable, Sendable, Codable {
        /// The target holds a verified copy the source no longer has: it puts it in place.
        case commitImport(moveId: String)
        /// The target holds a copy that must go: the source keeps the login.
        case abortImport(moveId: String)
        /// The login is here now: the remote device deletes its copy.
        case commitExport(moveId: String)
        /// The remote device keeps its login: it un-pauses it.
        case abortExport(moveId: String)
    }

    public struct Outcome: Equatable, Sendable {
        public var failure: Failure?
        /// Owed to the other side, kept and sent again by the caller.
        public var pending: Pending?
        public var moved: Bool { failure == nil }

        public static func moved(pending: Pending? = nil) -> Outcome { Outcome(failure: nil, pending: pending) }
        public static func failed(_ failure: Failure, pending: Pending? = nil) -> Outcome { Outcome(failure: failure, pending: pending) }
    }

    /// The login on this device.
    public protocol Local: Sendable {
        /// Pauses every background use of the login (usage and status reads, titles) until
        /// `unlock`; false when it's locked already.
        func lock() async -> Bool
        func unlock() async
        /// Chats using it here now.
        func chatsUsing() async -> Int
        /// Its bytes, read in-process; nil when it isn't here. Throws `Failure.keychainDenied`.
        func read() async throws -> Data?
        /// Writes it where this device keeps it. Throws when it can't.
        func write(_ data: Data) async throws
        /// Whether the CLI here reads it signed in (`auth status`).
        func signedIn() async -> Bool
        /// Deletes the copy here (never a logout).
        func delete() async throws
    }

    /// The same login's place on the other device, over the link. Each call is idempotent by
    /// `moveId`: one sent twice (after a drop) does the same once.
    public protocol Remote: Sendable {
        /// The target writes `data` to staging (never run), checks `sha` and its CLI's status.
        /// Throws a `Failure` (unreachable, sentWrong, notSignedIn, alreadyThere, refused…).
        func prepareImport(moveId: String, data: Data, sha: String) async throws
        func commitImport(moveId: String) async throws
        func abortImport(moveId: String) async throws
        /// The remote device pauses its copy, checks nothing runs on it, and sends it.
        func prepareExport(moveId: String) async throws -> (data: Data, sha: String)
        func commitExport(moveId: String) async throws
        func abortExport(moveId: String) async throws
    }

    /// The hex sha256 the target checks.
    public static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// A new move's id: what makes each call idempotent.
    public static func newID() -> String { UUID().uuidString.lowercased() }

    /// This device's login goes to the other device (Move to mybox, Keep on mybox).
    public static func out(_ local: some Local, to remote: some Remote, moveId: String = newID()) async -> Outcome {
        guard await local.lock() else { return .failed(.busy) }
        let outcome = await outLocked(local, remote, moveId)
        await local.unlock()
        return outcome
    }

    private static func outLocked(_ local: some Local, _ remote: some Remote, _ moveId: String) async -> Outcome {
        let using = await local.chatsUsing()
        guard using == 0 else { return .failed(.inUse(using)) }
        let data: Data
        do {
            guard let read = try await local.read() else { return .failed(.notThere) }
            data = read
        } catch { return .failed(failure(error)) }
        let sent = sha(data)
        do {
            try await remote.prepareImport(moveId: moveId, data: data, sha: sent)
        } catch {
            return .failed(failure(error), pending: await abortImport(remote, moveId))
        }
        // A refresh while it moved (a CLI outside Kore) makes the copy sent stale: the source
        // keeps the live one, the target's goes.
        do {
            guard let again = try await local.read(), sha(again) == sent else {
                return .failed(.changedMeanwhile, pending: await abortImport(remote, moveId))
            }
        } catch {
            return .failed(failure(error), pending: await abortImport(remote, moveId))
        }
        do {
            try await local.delete()
        } catch {
            return .failed(failure(error), pending: await abortImport(remote, moveId))
        }
        // From here the target's copy is the only one: it goes in place, now or when the link is back.
        do {
            try await remote.commitImport(moveId: moveId)
            return .moved()
        } catch {
            return .moved(pending: .commitImport(moveId: moveId))
        }
    }

    /// The other device's login comes here (Move back here, Keep here).
    public static func back(_ local: some Local, from remote: some Remote, moveId: String = newID()) async -> Outcome {
        guard await local.lock() else { return .failed(.busy) }
        let outcome = await backLocked(local, remote, moveId)
        await local.unlock()
        return outcome
    }

    private static func backLocked(_ local: some Local, _ remote: some Remote, _ moveId: String) async -> Outcome {
        do {
            if try await local.read() != nil { return .failed(.alreadyThere) }
        } catch {
            // A Keychain that won't say whether it's there: nothing is written over it.
            return .failed(failure(error))
        }
        let got: (data: Data, sha: String)
        do {
            got = try await remote.prepareExport(moveId: moveId)
        } catch {
            return .failed(failure(error), pending: await abortExport(remote, moveId))
        }
        guard sha(got.data) == got.sha else { return .failed(.sentWrong, pending: await abortExport(remote, moveId)) }
        do {
            try await local.write(got.data)
        } catch {
            try? await local.delete()
            return .failed(failure(error), pending: await abortExport(remote, moveId))
        }
        // What was written is what came, and the CLI here reads it signed in.
        let written = try? await local.read()
        guard written.map(sha) == got.sha else {
            try? await local.delete()
            return .failed(.sentWrong, pending: await abortExport(remote, moveId))
        }
        guard await local.signedIn() else {
            try? await local.delete()
            return .failed(.notSignedIn, pending: await abortExport(remote, moveId))
        }
        // From here this device's copy is the one: the other deletes its own, now or later.
        do {
            try await remote.commitExport(moveId: moveId)
            return .moved()
        } catch {
            return .moved(pending: .commitExport(moveId: moveId))
        }
    }

    private static func abortImport(_ remote: some Remote, _ moveId: String) async -> Pending? {
        do {
            try await remote.abortImport(moveId: moveId)
            return nil
        } catch { return .abortImport(moveId: moveId) }
    }

    /// A Keep there that stopped after staging: the staged copy goes, and theirs runs again.
    /// What's owed first, if either couldn't be told.
    private static func abortBoth(_ remote: some Remote, _ moveId: String) async -> Pending? {
        let staged = await abortImport(remote, moveId)
        let paused = await abortExport(remote, moveId)
        return staged ?? paused
    }

    private static func abortExport(_ remote: some Remote, _ moveId: String) async -> Pending? {
        do {
            try await remote.abortExport(moveId: moveId)
            return nil
        } catch { return .abortExport(moveId: moveId) }
    }

    // MARK: One sign-in on both devices: Keep

    /// The same sign-in is here and on the other device: it stays here. The live copy (the one
    /// refreshed last) is the one kept, written here if it's the other's; the other's copy goes.
    /// Nothing is logged out.
    public static func keepHere(_ local: some Local, _ remote: some Remote, cli: String, moveId: String = newID()) async -> Outcome {
        guard await local.lock() else { return .failed(.busy) }
        let outcome = await keepHereLocked(local, remote, cli, moveId)
        await local.unlock()
        return outcome
    }

    private static func keepHereLocked(_ local: some Local, _ remote: some Remote, _ cli: String, _ moveId: String) async -> Outcome {
        let mine: Data
        do {
            guard let read = try await local.read() else { return .failed(.notThere) }
            mine = read
        } catch { return .failed(failure(error)) }
        let theirs: (data: Data, sha: String)
        do {
            theirs = try await remote.prepareExport(moveId: moveId)
        } catch {
            return .failed(failure(error), pending: await abortExport(remote, moveId))
        }
        guard sha(theirs.data) == theirs.sha else { return .failed(.sentWrong, pending: await abortExport(remote, moveId)) }
        if (LoginCredential.freshness(theirs.data, cli: cli) ?? 0) > (LoginCredential.freshness(mine, cli: cli) ?? 0) {
            // Theirs refreshed last: it's the live one, and replaces this device's.
            do { try await local.write(theirs.data) } catch {
                try? await local.write(mine)
                return .failed(failure(error), pending: await abortExport(remote, moveId))
            }
            let written = try? await local.read()
            guard written.map(sha) == theirs.sha, await local.signedIn() else {
                try? await local.write(mine)
                return .failed(.notSignedIn, pending: await abortExport(remote, moveId))
            }
        }
        do {
            try await remote.commitExport(moveId: moveId)
            return .moved()
        } catch {
            return .moved(pending: .commitExport(moveId: moveId))
        }
    }

    /// The same sign-in is here and on the other device: it stays there. If this device's copy
    /// is the live one, it replaces the other's first; then this device's goes.
    public static func keepThere(_ local: some Local, _ remote: some Remote, cli: String, moveId: String = newID()) async -> Outcome {
        guard await local.lock() else { return .failed(.busy) }
        let outcome = await keepThereLocked(local, remote, cli, moveId)
        await local.unlock()
        return outcome
    }

    private static func keepThereLocked(_ local: some Local, _ remote: some Remote, _ cli: String, _ moveId: String) async -> Outcome {
        let using = await local.chatsUsing()
        guard using == 0 else { return .failed(.inUse(using)) }
        let mine: Data
        do {
            guard let read = try await local.read() else { return .failed(.notThere) }
            mine = read
        } catch { return .failed(failure(error)) }
        // The other's copy, paused while this runs: nothing refreshes it meanwhile.
        let theirs: (data: Data, sha: String)
        do {
            theirs = try await remote.prepareExport(moveId: moveId)
        } catch {
            return .failed(failure(error), pending: await abortExport(remote, moveId))
        }
        if (LoginCredential.freshness(mine, cli: cli) ?? 0) > (LoginCredential.freshness(theirs.data, cli: cli) ?? 0) {
            // This device's is the live one: it replaces theirs (staged, checked) before this one goes.
            do {
                try await remote.prepareImport(moveId: moveId, data: mine, sha: sha(mine))
            } catch {
                return .failed(failure(error), pending: await abortBoth(remote, moveId))
            }
            guard let again = try? await local.read(), sha(again) == sha(mine) else {
                return .failed(.changedMeanwhile, pending: await abortBoth(remote, moveId))
            }
            do { try await local.delete() } catch {
                return .failed(failure(error), pending: await abortBoth(remote, moveId))
            }
            do { try await remote.commitImport(moveId: moveId) } catch { return .moved(pending: .commitImport(moveId: moveId)) }
        } else {
            do { try await local.delete() } catch {
                return .failed(failure(error), pending: await abortExport(remote, moveId))
            }
        }
        // Theirs runs again.
        do {
            try await remote.abortExport(moveId: moveId)
            return .moved()
        } catch {
            return .moved(pending: .abortExport(moveId: moveId))
        }
    }

    /// Sends a kept `Pending` again; true once the other side took it.
    public static func resend(_ pending: Pending, to remote: some Remote) async -> Bool {
        do {
            switch pending {
            case .commitImport(let id): try await remote.commitImport(moveId: id)
            case .abortImport(let id): try await remote.abortImport(moveId: id)
            case .commitExport(let id): try await remote.commitExport(moveId: id)
            case .abortExport(let id): try await remote.abortExport(moveId: id)
            }
            return true
        } catch { return false }
    }

    static func failure(_ error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        return .failed(error.localizedDescription)
    }
}

/// What tells two copies of one sign-in apart from two sign-ins of one account, without the
/// token ever leaving its device: an HMAC of the refresh token under a secret only the owner's
/// devices know, truncated. Two devices with the same fingerprint hold the same sign-in, and
/// one of them is logged out at its next refresh.
public enum LoginFingerprint {
    /// Hex characters kept: enough to tell sign-ins apart, too few to stand for the token.
    public static let length = 16

    /// The fingerprint of a credential file's refresh token; nil when it has none.
    public static func of(_ credential: Data, cli: String, key: Data) -> String? {
        guard let token = LoginCredential.refreshToken(credential, cli: cli), !token.isEmpty else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(token.utf8), using: SymmetricKey(data: key))
        return String(mac.map { String(format: "%02x", $0) }.joined().prefix(length))
    }
}

/// The few fields Kore reads in a CLI's credential file, never sending or showing them.
public enum LoginCredential {
    /// Claude's `.credentials.json` (or Keychain item): `claudeAiOauth.refreshToken`. Codex's
    /// `auth.json`: `tokens.refresh_token`.
    public static func refreshToken(_ data: Data, cli: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if cli == "codex" { return (object["tokens"] as? [String: Any])?["refresh_token"] as? String }
        return (object["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String
    }

    /// When the access token expires (ms since 1970), Claude's; Codex's last refresh. The copy
    /// refreshed later is the live one when the same sign-in sits on two devices.
    public static func freshness(_ data: Data, cli: String) -> Double? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if cli == "codex" {
            guard let text = object["last_refresh"] as? String else { return nil }
            return ISO8601DateFormatter.lenient(text)?.timeIntervalSince1970
        }
        return ((object["claudeAiOauth"] as? [String: Any])?["expiresAt"] as? NSNumber)?.doubleValue
    }
}

extension ISO8601DateFormatter {
    /// An ISO 8601 date with or without fractional seconds.
    static func lenient(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
