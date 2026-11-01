import Foundation
import Observation
import CndCoreBridge

@Observable
public final class AppState {
    public var engine: CndEngine?
    public var stats: DbStats?
    public var sources: [IptvSourceRecord] = []
    public var items: [IptvItemRecord] = []
    
    public var searchQuery: String = "" {
        didSet {
            performSearch()
        }
    }
    
    public var selectedCategory: String = "live"
    public var isLoading: Bool = false
    public var errorMessage: String?
    
    public init() {
        initEngine()
    }
    
    public func initEngine() {
        Task.detached(priority: .userInitiated) {
            do {
                // Prepare app support database directory
                let fileManager = FileManager.default
                let appSupport = try fileManager.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let cndDir = appSupport.appendingPathComponent("CndIptvNative", isDirectory: true)
                try fileManager.createDirectory(at: cndDir, withIntermediateDirectories: true)
                
                let dbUrl = cndDir.appendingPathComponent("cnd_iptv.db")
                let engineInstance = try CndEngine(dbPath: dbUrl.path)
                
                let currentStats = try engineInstance.getStats()
                let currentSources = try engineInstance.listSources()
                
                await MainActor.run {
                    self.engine = engineInstance
                    self.stats = currentStats
                    self.sources = currentSources
                    self.isLoading = false
                    self.performSearch()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Engine init error: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
    
    public func refresh() {
        guard let engine = self.engine else { return }
        Task.detached(priority: .userInitiated) {
            do {
                let newStats = try engine.getStats()
                let newSources = try engine.listSources()
                await MainActor.run {
                    self.stats = newStats
                    self.sources = newSources
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    public func performSearch() {
        guard let engine = self.engine else { return }
        let query = self.searchQuery
        let kind = self.selectedCategory
        
        Task.detached(priority: .userInitiated) {
            do {
                let results = try engine.queryItems(
                    kind: kind,
                    query: query,
                    group: nil,
                    host: nil,
                    limit: 100,
                    offset: 0
                )
                await MainActor.run {
                    self.items = results
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    public func addSampleSource() {
        guard let engine = self.engine else { return }
        Task.detached(priority: .userInitiated) {
            do {
                _ = try engine.addSource(
                    name: "Freebox TV France",
                    sourceType: "m3u",
                    url: "http://mafreebox.freebox.fr/freeboxtv/playlist.m3u",
                    server: nil,
                    username: nil,
                    passwordRef: nil
                )
                let updatedSources = try engine.listSources()
                let updatedStats = try engine.getStats()
                await MainActor.run {
                    self.sources = updatedSources
                    self.stats = updatedStats
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    public func toggleFavorite(item: IptvItemRecord) {
        guard let engine = self.engine else { return }
        Task.detached(priority: .userInitiated) {
            do {
                _ = try engine.toggleFavorite(stableHash: item.stableHash, itemKind: item.kind)
                let updatedStats = try engine.getStats()
                await MainActor.run {
                    self.stats = updatedStats
                    self.performSearch()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

