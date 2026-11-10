import SwiftUI

/// Sheet shown on an existing household device (e.g. Mac, iPhone) to invite a nearby device without QR or key typing.
public struct HouseholdNearbyInviteSheet: View {
    @State private var host = HouseholdNearbyPairingHost()
    var onClose: () -> Void

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch host.state {
                case .idle, .listening:
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.4)
                            .padding(.top, 24)
                        Text("En attente d'un appareil…")
                            .font(.headline)
                        Text("Sur le nouvel appareil, ouvrez Buntu sur le même Wi-Fi et choisissez « Rejoindre un foyer à proximité ».")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                case .requestReceived(let deviceName, let sasCode):
                    VStack(spacing: 20) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 54))
                            .foregroundStyle(Color.accentColor)
                            .padding(.top, 16)

                        Text("Demande d'adhésion")
                            .font(.title2.bold())

                        Text("**\(deviceName)** souhaite rejoindre votre foyer.")
                            .font(.body)
                            .multilineTextAlignment(.center)

                        VStack(spacing: 6) {
                            Text("Code de confirmation")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(sasCode)
                                .font(.system(size: 38, weight: .bold, design: .monospaced))
                                .tracking(6)
                                .foregroundStyle(.primary)
                            Text("Vérifiez que ce code s'affiche sur le nouvel appareil.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(12)

                        HStack(spacing: 16) {
                            Button("Refuser", role: .cancel) {
                                host.pendingRequest?.reject()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            Button("Autoriser") {
                                host.pendingRequest?.approve()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                        .padding(.top, 8)
                    }

                case .success(let deviceName):
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(.green)
                            .padding(.top, 24)

                        Text("Appareil ajouté !")
                            .font(.title2.bold())

                        Text("**\(deviceName)** a rejoint votre foyer et synchronisera ses favoris et reprises.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Button("Terminer") {
                            onClose()
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 12)
                    }

                case .failed(let message):
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)
                            .padding(.top, 24)

                        Text("Impossible d'ajouter l'appareil")
                            .font(.headline)

                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Button("Réessayer") {
                            host.startListening()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Spacer()
            }
            .padding()
            .frame(minWidth: 380, minHeight: 380)
            .navigationTitle("Ajouter un appareil")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") {
                        host.stop()
                        onClose()
                    }
                }
            }
            .onAppear {
                host.startListening()
            }
            .onDisappear {
                host.stop()
            }
        }
    }
}

/// Sheet shown on a new device (Mac, iPhone, iPad) to discover and join a household on the local network.
public struct HouseholdNearbyJoinSheet: View {
    @State private var client = HouseholdNearbyPairingClient()
    var onJoined: () -> Void
    var onClose: () -> Void

    public init(onJoined: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onJoined = onJoined
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch client.state {
                case .idle, .browsing:
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Recherche des appareils du foyer sur votre réseau Wi-Fi…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if client.discoveredHosts.isEmpty {
                            VStack(spacing: 16) {
                                ProgressView()
                                    .padding(.top, 24)
                                Text("Aucun appareil invitant détecté pour l'instant.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("Sur un appareil déjà dans le foyer (Mac ou iPhone), ouvrez Appareils > « Ajouter un appareil à proximité ».")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                        } else {
                            List(client.discoveredHosts) { host in
                                Button {
                                    client.connectToHost(host)
                                } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "house.fill")
                                            .font(.title3)
                                            .foregroundStyle(Color.accentColor)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(host.name)
                                                .font(.headline)
                                                .foregroundStyle(.primary)
                                            Text("Appuyez pour rejoindre ce foyer")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                            #if os(tvOS)
                            .listStyle(.plain)
                            #else
                            .listStyle(.inset)
                            #endif
                        }
                    }

                case .connecting(let hostName):
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.4)
                            .padding(.top, 24)
                        Text("Connexion à **\(hostName)**…")
                            .font(.headline)
                    }

                case .waitingForAuthorization(let hostName, let sasCode):
                    VStack(spacing: 20) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.accentColor)
                            .padding(.top, 16)

                        Text("En attente d'autorisation")
                            .font(.title2.bold())

                        Text("Une confirmation a été envoyée sur **\(hostName)**.")
                            .font(.body)
                            .multilineTextAlignment(.center)

                        VStack(spacing: 6) {
                            Text("Code de confirmation")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(sasCode)
                                .font(.system(size: 38, weight: .bold, design: .monospaced))
                                .tracking(6)
                                .foregroundStyle(.primary)
                            Text("Vérifiez que ce code correspond sur l'autre écran.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(12)

                        ProgressView("Attente de la réponse…")
                            .font(.caption)
                    }

                case .success:
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(.green)
                            .padding(.top, 24)

                        Text("Foyer rejoint !")
                            .font(.title2.bold())

                        Text("Cet appareil fait désormais partie du foyer. Vos favoris, reprises et comptes IPTV sont partagés.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Button("Commencer") {
                            onJoined()
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 12)
                    }

                case .refused:
                    VStack(spacing: 16) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.red)
                            .padding(.top, 24)

                        Text("Demande refusée")
                            .font(.headline)

                        Text("La demande d'adhésion a été refusée sur l'autre appareil.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Button("Réessayer") {
                            client.startBrowsing()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                case .failed(let message):
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)
                            .padding(.top, 24)

                        Text("Erreur de connexion")
                            .font(.headline)

                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Button("Réessayer") {
                            client.startBrowsing()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Spacer()
            }
            .padding()
            .frame(minWidth: 380, minHeight: 380)
            .navigationTitle("Rejoindre un foyer")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") {
                        client.stop()
                        onClose()
                    }
                }
            }
            .onAppear {
                client.startBrowsing()
            }
            .onDisappear {
                client.stop()
            }
        }
    }
}

