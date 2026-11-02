import Foundation

/// What a failing stream's server answers, in words the user can act on. The player engines only
/// report "loading failed"; one tiny request after a failure tells the real cause.
public enum StreamDiagnosis: Equatable, Sendable {
    /// The server answered with this HTTP status (after redirects).
    case http(Int)
    case timeout
    case unknownHost
    case offline
    case secureConnection
    case unreachable

    /// Clear explanation for the logs and the error banner. Never contains the address.
    public var message: String {
        switch self {
        case .http(429):
            return "Le serveur refuse la connexion (HTTP 429, trop de requêtes). Cause la plus fréquente : la limite de connexions simultanées de l'abonnement est atteinte (autre appareil, mosaïque, téléchargement ou enregistrement en cours). Fermez-les puis réessayez."
        case .http(let code) where code == 401 || code == 403:
            return "Accès refusé par le serveur (HTTP \(code)) : identifiants invalides, abonnement expiré ou adresse IP non autorisée."
        case .http(let code) where code == 404 || code == 410:
            return "Contenu introuvable sur le serveur (HTTP \(code)) : le fichier a été retiré ou le lien est périmé. Synchronisez la source."
        case .http(let code) where code == 458 || code == 884:
            return "Le serveur refuse ce compte (HTTP \(code)) : limite de connexions ou compte bloqué par le fournisseur."
        case .http(let code) where (500...599).contains(code):
            return "Erreur du serveur (HTTP \(code)) : le fournisseur a un problème, réessayez plus tard."
        case .http(let code) where (200...299).contains(code):
            return "Le serveur répond (HTTP \(code)) mais le flux n'a pas pu être lu : format non pris en charge ou flux interrompu."
        case .http(let code):
            return "Réponse inattendue du serveur (HTTP \(code))."
        case .timeout:
            return "Le serveur ne répond pas (délai dépassé) : serveur surchargé ou réseau trop lent."
        case .unknownHost:
            return "Nom du serveur introuvable (DNS) : vérifiez l'adresse de la source ou votre connexion."
        case .offline:
            return "Pas de connexion Internet."
        case .secureConnection:
            return "Connexion sécurisée refusée (certificat HTTPS invalide)."
        case .unreachable:
            return "Connexion au serveur impossible (serveur éteint ou port fermé)."
        }
    }

    /// Reconnecting again right away cannot help: the server said no, the content is gone, or the
    /// name does not resolve. Timeouts, 5xx and a reachable server stay worth retrying.
    public var isFinal: Bool {
        switch self {
        case .http(let code): return [401, 403, 404, 410, 429, 458, 884].contains(code)
        case .unknownHost, .secureConnection: return true
        case .timeout, .offline, .unreachable: return false
        }
    }

    static func classify(_ error: Error) -> StreamDiagnosis {
        guard let urlError = error as? URLError else { return .unreachable }
        switch urlError.code {
        case .timedOut: return .timeout
        case .cannotFindHost, .dnsLookupFailed: return .unknownHost
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .offline
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
            return .secureConnection
        default: return .unreachable
        }
    }

    /// Asks for the first byte of the stream (redirects followed, same headers as the player) and
    /// stops reading as soon as the status is known. It only runs after a playback failure.
    public static func probe(url: URL, headers: [String: String], session: URLSession? = nil) async -> StreamDiagnosis {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "GET"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let session = session ?? URLSession(configuration: .ephemeral)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            return .http(http.statusCode)
        } catch {
            return classify(error)
        }
    }
}
