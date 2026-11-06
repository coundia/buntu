import Foundation
#if canImport(FoundationModels) && !os(tvOS)
import FoundationModels
#endif

/// A language model that runs on this device and answers a prompt with text (PRD 34, lot 34.5).
/// A seam: the re-rank logic is tested with a fake, and the real one only exists where Apple ships it.
protocol OnDeviceTextModel: Sendable {
    /// The model can answer right now (compatible device, Apple Intelligence on, model downloaded).
    var isAvailable: Bool { get }
    /// Why it cannot, in one sentence for the Settings screen; `nil` when it can, or when nothing can be said.
    var unavailableReason: String? { get }
    func respond(system: String, user: String) async throws -> String
}

enum OnDeviceModelError: Error, Equatable {
    case unavailable
    case timedOut
}

/// The Foundation Models of Apple (macOS, iOS and visionOS 26 and later). Everywhere else, and on older
/// systems, it reports itself unavailable and the Settings screen does not offer it.
struct AppleOnDeviceModel: OnDeviceTextModel {
    static let shared = AppleOnDeviceModel()

    var isAvailable: Bool {
        #if canImport(FoundationModels) && !os(tvOS)
        if #available(macOS 26, iOS 26, visionOS 26, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    var unavailableReason: String? {
        #if canImport(FoundationModels) && !os(tvOS)
        if #available(macOS 26, iOS 26, visionOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "Cet appareil ne prend pas en charge Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Activez Apple Intelligence dans les Réglages du système."
            case .unavailable(.modelNotReady):
                return "Le modèle d'Apple se télécharge encore : réessayez plus tard."
            case .unavailable:
                return "Le modèle d'Apple n'est pas disponible pour le moment."
            }
        }
        #endif
        return nil
    }

    func respond(system: String, user: String) async throws -> String {
        #if canImport(FoundationModels) && !os(tvOS)
        if #available(macOS 26, iOS 26, visionOS 26, *) {
            guard SystemLanguageModel.default.isAvailable else { throw OnDeviceModelError.unavailable }
            // One session per question: the shelves of one kind never see the context of another.
            let session = LanguageModelSession(instructions: system)
            let response = try await session.respond(to: user)
            return response.content
        }
        #endif
        throw OnDeviceModelError.unavailable
    }
}

/// Runs `operation` and gives up after `seconds` (the shelf stays as the local engine made it).
func withDeadline<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw OnDeviceModelError.timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw OnDeviceModelError.timedOut }
        return first
    }
}

