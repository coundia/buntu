import Foundation
import Observation
import CoreImage
import CoreImage.CIFilterBuiltins
import CndCoreBridge
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum DeviceName {
    static var current: String {
        #if os(macOS)
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        return UIDevice.current.name
        #endif
    }
}

enum ShareValidity: Int, CaseIterable, Identifiable {
    case hour = 3_600
    case day = 86_400
    case week = 604_800

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .hour: return "1 heure"
        case .day: return "24 heures"
        case .week: return "7 jours"
        }
    }
}

/// What the sender gets after "Créer le partage".
struct SharePackage {
    var envelope: Data
    var code: Data
    var warnings: [ShareWarning]
    var sourceCount: Int
    var expiresAt: Date

    var codeText: String { ShareEnvelope.format(code: code) }
    var link: String { ShareEnvelope.link(envelope: envelope, code: code) }
    /// A QR code only fits so much; beyond that the file is the way to send it.
    var linkFitsInQR: Bool { link.utf8.count <= ShareEnvelope.qrByteLimit }

    func writeFile(directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = directory.appendingPathComponent("Partage CND IPTV.\(ShareEnvelope.fileExtension)")
        try envelope.write(to: url, options: .atomic)
        return url
    }

    func qrImage(scale: CGFloat = 8) -> CGImage? {
        guard linkFitsInQR else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

// MARK: - Sending

/// Choices and result of the "Partager…" sheet.
@Observable
@MainActor
final class ShareSourcesModel {
    let engine: CndEngine
    let keychain: KeychainStore
    let sources: [IptvSourceRecord]

    var selected: Set<Int64>
    var includeCredentials: Set<Int64> = []
    var includePlaylist: Set<Int64> = []
    var validity: ShareValidity = .day
    private(set) var package: SharePackage?
    private(set) var isPreparing = false
    private(set) var errorMessage: String?

    init(engine: CndEngine, keychain: KeychainStore = .shared, sources: [IptvSourceRecord], preselected: Set<Int64> = []) {
        self.engine = engine
        self.keychain = keychain
        self.sources = sources
        selected = preselected.isEmpty ? Set(sources.prefix(1).map(\.id)) : preselected
    }

    static func isLocalPlaylist(_ source: IptvSourceRecord) -> Bool {
        source.sourceType != "xtream" && (source.url ?? "").hasPrefix("file://")
    }

    var canPrepare: Bool { !selected.isEmpty && !isPreparing }

    /// Connections allowed by the subscriptions being shared with their credentials (smallest known).
    var sharedConnectionLimit: UInt32? {
        sources.filter { includeCredentials.contains($0.id) && selected.contains($0.id) }.compactMap(\.maxConnections).min()
    }

    var sharesCredentials: Bool { !includeCredentials.intersection(selected).isEmpty }

    private func password(for source: IptvSourceRecord) -> String? {
        guard source.sourceType == "xtream" else { return nil }
        let key = source.passwordRef ?? KeychainStore.xtreamKey(forSourceUuid: source.uuid)
        return try? keychain.readSecret(forKey: key)
    }

    func prepare() async {
        guard canPrepare else { return }
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }
        let chosen = sources.filter { selected.contains($0.id) }
        let options = chosen.map { source in
            ShareSourceOption(
                sourceId: source.id,
                includeCredentials: includeCredentials.contains(source.id),
                password: includeCredentials.contains(source.id) ? password(for: source) : nil,
                includePlaylist: includePlaylist.contains(source.id)
            )
        }
        let engine = self.engine
        let from = DeviceName.current
        let validFor = UInt32(validity.rawValue)
        do {
            let export = try await Task.detached(priority: .userInitiated) {
                try engine.exportShareDocument(options: options, from: from, validForSeconds: validFor)
            }.value
            let code = ShareEnvelope.makeCode()
            let expiresAt = Date().addingTimeInterval(TimeInterval(validFor))
            let envelope = try ShareEnvelope.seal(
                document: Data(export.json.utf8), code: code,
                sourceCount: Int(export.sourceCount), expiresAt: Int64(expiresAt.timeIntervalSince1970)
            )
            package = SharePackage(
                envelope: envelope, code: code, warnings: export.warnings,
                sourceCount: Int(export.sourceCount), expiresAt: expiresAt
            )
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    func reset() {
        package = nil
        errorMessage = nil
    }
}

// MARK: - Receiving

struct IncomingShare: Equatable {
    var envelope: Data
    var code: String?

    /// A `cndiptv://import#…` link or a `.cndshare` file handed to the app by the system.
    static func from(url: URL) -> IncomingShare? {
        if let link = ShareEnvelope.parse(link: url) { return IncomingShare(envelope: link.envelope, code: link.code) }
        guard url.isFileURL, url.pathExtension.lowercased() == ShareEnvelope.fileExtension else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return IncomingShare(envelope: data, code: nil)
    }
}

struct ShareImportSummary: Equatable {
    var imported: Int
    var replaced: Int
    var skipped: Int
    /// Sources that still need a password or credentials before they can load.
    var needingCredentials: [String]
    var importedIds: [Int64]
}

@Observable
@MainActor
final class ShareImportModel {
    enum Stage: Equatable {
        case input
        case preview
        case done(ShareImportSummary)
    }

    let engine: CndEngine
    let keychain: KeychainStore
    let importsDirectory: URL

    var codeText = ""
    private(set) var envelope: Data?
    private(set) var header: ShareEnvelope.Header?
    private(set) var preview: SharePreview?
    var decisions: [UInt32: ShareImportAction] = [:]
    private(set) var stage: Stage = .input
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var document: String?
    @ObservationIgnored var onImported: ([Int64]) -> Void = { _ in }

    init(
        engine: CndEngine,
        keychain: KeychainStore = .shared,
        importsDirectory: URL = SourcesModel.defaultImportsDirectory,
        incoming: IncomingShare? = nil
    ) {
        self.engine = engine
        self.keychain = keychain
        self.importsDirectory = importsDirectory
        if let incoming { load(envelope: incoming.envelope, code: incoming.code) }
    }

    var hasEnvelope: Bool { envelope != nil }
    var expiresAt: Date? { header.map { Date(timeIntervalSince1970: TimeInterval($0.expiresAt)) } }

    /// Accepts a file's bytes or a pasted `cndiptv://import#…` link.
    func load(envelope data: Data, code: String? = nil) {
        errorMessage = nil
        do {
            let parts = try ShareEnvelope.header(of: data)
            guard parts.header.expiresAt > Int64(Date().timeIntervalSince1970) else { throw ShareEnvelope.Failure.expired }
            envelope = data
            header = parts.header
            if let code { codeText = code }
            if code != nil { Task { await decrypt() } }
        } catch {
            envelope = nil
            header = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func load(pasted text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let incoming = ShareEnvelope.parse(link: url) else {
            errorMessage = "Ce lien n'est pas un partage CND IPTV."
            return
        }
        load(envelope: incoming.envelope, code: incoming.code)
    }

    func decrypt() async {
        guard let envelope, !isWorking else { return }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let code = try ShareEnvelope.parse(code: codeText)
            let plain = try ShareEnvelope.open(envelope: envelope, code: code)
            guard let json = String(data: plain, encoding: .utf8) else { throw ShareEnvelope.Failure.malformed }
            let engine = self.engine
            let preview = try await Task.detached(priority: .userInitiated) { try engine.previewShareDocument(json: json) }.value
            document = json
            self.preview = preview
            decisions = Dictionary(uniqueKeysWithValues: preview.sources.map {
                ($0.index, $0.duplicateOf == nil ? ShareImportAction.import : .skip)
            })
            stage = .preview
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? userMessage(for: error)
        }
    }

    var chosenCount: Int { decisions.values.filter { $0 != .skip }.count }

    func performImport() async {
        guard let document, !isWorking, chosenCount > 0 else { return }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        let engine = self.engine
        let dir = importsDirectory.path
        let list = decisions.map { ShareDecision(index: $0.key, action: $0.value) }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try engine.importShareDocument(json: document, decisions: list, importsDir: dir)
            }.value
            var needing: [ShareImportedSource] = []
            for item in result.imported {
                if item.sourceType == "xtream" {
                    if let password = item.password {
                        try storePassword(password, for: item)
                    } else if !(item.replaced && hasStoredPassword(for: item)) {
                        needing.append(item)
                    }
                } else if preview?.sources.first(where: { $0.name == item.name })?.needsCredentials == true {
                    needing.append(item)
                }
            }
            let needingIds = Set(needing.map(\.sourceId))
            let summary = ShareImportSummary(
                imported: result.imported.filter { !$0.replaced }.count,
                replaced: result.imported.filter(\.replaced).count,
                skipped: Int(result.skipped),
                needingCredentials: needing.map(\.name),
                importedIds: result.imported.map(\.sourceId)
            )
            stage = .done(summary)
            // Only sources that can load now are synced; the others wait for their credentials.
            onImported(summary.importedIds.filter { !needingIds.contains($0) })
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    private func hasStoredPassword(for item: ShareImportedSource) -> Bool {
        let record = try? engine.listSources().first { $0.id == item.sourceId }
        let key = record?.passwordRef ?? KeychainStore.xtreamKey(forSourceUuid: item.uuid)
        return ((try? keychain.readSecret(forKey: key)) ?? nil) != nil
    }

    /// The secret goes to the Keychain; only its reference is kept in the database.
    private func storePassword(_ password: String, for item: ShareImportedSource) throws {
        let key = KeychainStore.xtreamKey(forSourceUuid: item.uuid)
        try keychain.saveSecret(password, forKey: key)
        guard let record = try engine.listSources().first(where: { $0.id == item.sourceId }) else { return }
        try engine.updateXtreamSource(
            sourceId: record.id, name: record.name, server: record.server ?? "", username: record.username ?? "",
            passwordRef: key, epgUrl: record.epgUrl
        )
    }
}
