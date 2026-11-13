package com.pcoundia.buntu.core.data.repository

import com.pcoundia.buntu.core.domain.repository.HouseholdInviteCodec
import com.pcoundia.buntu.core.engine.EngineProvider
import com.pcoundia.buntu.core.engine.ffi.syncHouseholdInviteLink
import com.pcoundia.buntu.core.engine.ffi.syncHouseholdKeyFromScanned
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

/** [HouseholdInviteCodec] backed by `cnd-core` (`sync_household_invite_link`, `sync_household_key_from_scanned`). */
@Singleton
class RustHouseholdInviteCodec @Inject constructor(
    private val engineProvider: EngineProvider,
) : HouseholdInviteCodec {

    override suspend fun inviteLink(keyHex: String): String? = withContext(Dispatchers.IO) {
        // Waiting for the engine guarantees the native library is loaded before the first call.
        engineProvider.awaitEngine()
        syncHouseholdInviteLink(keyHex)
    }

    override suspend fun keyFromScanned(text: String): String? = withContext(Dispatchers.IO) {
        engineProvider.awaitEngine()
        syncHouseholdKeyFromScanned(text)
    }
}
