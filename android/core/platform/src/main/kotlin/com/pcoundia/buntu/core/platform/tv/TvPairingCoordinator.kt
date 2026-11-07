package com.pcoundia.buntu.core.platform.tv

import com.pcoundia.buntu.core.domain.usecase.SyncSourceUseCase
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

/** A phone wants to add accounts: shown on the TV until the user decides with the remote. */
data class IncomingPairingUi(val from: String, val sources: ImmutableList<IncomingSourceUi>)

data class IncomingSourceUi(val name: String, val isXtream: Boolean, val host: String, val hasPassword: Boolean)

data class TvPairingState(
    val session: PairingSession? = null,
    val incoming: IncomingPairingUi? = null,
    val isSyncing: Boolean = false,
    val error: String? = null,
)

/**
 * PRD-39 § 5.2: one place that runs the TV side of pairing for every screen that offers it (first launch,
 * Sources): the session, the confirmation with the remote, and the adding of the accounts one after the other.
 */
@Singleton
class TvPairingCoordinator @Inject constructor(
    private val server: QrPairingServer,
    private val syncSource: SyncSourceUseCase,
) {
    private val _state = MutableStateFlow(TvPairingState())
    val state: StateFlow<TvPairingState> = _state.asStateFlow()

    /** The user's answer to the confirmation card, set by the remote. */
    @Volatile private var pending: CompletableDeferred<Boolean>? = null
    @Volatile private var startJob: Job? = null

    /** Starts (or restarts) a session off the Main Thread; [onAdded] runs after accounts were added. */
    fun start(scope: CoroutineScope, onAdded: suspend (count: Int) -> Unit = {}) {
        startJob?.cancel()
        startJob = scope.launch(Dispatchers.IO) {
            val session = server.start(
                scope = scope,
                onIncoming = { incoming -> decide(incoming, onAdded) },
                onClosed = { reason -> if (reason != PairingClosedReason.Done) start(scope, onAdded) },
            )
            _state.update {
                it.copy(
                    session = session,
                    error = if (session == null) "Aucune connexion réseau Wi-Fi / Ethernet détectée sur la TV." else null,
                )
            }
        }
    }

    fun confirm() { pending?.complete(true) }

    fun refuse() { pending?.complete(false) }

    fun stop() {
        startJob?.cancel()
        startJob = null
        pending?.complete(false)
        server.stop()
        _state.value = TvPairingState()
    }

    private suspend fun decide(incoming: IncomingPairing, onAdded: suspend (Int) -> Unit): PairingDecision {
        // Session expiry was already verified against the TV's own clock by `pairing.open`;
        // pass nowSeconds = 0L so wall-clock skew between Phone and TV never drops the request.
        val sources = runCatching { SharedSources.parse(incoming.shareJson, nowSeconds = 0L) }.getOrElse { err ->
            _state.update { it.copy(error = err.message) }
            return PairingDecision.Failed
        }
        val decision = CompletableDeferred<Boolean>()
        pending = decision
        _state.update {
            it.copy(
                error = null,
                incoming = IncomingPairingUi(
                    from = incoming.from,
                    sources = sources.map { s -> IncomingSourceUi(s.name, s.isXtream, s.host, s.hasPassword) }.toImmutableList(),
                ),
            )
        }
        val accepted = decision.await()
        pending = null
        _state.update { it.copy(incoming = null) }
        if (!accepted) return PairingDecision.Refused

        _state.update { it.copy(isSyncing = true) }
        var added = 0
        for (s in sources) {
            // One subscription, one connection: the playlists are downloaded one after the other.
            val ok = runCatching {
                if (s.isXtream) {
                    syncSource.addAndSyncXtream(s.name, s.server!!, s.username!!, s.password.orEmpty())
                } else {
                    syncSource.addAndSyncM3u(s.name, s.url!!)
                }
            }.isSuccess
            if (ok) added++
        }
        if (added > 0) runCatching { onAdded(added) }
        _state.update {
            it.copy(isSyncing = false, error = if (added == 0) "Aucun compte n'a pu être ajouté." else null)
        }
        return if (added > 0) PairingDecision.Added(added) else PairingDecision.Failed
    }
}
