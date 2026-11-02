import SwiftUI
import CndCoreBridge

struct SendToDeviceSheet: View {
    @State var model: NearbySendModel
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                ShareSourceChoices(model: model.share)

                Section {
                    if model.client.discoveredPeers.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Recherche d'appareils…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.client.discoveredPeers) { peer in
                        Button {
                            model.selectedPeerID = peer.id
                        } label: {
                            HStack {
                                Image(systemName: model.selectedPeerID == peer.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.selectedPeerID == peer.id ? Color.accentColor : .secondary)
                                Text(peer.name)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Appareil")
                } footer: {
                    Text("Sur l'autre appareil, ouvrez Sources > « Recevoir depuis un autre appareil… » : il s'affiche ici et montre un code à 6 chiffres. Les deux appareils doivent être sur le même réseau.")
                }

                Section("Code affiché sur l'appareil") {
                    TextField("6 chiffres", text: $model.pin)
                        .font(.system(.title3, design: .monospaced))
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .onChange(of: model.pin) { _, value in
                            let digits = String(value.filter(\.isNumber).prefix(6))
                            if digits != value { model.pin = digits }
                        }
                }

                Section {
                    Button {
                        Task { await model.send() }
                    } label: {
                        HStack {
                            Text("Envoyer")
                            if model.status == .sending { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(!model.canSend)
                    switch model.status {
                    case .sent:
                        Label("Envoyé. Confirmez l'import sur l'autre appareil.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed(let message):
                        Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    default:
                        EmptyView()
                    }
                } footer: {
                    Text("Le partage est chiffré et valable 1 heure ; il passe par un canal protégé par le code, sans serveur.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Envoyer vers un autre appareil")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer", action: onClose) } }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 640)
        #endif
        .onAppear { model.startSearching() }
        .onDisappear { model.stopSearching() }
    }
}

struct ReceiveFromDeviceSheet: View {
    @State var model: NearbyReceiveModel
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                switch model.status {
                case .waiting, .connected:
                    Text("Code à saisir sur l'autre appareil")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(model.pairingCode)
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Text(model.status == .connected
                         ? "Réception en cours…"
                         : "Sur l'autre appareil : Sources > « Envoyer vers un autre appareil… », choisissez celui-ci puis saisissez ce code. Cet écran écoute 5 minutes.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                case .received:
                    Label("Reçu", systemImage: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Recevoir des sources")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer", action: onClose) } }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 400)
        #endif
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}
