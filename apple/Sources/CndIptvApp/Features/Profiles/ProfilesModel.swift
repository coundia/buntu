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

    public init(engine: CndEngine) {
        self.engine = engine
        self.activeProfileId = engine.activeProfileId()
        reload()
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
        return true
    }

    public func forceSelectProfile(id: Int64) {
        engine.setActiveProfileId(id: id)
        activeProfileId = id
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

