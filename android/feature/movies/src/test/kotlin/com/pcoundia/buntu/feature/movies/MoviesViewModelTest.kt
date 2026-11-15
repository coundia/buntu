package com.pcoundia.buntu.feature.movies

import com.pcoundia.buntu.core.domain.model.CategoryFacet
import com.pcoundia.buntu.core.domain.repository.CatalogRepository
import com.pcoundia.buntu.core.domain.repository.ProfilesRepository
import com.pcoundia.buntu.core.domain.repository.RecommendationsRepository
import com.pcoundia.buntu.core.domain.repository.RemotePlaybackRepository
import com.pcoundia.buntu.core.domain.repository.SecretStore
import com.pcoundia.buntu.core.domain.repository.SettingsRepository
import com.pcoundia.buntu.core.domain.usecase.LoadShelvesUseCase
import com.pcoundia.buntu.core.domain.usecase.PlayOnAnotherDeviceUseCase
import kotlinx.collections.immutable.persistentListOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import java.lang.reflect.Proxy

@OptIn(ExperimentalCoroutinesApi::class)
class MoviesViewModelTest {

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    /**
     * The engine files films under the kind "movie" (the paging source and the Apple app use it). Asking for
     * "vod" matched no row, so the categories of the Movies screen, and its drawer, were empty.
     */
    @Test
    fun `movie categories are requested with the engine kind movie`() = runTest {
        val kinds = mutableListOf<String>()
        val catalog = stub<CatalogRepository> { name, args ->
            if (name == "getGroups") {
                kinds += args!![0] as String
                persistentListOf(CategoryFacet("Action", 3), CategoryFacet("Drame", 2))
            } else {
                null
            }
        }
        val shelves = LoadShelvesUseCase(
            stub<RecommendationsRepository>(),
            stub<ProfilesRepository>(),
            stub<SettingsRepository>(),
            stub<SecretStore>(),
        )
        val vm = MoviesViewModel(catalog, shelves, PlayOnAnotherDeviceUseCase(stub<RemotePlaybackRepository>()))

        assertEquals(listOf("movie"), kinds)
        assertEquals(listOf("Action", "Drame"), vm.uiState.value.categories.toList())
    }

    /** A repository whose every method returns an empty value, unless [handler] answers. */
    private inline fun <reified T : Any> stub(crossinline handler: (String, Array<Any?>?) -> Any? = { _, _ -> null }): T =
        Proxy.newProxyInstance(T::class.java.classLoader, arrayOf(T::class.java)) { _, method, args ->
            handler(method.name, args) ?: when (method.returnType) {
                kotlinx.coroutines.flow.StateFlow::class.java -> MutableStateFlow<Any?>(emptyList<Any>())
                kotlinx.coroutines.flow.SharedFlow::class.java -> MutableSharedFlow<Any?>()
                kotlinx.coroutines.flow.Flow::class.java -> emptyFlow<Any?>()
                kotlinx.collections.immutable.ImmutableList::class.java -> persistentListOf<Any?>()
                java.lang.Boolean.TYPE -> false
                else -> null
            }
        } as T
}
