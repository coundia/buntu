import Foundation
import Testing
@testable import CndIptvApp
import CndCoreBridge

@Suite("Profiles, Bouquets & Parental Control Tests (PRD-20)", .serialized)
struct ProfilesAndBouquetsTests {

    @Test("ParentalControlManager PIN hashing and session unlock")
    @MainActor
    func testParentalControlManager() {
        let parental = ParentalControlManager.shared
        _ = parental.removePin()
        #expect(!parental.hasPin)
        #expect(!parental.isAdultUnlocked)

        // Set PIN
        #expect(parental.setPin("1234"))
        #expect(parental.hasPin)

        // Verify PIN
        #expect(parental.verifyPin("1234"))
        #expect(!parental.verifyPin("0000"))

        // Session unlock for adult content
        #expect(!parental.isAdultUnlocked)
        parental.unlockAdultSession(durationMinutes: 15)
        #expect(parental.isAdultUnlocked)

        // Lock session
        parental.lockAdultSession()
        #expect(!parental.isAdultUnlocked)

        // Cleanup
        #expect(parental.removePin())
        #expect(!parental.hasPin)
    }

    @Test("ProfilesModel CRUD and Kids profile isolation")
    @MainActor
    func testProfilesModel() throws {
        let engine = try CndEngine.inMemory()
        let model = ProfilesModel(engine: engine)

        #expect(model.profiles.count == 1)
        #expect(model.activeProfileId == 1)
        #expect(model.activeProfile?.name == "Principal")
        #expect(!model.isKidsModeActive)

        // Create Kids Profile
        let kids = model.createProfile(name: "Kids Room", avatar: "figure.child", isKids: true)
        #expect(kids != nil)
        #expect(kids?.isKids == true)
        #expect(model.profiles.count == 2)

        // Switch to kids profile
        model.forceSelectProfile(id: kids!.id)
        #expect(model.activeProfileId == kids!.id)
        #expect(model.isKidsModeActive)

        // Update profile
        #expect(model.updateProfile(id: kids!.id, name: "Kids Zone", avatar: "star.fill", isKids: true))
        #expect(model.activeProfile?.name == "Kids Zone")

        // Attempt to delete profile 1 (must fail)
        #expect(!model.deleteProfile(id: 1))

        // Delete kids profile
        #expect(model.deleteProfile(id: kids!.id))
        #expect(model.profiles.count == 1)
        #expect(model.activeProfileId == 1)
    }

    @Test("BouquetEditorModel group hiding and favorite folders")
    @MainActor
    func testBouquetEditorModel() throws {
        let engine = try CndEngine.inMemory()

        // Adult keyword detection
        #expect(engine.isAdultCategory(group: "XXX Adultes"))
        #expect(engine.isAdultCategory(group: "FR: +18"))
        #expect(!engine.isAdultCategory(group: "France 2 HD"))
        #expect(!engine.isAdultCategory(group: "Jeunesse & Enfants"))

        let bouquetModel = BouquetEditorModel(engine: engine, kind: "live")

        // Create favorite folder
        let folderId = bouquetModel.createFavoriteFolder(name: "Sport Favoris")
        #expect(folderId != nil)
        #expect(bouquetModel.favoriteFolders.count == 1)
        #expect(bouquetModel.favoriteFolders.first?.name == "Sport Favoris")

        // Delete favorite folder
        bouquetModel.deleteFavoriteFolder(id: folderId!)
        #expect(bouquetModel.favoriteFolders.isEmpty)
    }
}
