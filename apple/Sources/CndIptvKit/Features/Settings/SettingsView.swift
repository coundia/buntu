import SwiftUI
import CndCoreBridge

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @Bindable var directory: DownloadDirectoryManager
    let stats: DbStats?
    var sync: CloudKitSyncManager?
    var localSync: LocalSyncService?
    var ai: AiProviderSettings?
    var assistant: AssistantModel?
    var upNext: UpNextModel?
    var forYou: ForYouHub?
    #if !os(tvOS)
    var library: LibraryModel?
    #endif

    @State private var showsOmdbKey = false
    @State private var showsAiKey = false
    @State private var aiStatus: AiProviderStatus?
    @State private var isTestingAi = false
    @AppStorage("autoFailoverEnabled") private var autoFailoverEnabled = true
    @AppStorage("healthChecksEnabled") private var healthChecksEnabled = true
    @AppStorage("timeshiftDuration") private var timeshiftDurationRaw: String = TimeshiftDuration.oneHour.rawValue
    @AppStorage("openSubtitlesLanguages") private var openSubtitlesLanguages: String = "fr,en"
    @AppStorage("openSubtitlesAutoSearch") private var openSubtitlesAutoSearch = false
    @AppStorage("downloads.background.enabled") private var backgroundDownloadsEnabled = true
    @AppStorage("downloads.cellular.enabled") private var cellularDownloadsEnabled = true
    @AppStorage("downloads.notifications.enabled") private var downloadNotificationsEnabled = true
    @AppStorage("downloads.keepAwake.enabled") private var keepScreenAwakeOnDownload = false
    @State private var showingProfilesManagement = false
    @State private var showingAdultUnlock = false
    @State private var showingJoinHousehold = false
    @State private var joinKeyInput = ""
    @State private var householdStore = HouseholdStore.shared
    @State private var parental = ParentalControlManager.shared
    @State private var languageStore = AppLanguageStore.shared

    private func t(_ key: String) -> String { languageStore.t(key) }
    private func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: languageStore.t(key), arguments: args)
    }

    var body: some View {
        Form {
            playbackAndHealthSection
            if let upNext { recommendationsSection(upNext) }
            if let forYou { forYouSection(forYou) }
            profilesAndBouquetsSection
            parentalSection
            appearanceSection
            #if os(macOS)
            windowSection
            #endif
            #if os(iOS)
            liveActivitiesSection
            #endif
            #if os(tvOS)
            displaySection
            #endif
            subtitlesSection
            downloadsSection
            #if !os(tvOS)
            if let library { librarySection(library) }
            #endif
            networkSection
            omdbSection
            if let ai, let assistant { assistantSection(ai, assistant) }
            if let sync { iCloudSection(sync) }
            householdSection
            diagnosticSection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle(t("settings.title"))
        .onDisappear { model.flush() }
    }

    // MARK: Sections

    private var playbackAndHealthSection: some View {
        Section(t("settings.playback.section")) {
            Toggle(t("settings.playback.autoFailover"), isOn: $autoFailoverEnabled)
            Toggle(t("settings.playback.healthChecks"), isOn: $healthChecksEnabled)
            Picker(t("settings.playback.timeshift"), selection: $timeshiftDurationRaw) {
                ForEach(TimeshiftDuration.allCases) { item in
                    Text(item.title).tag(item.rawValue)
                }
            }
        }
    }

    @ViewBuilder
    private func recommendationsSection(_ upNext: UpNextModel) -> some View {
        Section {
            Toggle(t("settings.recommendations.upNextShelf"), isOn: Binding(
                get: { upNext.isUpNextShelfEnabled },
                set: { upNext.isUpNextShelfEnabled = $0 }
            ))
            Toggle(t("settings.recommendations.nextUpCard"), isOn: Binding(
                get: { upNext.isNextUpCardEnabled },
                set: { upNext.isNextUpCardEnabled = $0 }
            ))
            if upNext.isNextUpCardEnabled {
                Toggle(t("settings.recommendations.autoPlay"), isOn: Binding(
                    get: { upNext.isAutoPlayNextEnabled },
                    set: { upNext.isAutoPlayNextEnabled = $0 }
                ))
                if upNext.isAutoPlayNextEnabled {
                    Picker(t("settings.recommendations.countdown"), selection: Binding(
                        get: { upNext.countdownDuration },
                        set: { upNext.countdownDuration = $0 }
                    )) {
                        Text(t("settings.recommendations.seconds", 5)).tag(5)
                        Text(t("settings.recommendations.seconds", 10)).tag(10)
                        Text(t("settings.recommendations.seconds", 15)).tag(15)
                        Text(t("settings.recommendations.seconds", 30)).tag(30)
                    }
                }
            }
            Picker(t("settings.recommendations.sagaOrder"), selection: Binding(
                get: { upNext.sagaOrderPreference },
                set: { upNext.sagaOrderPreference = $0 }
            )) {
                Text(t("settings.recommendations.sagaChronology")).tag(SagaOrderPreference.storyChronology)
                Text(t("settings.recommendations.sagaRelease")).tag(SagaOrderPreference.releaseOrder)
            }
            Toggle(t("settings.recommendations.useAiForSagas"), isOn: Binding(
                get: { upNext.useAiForSagas },
                set: { upNext.useAiForSagas = $0 }
            ))
            .disabled(ai?.isAssistantEnabled != true)

            Button(t("settings.recommendations.resetDismissed")) {
                upNext.resetDismissed()
            }
        } header: {
            Text(t("settings.recommendations.section"))
        } footer: {
            Text(t("settings.recommendations.footer"))
        }
    }

    /// The « Pour vous » rows of PRD 34: one switch per kind, the AI refinement, and a reset of the taste per kind.
    @ViewBuilder
    private func forYouSection(_ forYou: ForYouHub) -> some View {
        @Bindable var hub = forYou
        Section {
            Toggle(t("settings.forYou.movies"), isOn: $hub.moviesEnabled)
            Toggle(t("settings.forYou.series"), isOn: $hub.seriesEnabled)
            Toggle(t("settings.forYou.live"), isOn: $hub.liveEnabled)
            Toggle(t("settings.forYou.aiRefine"), isOn: $hub.aiRefine)
                .disabled(ai?.isAssistantEnabled != true && !hub.onDevice.isAvailable)
            // Only offered where the device has the model (macOS, iOS and visionOS 26 and later, Apple Intelligence on).
            if hub.aiRefine && hub.onDevice.isAvailable {
                Toggle(t("settings.forYou.onDeviceModel"), isOn: $hub.preferOnDeviceModel)
            }
            if hub.aiRefine && ai?.endpointIsLocal != true && !hub.usesOnDeviceModel {
                Toggle(t("settings.forYou.sendRecentTitles"), isOn: $hub.sendRecentTitles)
                    .disabled(ai?.isAssistantEnabled != true)
            }
            Button(t("settings.forYou.resetMovies")) { forYou.movies.resetTaste() }
            Button(t("settings.forYou.resetSeries")) { forYou.series.resetTaste() }
            Button(t("settings.forYou.resetLive")) { forYou.live.resetTaste() }
        } header: {
            Text(t("settings.forYou.section"))
        } footer: {
            Text(t("settings.forYou.footer"))
        }
    }

    private var parentalSection: some View {
        Section {
            LabeledContent(t("settings.parental.adultCategories")) {
                if let until = parental.adultUnlockedUntil, parental.isAdultUnlocked {
                    Text(t("settings.parental.visibleUntil", until.formatted(date: .omitted, time: .shortened)))
                } else {
                    Text(t("settings.parental.hidden"))
                }
            }
            if parental.isAdultUnlocked {
                Button(t("settings.parental.relock")) { parental.lockAdultSession() }
            } else {
                Button(t("settings.parental.unlock15m")) { showingAdultUnlock = true }
            }
        } header: {
            Text(t("settings.parental.section"))
        } footer: {
            Text(t("settings.parental.footer"))
        }
        .sheet(isPresented: $showingAdultUnlock) {
            AdultUnlockSheet(parental: parental) { showingAdultUnlock = false }
        }
    }

    #if os(tvOS)
    private var displaySection: some View {
        @Bindable var matcher = DisplayRateMatcher.shared
        return Section {
            Toggle(t("settings.display.matchRate"), isOn: $matcher.isEnabled)
        } footer: {
            Text(t("settings.display.footer"))
        }
    }
    #endif

    #if os(iOS)
    private var liveActivitiesSection: some View {
        @Bindable var activities = LiveActivityManager.shared
        return Section {
            Toggle(t("settings.liveActivities.recording"), isOn: $activities.isRecordingActivityEnabled)
            Toggle(t("settings.liveActivities.playback"), isOn: $activities.isPlaybackActivityEnabled)
        } header: {
            Text(t("settings.liveActivities.section"))
        } footer: {
            Text(t("settings.liveActivities.footer"))
        }
    }
    #endif

    private var appearanceSection: some View {
        @Bindable var scale = UIScaleStore.shared
        @Bindable var lang = languageStore
        return Section {
            Picker(t("settings.language.picker"), selection: $lang.language) {
                ForEach(AppLanguage.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
            Picker(t("settings.appearance.uiScale"), selection: $scale.setting) {
                ForEach(UIScaleSetting.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text(t("settings.appearance.section"))
        } footer: {
            #if os(macOS)
            Text(t("settings.appearance.footerMac"))
            #else
            Text(t("settings.appearance.footerOther"))
            #endif
        }
    }

    #if os(macOS)
    private var windowSection: some View {
        @Bindable var level = WindowLevelController.shared
        return Section {
            Picker(t("settings.window.alwaysOnTop"), selection: $level.mode) {
                ForEach(AlwaysOnTopMode.allCases) { Text($0.title).tag($0) }
            }
            Toggle(t("settings.window.allSpaces"), isOn: $level.showsOnAllSpaces)
        } header: {
            Text(t("settings.window.section"))
        } footer: {
            Text(t("settings.window.footer"))
        }
    }
    #endif

    private var profilesAndBouquetsSection: some View {
        Section(t("settings.profiles.section")) {
            Button {
                showingProfilesManagement = true
            } label: {
                Label(t("settings.profiles.manage"), systemImage: "person.2.badge.gearshape")
            }
        }
        .sheet(isPresented: $showingProfilesManagement) {
            NavigationStack {
                ProfilesManagementView(engine: model.engine)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(t("common.close")) { showingProfilesManagement = false }
                        }
                    }
            }
        }
    }

    private var subtitlesSection: some View {
        Section(t("settings.subtitles.section")) {
            SecureField(t("settings.subtitles.apiKey"), text: $model.openSubtitlesKey)
            TextField(t("settings.subtitles.languages"), text: $openSubtitlesLanguages)
            TextField(t("settings.subtitles.account"), text: $model.openSubtitlesUser)
                .autocorrectionDisabled()
            SecureField(t("settings.subtitles.password"), text: $model.openSubtitlesPassword)
            Toggle(t("settings.subtitles.autoSearch"), isOn: $openSubtitlesAutoSearch)
            Text(t("settings.subtitles.footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
            bundledKeyNotice(.openSubtitles, userKey: model.openSubtitlesKey)
        }
    }

    private var downloadsSection: some View {
        Section(t("settings.downloads.section")) {
            Toggle(t("settings.downloads.background"), isOn: $backgroundDownloadsEnabled)
            #if os(iOS)
            Toggle(t("settings.downloads.cellular"), isOn: $cellularDownloadsEnabled)
            Toggle(t("settings.downloads.keepAwake"), isOn: $keepScreenAwakeOnDownload)
                .onChange(of: keepScreenAwakeOnDownload) { _, newValue in
                    SystemPowerCoordinator.shared.keepScreenAwakeOnDownload = newValue
                }
            #endif
            #if !os(macOS) && !os(tvOS)
            Toggle(t("settings.downloads.notifications"), isOn: $downloadNotificationsEnabled)
            #endif
            #if os(tvOS)
            LabeledContent(t("settings.downloads.connections"), value: "\(model.connectionLimit)")
            LabeledContent(t("settings.downloads.segments"), value: "\(model.segmentsPerFile)")
            LabeledContent(t("settings.downloads.partSize"), value: t("settings.downloads.partSizeValue", model.partSizeMB))
            LabeledContent(t("settings.downloads.maxFiles"), value: "\(model.maxActiveFiles)")
            #else
            Stepper(value: $model.connectionLimit, in: ConnectionBudget.range) {
                LabeledContent(t("settings.downloads.connections"), value: "\(model.connectionLimit)")
            }
            Stepper(value: $model.segmentsPerFile, in: 1...model.budget.downloadConnections) {
                LabeledContent(t("settings.downloads.segments"), value: "\(model.segmentsPerFile)")
            }
            Stepper(value: $model.partSizeMB, in: SettingsModel.partSizeRangeMB) {
                LabeledContent(t("settings.downloads.partSize"), value: t("settings.downloads.partSizeValue", model.partSizeMB))
            }
            Stepper(value: $model.maxActiveFiles, in: 1...model.budget.downloadConnections) {
                LabeledContent(t("settings.downloads.maxFiles"), value: "\(model.maxActiveFiles)")
            }
            #endif
            Text(model.budget.pausesDuringPlayback
                 ? t("settings.downloads.pauseInfo")
                 : t("settings.downloads.freeConnectionInfo", model.budget.downloadConnections))
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent(t("settings.downloads.folder")) {
                    #if os(tvOS)
                    Text(directory.directory.path)
                        .font(.callout).lineLimit(2).truncationMode(.middle)
                        .multilineTextAlignment(.trailing)
                    #else
                    Text(directory.directory.path)
                        .font(.callout).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                    #endif
                }
                #if os(macOS)
                HStack {
                    Button(t("settings.downloads.choose")) {
                        directory.chooseDirectory()
                        model.downloadDirectoryChanged()
                    }
                    Button(t("settings.downloads.default")) {
                        directory.resetToDefault()
                        model.downloadDirectoryChanged()
                    }
                    .disabled(!directory.isCustom)
                }
                #else
                Text(t("settings.downloads.filesHint"))
                    .font(.caption).foregroundStyle(.secondary)
                #endif
                if let error = directory.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    #if !os(tvOS)
    private func librarySection(_ lib: LibraryModel) -> some View {
        Section(t("settings.library.section")) {
            NavigationLink {
                LibrarySettingsView(model: lib)
            } label: {
                Label(t("settings.library.manage"), systemImage: "folder.badge.gear")
            }
        }
    }
    #endif

    private var networkSection: some View {
        Section(t("settings.network.section")) {
            TextField(t("settings.network.userAgent"), text: $model.userAgent)
                .autocorrectionDisabled()
            TextField(t("settings.network.referer"), text: $model.referer)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        }
    }

    private var omdbSection: some View {
        Section {
            HStack {
                Group {
                    if showsOmdbKey {
                        TextField(t("settings.omdb.apiKey"), text: $model.omdbKey)
                    } else {
                        SecureField(t("settings.omdb.apiKey"), text: $model.omdbKey)
                    }
                }
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                Button { showsOmdbKey.toggle() } label: {
                    Image(systemName: showsOmdbKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showsOmdbKey ? t("settings.omdb.hideKey") : t("settings.omdb.showKey"))
            }
        } header: {
            Text(t("settings.omdb.section"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("settings.omdb.footer"))
                bundledKeyNotice(.omdb, userKey: model.omdbKey)
            }
        }
    }

    // MARK: Assistant IA

    @ViewBuilder
    private func assistantSection(_ ai: AiProviderSettings, _ assistant: AssistantModel) -> some View {
        @Bindable var ai = ai
        Section {
            Picker(t("settings.ai.provider"), selection: $ai.choice) {
                ForEach(AiChoice.allCases) { Text($0.title).tag($0) }
            }
            if ai.choice.isRemote {
                TextField(t("settings.ai.model"), text: $ai.model, prompt: Text(t("settings.ai.defaultModel")))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField(t("settings.ai.serverUrl"), text: $ai.baseURL, prompt: Text(ai.choice.baseURLPlaceholder))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                HStack {
                    Group {
                        if showsAiKey {
                            TextField(ai.choice.requiresKey ? t("settings.ai.apiKey") : t("settings.ai.apiKeyOptional"), text: $ai.apiKey)
                        } else {
                            SecureField(ai.choice.requiresKey ? t("settings.ai.apiKey") : t("settings.ai.apiKeyOptional"), text: $ai.apiKey)
                        }
                    }
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    Button { showsAiKey.toggle() } label: { Image(systemName: showsAiKey ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showsAiKey ? t("settings.omdb.hideKey") : t("settings.omdb.showKey"))
                }
                if ai.endpointIsLocal {
                    Label(t("settings.ai.localServerNote"), systemImage: "lock.shield")
                        .font(.callout).foregroundStyle(.green)
                } else {
                    Toggle(t("settings.ai.consent"), isOn: $ai.consent)
                }
                Toggle(t("settings.ai.autoSearch"), isOn: $ai.autoSearch)
                Text(t("settings.ai.autoSearchInfo"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(t("settings.ai.test")) { Task { await runAiTest(assistant) } }
                        .disabled(isTestingAi || (ai.choice.requiresKey && !ai.hasKey))
                    if isTestingAi { ProgressView().controlSize(.small) }
                    if let status = aiStatus {
                        Label(
                            status.ok ? "\(status.message) (\(status.latencyMs) ms, \(status.model))" : status.message,
                            systemImage: status.ok ? "checkmark.circle.fill" : "xmark.octagon.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(status.ok ? .green : .red)
                    }
                }
                if ai.usesBundledKey {
                    Label(t("settings.ai.bundledQuota", BundledAiQuota.dailyLimit), systemImage: "key.fill")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let blocker = ai.blocker {
                    Label(t("settings.ai.localFallbackNotice", blocker), systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let keychainError = ai.keychainError {
                    Label(keychainError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                }
                #if !os(tvOS)
                DisclosureGroup(t("settings.ai.whatIsSent")) { sentTable }
                    .font(.callout)
                #endif
            }
        } header: {
            Text(t("settings.ai.section"))
        } footer: {
            Text(assistantFooter(ai))
        }
        .onChange(of: ai.choice) { _, _ in aiStatus = nil }
    }

    private func assistantFooter(_ ai: AiProviderSettings) -> String {
        switch ai.choice {
        case .disabled: return t("settings.ai.footerDisabled")
        case .localOnly: return t("settings.ai.footerLocalOnly")
        default: return t("settings.ai.footerRemote")
        }
    }

    private var sentTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t("settings.ai.sentTitle")).font(.caption.weight(.semibold))
            Text(t("settings.ai.sentBody"))
                .font(.caption)
            Text(t("settings.ai.neverSentTitle")).font(.caption.weight(.semibold)).padding(.top, 4)
            Text(t("settings.ai.neverSentBody"))
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private func runAiTest(_ assistant: AssistantModel) async {
        isTestingAi = true
        aiStatus = await assistant.testProvider()
        isTestingAi = false
    }

    private func iCloudSection(_ sync: CloudKitSyncManager) -> some View {
        Section {
            LabeledContent(t("settings.icloud.status")) {
                HStack(spacing: 6) {
                    if sync.status == .syncing { ProgressView().controlSize(.small) }
                    Text(sync.status.title)
                }
            }
            if let detail = sync.status.detail {
                Label(detail, systemImage: sync.isAvailable ? "exclamationmark.triangle.fill" : "icloud.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(t("settings.icloud.syncNow")) { Task { await sync.syncNow() } }
                .disabled(!sync.isAvailable || sync.status == .syncing)
            Toggle(t("settings.icloud.syncPasswords"), isOn: Binding(
                get: { model.syncsPasswords },
                set: { model.setPasswordSync($0) }
            ))
            if let error = model.passwordSyncError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(t("settings.icloud.section"))
        } footer: {
            Text(t("settings.icloud.footer"))
        }
    }

    private var householdSection: some View {
        Section {
            if householdStore.isJoined {
                LabeledContent(t("settings.household.id")) {
                    Text(householdStore.householdId ?? "")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                LabeledContent(t("settings.household.localDevice")) {
                    Text("\(householdStore.deviceName) (\(householdStore.deviceType))")
                        .foregroundStyle(.secondary)
                }
                if let localSync {
                    LabeledContent(t("settings.household.networkStatus")) {
                        Text(localSync.syncStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let lastSync = localSync.lastSyncDate {
                        LabeledContent(t("settings.household.lastSync")) {
                            Text(lastSync.formatted(date: .omitted, time: .standard))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !localSync.activePeers.isEmpty {
                        ForEach(localSync.activePeers) { peer in
                            Label("\(peer.name) (\(peer.deviceType))", systemImage: peer.deviceType == "tv" ? "tv" : (peer.deviceType == "desktop" ? "laptopcomputer" : "iphone"))
                                .font(.subheadline)
                        }
                    } else {
                        Text(t("settings.household.waitingPeers"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(t("settings.household.sendData")) {
                        localSync.sendNow()
                    }
                    Button(t("settings.household.receiveData")) {
                        localSync.receiveNow()
                    }
                }
                #if os(macOS)
                Button(t("settings.household.copyKey")) {
                    if let keyHex = householdStore.currentHouseholdKeyHex() {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(keyHex, forType: .string)
                    }
                }
                #elseif os(iOS)
                Button(t("settings.household.copyKey")) {
                    if let keyHex = householdStore.currentHouseholdKeyHex() {
                        UIPasteboard.general.string = keyHex
                    }
                }
                #endif
                Button(t("settings.household.leave"), role: .destructive) {
                    householdStore.leaveHousehold()
                    localSync?.stop()
                }
            } else {
                Text(t("settings.household.intro"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button(t("settings.household.create")) {
                    _ = try? householdStore.createHousehold()
                    localSync?.start()
                }
                Button(t("settings.household.joinExisting")) {
                    showingJoinHousehold = true
                }
            }
        } header: {
            Text(t("settings.household.section"))
        } footer: {
            Text(t("settings.household.footer"))
        }
        .alert(t("settings.household.joinAlertTitle"), isPresented: $showingJoinHousehold) {
            TextField(t("settings.household.joinKeyPlaceholder"), text: $joinKeyInput)
            Button(t("settings.household.joinButton")) {
                _ = try? householdStore.joinHousehold(keyHex: joinKeyInput)
                joinKeyInput = ""
                localSync?.start()
            }
            Button(t("common.cancel"), role: .cancel) {
                joinKeyInput = ""
            }
        } message: {
            Text(t("settings.household.joinAlertMessage"))
        }
    }

    private var diagnosticSection: some View {
        Section(t("settings.diagnostic.section")) {
            Toggle(t("settings.diagnostic.showConsole"), isOn: $model.showNetworkConsole)
            HStack {
                Button(t("settings.diagnostic.clearImageCache")) { Task { await model.clearImageCache() } }
                if let date = model.cacheClearedAt {
                    Text(t("settings.diagnostic.clearedAt", date.formatted(date: .omitted, time: .standard))).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }

    /// "Clé intégrée utilisée" under a key field that is empty while the build carries a default key.
    @ViewBuilder
    private func bundledKeyNotice(_ service: ApiService, userKey: String) -> some View {
        let resolver = ApiKeyResolver.shared
        if resolver.hasBundledKey(service),
           userKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Label(t("settings.bundledKeyNotice"), systemImage: "key.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section(t("settings.about.section")) {
            HStack(spacing: 12) {
                AppLogoView(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppBrand.name).font(.headline)
                    Text(AppBrand.descriptor).font(.caption).foregroundStyle(.secondary)
                }
            }
            LabeledContent(t("settings.about.app"), value: SettingsModel.appVersion)
            LabeledContent(t("settings.about.rustEngine"), value: model.engineVersion)
            LabeledContent(t("settings.about.creator"), value: AppBrand.authorName)
            LabeledContent(t("settings.about.email"), value: AppBrand.authorEmail)
            LabeledContent(t("settings.about.country"), value: AppBrand.authorCountry)
            LabeledContent(t("settings.about.license"), value: AppBrand.license)
            LabeledContent(t("settings.about.bundledKeys")) {
                let services = ApiService.allCases.filter { ApiKeyResolver.shared.hasBundledKey($0) }
                Text(services.isEmpty ? t("common.none") : services.map(\.displayName).joined(separator: ", "))
                    .multilineTextAlignment(.trailing)
            }
            if let stats {
                AboutDetailView.statsRows(for: stats)
            }
            NavigationLink(t("settings.about.aboutBuntu")) {
                AboutDetailView(engineVersion: model.engineVersion, stats: stats)
            }
        }
    }
}

/// Full About page showing Buntu identity, creator information, application versions, stats, and legal notice.
struct AboutDetailView: View {
    let engineVersion: String
    let stats: DbStats?
    @State private var languageStore = AppLanguageStore.shared

    private func t(_ key: String) -> String { languageStore.t(key) }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    AppLogoView(size: 72)
                    Text(AppBrand.name)
                        .font(.title2.weight(.bold))
                    Text(AppBrand.sloganWolof)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(AppBrand.sloganFrench)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text(AppBrand.descriptor)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section(t("settings.about.creator")) {
                LabeledContent(t("settings.about.creator"), value: AppBrand.authorName)
                #if os(tvOS)
                LabeledContent(t("settings.about.email"), value: AppBrand.authorEmail)
                #else
                LabeledContent(t("settings.about.email"), value: AppBrand.authorEmail)
                    .textSelection(.enabled)
                #endif
                LabeledContent(t("settings.about.country"), value: AppBrand.authorCountry)
            }

            Section(t("settings.about.app")) {
                LabeledContent(t("settings.about.app"), value: SettingsModel.appVersion)
                LabeledContent(t("settings.about.rustEngine"), value: engineVersion)
                LabeledContent(t("settings.about.license"), value: AppBrand.license)
                if let stats {
                    Self.statsRows(for: stats)
                }
            }

            Section {
                Text(AppBrand.neutralPlayerNotice)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(t("settings.about.aboutBuntu"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    static func statsRows(for stats: DbStats) -> some View {
        let lang = AppLanguageStore.shared
        LabeledContent(lang.t("settings.about.database"), value: ByteCountFormatter.string(fromByteCount: Int64(stats.dbSizeBytes), countStyle: .file))
        LabeledContent(lang.t("settings.about.counts"), value: "\(stats.totalLiveChannels) / \(stats.totalMovies) / \(stats.totalSeries)")
        LabeledContent(lang.t("settings.about.favBroken"), value: "\(stats.totalFavorites) / \(stats.totalBroken)")
    }
}
