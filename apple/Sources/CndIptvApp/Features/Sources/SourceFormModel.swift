import Foundation
import Observation
import CndCoreBridge

enum SourceKind: String, CaseIterable, Identifiable {
    case m3u
    case xtream

    var id: String { rawValue }
    var title: String { self == .m3u ? "M3U" : "Xtream Codes" }
}

enum ConnectionTestState: Equatable {
    case idle
    case testing
    case success(XtreamAccountInfo)
    case failure(String)
}

/// Create / edit logic of a source. The Xtream password never reaches SQLite: it is stored in the
/// Keychain under `cnd.xtream.<uuid>` and only that reference is persisted.
@Observable
@MainActor
final class SourceFormModel {
    let engine: CndEngine
    let keychain: KeychainStore
    let editing: IptvSourceRecord?

    var kind: SourceKind
    var name: String
    var m3uUrl: String
    var epgUrl: String
    var server: String { didSet { invalidateTest() } }
    var username: String { didSet { invalidateTest() } }
    var password: String { didSet { invalidateTest() } }

    private(set) var testState: ConnectionTestState = .idle
    private(set) var isSaving = false
    var errorMessage: String?

    init(engine: CndEngine, keychain: KeychainStore = .shared, editing: IptvSourceRecord? = nil) {
        self.engine = engine
        self.keychain = keychain
        self.editing = editing
        kind = editing.map { $0.sourceType == "xtream" ? .xtream : .m3u } ?? .m3u
        name = editing?.name ?? ""
        m3uUrl = editing?.url ?? ""
        epgUrl = editing?.epgUrl ?? ""
        server = editing?.server ?? ""
        username = editing?.username ?? ""
        if let editing, editing.sourceType == "xtream" {
            let key = editing.passwordRef ?? KeychainStore.xtreamKey(forSourceUuid: editing.uuid)
            password = (try? keychain.readSecret(forKey: key)) ?? ""
        } else {
            password = ""
        }
    }

    var isEditing: Bool { editing != nil }
    var title: String { isEditing ? "Modifier la source" : "Nouvelle source" }

    private func invalidateTest() {
        if testState != .testing { testState = .idle }
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedEpg: String? {
        let value = Self.trimmed(epgUrl)
        return value.isEmpty ? nil : value
    }

    static func isValidPlaylistLocation(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://")
    }

    var validationMessage: String? {
        if Self.trimmed(name).isEmpty { return "Donnez un nom à la source." }
        switch kind {
        case .m3u:
            let url = Self.trimmed(m3uUrl)
            if url.isEmpty { return "Saisissez l'URL de la playlist M3U." }
            if !Self.isValidPlaylistLocation(url) { return "L'URL doit commencer par http://, https:// ou file://." }
        case .xtream:
            if Self.trimmed(server).isEmpty { return "Saisissez l'adresse du serveur." }
            if Self.trimmed(username).isEmpty { return "Saisissez le nom d'utilisateur." }
            if password.isEmpty { return "Saisissez le mot de passe." }
        }
        return nil
    }

    var canSave: Bool { validationMessage == nil && !isSaving }
    var canTest: Bool {
        kind == .xtream && testState != .testing
            && !Self.trimmed(server).isEmpty && !Self.trimmed(username).isEmpty && !password.isEmpty
    }

    // MARK: Connection test

    func testConnection() async {
        guard canTest else { return }
        testState = .testing
        do {
            let info = try await engine.verifyXtreamAccount(
                server: Self.trimmed(server), username: Self.trimmed(username), password: password
            )
            testState = .success(info)
        } catch {
            testState = .failure(userMessage(for: error))
        }
    }

    static func describe(_ info: XtreamAccountInfo, now: Date = Date()) -> String {
        var parts = [info.status.capitalized]
        if info.isTrial { parts.append("essai") }
        if let ts = info.expDateTs {
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            let formatted = date.formatted(date: .abbreviated, time: .omitted)
            parts.append(date < now ? "expiré le \(formatted)" : "expire le \(formatted)")
        }
        if info.maxConnections > 0 {
            parts.append("\(info.activeConnections)/\(info.maxConnections) connexions")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Save

    /// Creates or updates the source and returns its id.
    func save() async throws -> Int64 {
        if let message = validationMessage { throw CndError.Parse(message: message) }
        isSaving = true
        defer { isSaving = false }
        let engine = self.engine
        let keychain = self.keychain
        let cleanName = Self.trimmed(name)
        let epg = trimmedEpg

        switch kind {
        case .m3u:
            let url = Self.trimmed(m3uUrl)
            if let editing {
                try engine.updateSource(sourceId: editing.id, name: cleanName, url: url, epgUrl: epg)
                return editing.id
            }
            let id = try engine.addSource(
                name: cleanName, sourceType: "m3u", url: url, server: nil, username: nil, passwordRef: nil
            )
            if epg != nil { try engine.updateSource(sourceId: id, name: cleanName, url: url, epgUrl: epg) }
            return id

        case .xtream:
            let cleanServer = Self.trimmed(server)
            let cleanUser = Self.trimmed(username)
            let id: Int64
            let uuid: String
            if let editing {
                id = editing.id
                uuid = editing.uuid
            } else {
                id = try engine.addSource(
                    name: cleanName, sourceType: "xtream", url: nil,
                    server: cleanServer, username: cleanUser, passwordRef: nil
                )
                guard let created = try engine.listSources().first(where: { $0.id == id }) else {
                    throw CndError.Internal(message: "Source créée introuvable (id=\(id)).")
                }
                uuid = created.uuid
            }
            let key = editing?.passwordRef ?? KeychainStore.xtreamKey(forSourceUuid: uuid)
            try keychain.savePassword(password, forKey: key)
            try engine.updateXtreamSource(
                sourceId: id, name: cleanName, server: cleanServer, username: cleanUser,
                passwordRef: key, epgUrl: epg
            )
            return id
        }
    }
}
