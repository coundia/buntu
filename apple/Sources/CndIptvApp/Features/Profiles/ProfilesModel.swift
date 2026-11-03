import Foundation
import Observation
import SwiftUI
import CndCoreBridge

@Observable
@MainActor
public final class ProfilesModel {
    private let engine: CndEngine
    public private(set) var profiles: [ProfileRecord] = []
    public private(set) var activeProfileId: Int64 = 1
    public var errorMessage: String?

    public var activeProfile: ProfileRecord? {
        profiles.first(where: { $0.id == activeProfileId })
    }

    public var isKidsModeActive: Bool {
        activeProfile?.isKids ?? false
    }

    nonisolated static var activeProfileDefaultsKey: String { "profiles.activeId" }

    private let defaults: UserDefaults

    public init(engine: CndEngine, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        self.activeProfileId = engine.activeProfileId()
        reload()
    }

    /// The active profile survives a relaunch: otherwise leaving the Kids profile would only take
    /// quitting and reopening the app, without the PIN. Falls back to the main profile if it was deleted.
    static func restoreActiveProfile(engine: CndEngine, defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: activeProfileDefaultsKey) != nil else { return }
        let stored = Int64(defaults.integer(forKey: activeProfileDefaultsKey))
        let exists = (try? engine.listProfiles())?.contains { $0.id == stored } ?? false
        engine.setActiveProfileId(id: exists ? stored : 1)
    }

    public func reload() {
        do {
            profiles = try engine.listProfiles()
            activeProfileId = engine.activeProfileId()
        } catch {
            errorMessage = "Erreur lors du chargement des profils : \(error.localizedDescription)"
        }
    }

    public func selectProfile(_ profile: ProfileRecord, parental: ParentalControlManager? = nil) async -> Bool {
        // If exiting kids mode, verify parental PIN if configured
        if isKidsModeActive && !profile.isKids {
            if let parental, parental.hasPin {
                // Must be authenticated outside before selecting or verified
                return false
            }
        }

        engine.setActiveProfileId(id: profile.id)
        activeProfileId = profile.id
        defaults.set(Int(profile.id), forKey: Self.activeProfileDefaultsKey)
        return true
    }

    public func forceSelectProfile(id: Int64) {
        engine.setActiveProfileId(id: id)
        activeProfileId = id
        defaults.set(Int(id), forKey: Self.activeProfileDefaultsKey)
    }

    public func createProfile(name: String, avatar: String, isKids: Bool) -> ProfileRecord? {
        do {
            let created = try engine.createProfile(name: name, avatar: avatar, isKids: isKids)
            reload()
            return created
        } catch {
            errorMessage = "Impossible de créer le profil : \(error.localizedDescription)"
            return nil
        }
    }

    public func updateProfile(id: Int64, name: String, avatar: String, isKids: Bool) -> Bool {
        do {
            try engine.updateProfile(id: id, name: name, avatar: avatar, isKids: isKids)
            reload()
            return true
        } catch {
            errorMessage = "Impossible de modifier le profil : \(error.localizedDescription)"
            return false
        }
    }

    public func deleteProfile(id: Int64) -> Bool {
        guard id != 1 else {
            errorMessage = "Le profil principal ne peut pas être supprimé."
            return false
        }
        do {
            let deleted = try engine.deleteProfile(id: id)
            if deleted {
                if activeProfileId == id {
                    forceSelectProfile(id: 1)
                }
                reload()
            }
            return deleted
        } catch {
            errorMessage = "Impossible de supprimer le profil : \(error.localizedDescription)"
            return false
        }
    }
}

