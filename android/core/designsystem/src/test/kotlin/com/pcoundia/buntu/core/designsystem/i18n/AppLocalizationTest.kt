package com.pcoundia.buntu.core.designsystem.i18n

import com.pcoundia.buntu.core.designsystem.filterCategories
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppLocalizationTest {

    @After
    fun resetLanguageToDefault() {
        AppLanguageState.setLanguage(AppLanguage.FR)
    }

    @Test
    fun `default language is French`() {
        assertEquals(AppLanguage.FR, AppLanguageState.current)
        assertEquals("fr", AppLanguage.FR.code)
        assertEquals("Français", AppLanguage.FR.label)
        assertEquals("Réglages", AppLanguageState.translate("settings.title"))
    }

    @Test
    fun `switching to English updates reactive state and translations`() {
        AppLanguageState.setLanguage(AppLanguage.EN)

        assertEquals(AppLanguage.EN, AppLanguageState.current)
        assertEquals(AppLanguage.EN, AppLanguageState.language.value)
        assertEquals("Settings", AppLanguageState.translate("settings.title"))
        assertEquals("Household Devices", AppLanguageState.translate("devices.title"))
        assertEquals("TV Remote", AppLanguageState.translate("remote.title"))
        assertEquals("Live", AppLanguageState.translate("nav.live"))
    }

    @Test
    fun `fromCode resolves known codes and falls back to FR`() {
        assertEquals(AppLanguage.EN, AppLanguage.fromCode("en"))
        assertEquals(AppLanguage.EN, AppLanguage.fromCode("EN"))
        assertEquals(AppLanguage.FR, AppLanguage.fromCode("fr"))
        assertEquals(AppLanguage.FR, AppLanguage.fromCode(null))
        assertEquals(AppLanguage.FR, AppLanguage.fromCode("es"))
    }

    @Test
    fun `frStrings and enStrings have 100 percent key parity and non-blank values`() {
        val missingInEn = frStrings.keys - enStrings.keys
        val extraInEn = enStrings.keys - frStrings.keys

        assertTrue("Keys missing in enStrings: $missingInEn", missingInEn.isEmpty())
        assertTrue("Extra keys in enStrings not in frStrings: $extraInEn", extraInEn.isEmpty())
        assertEquals(frStrings.size, enStrings.size)

        frStrings.forEach { (key, value) ->
            assertFalse("frStrings[$key] must not be blank", value.isBlank())
        }
        enStrings.forEach { (key, value) ->
            assertFalse("enStrings[$key] must not be blank", value.isBlank())
        }
    }

    @Test
    fun `translate formats arguments properly in FR and EN`() {
        assertEquals(
            "Connexions de mon abonnement : 3",
            AppLanguageState.translate("settings.network.connections", 3, lang = AppLanguage.FR),
        )
        assertEquals(
            "Subscription connections: 3",
            AppLanguageState.translate("settings.network.connections", 3, lang = AppLanguage.EN),
        )
    }

    @Test
    fun `live movies and series keys translate properly in FR and EN`() {
        assertEquals("TV en direct", AppLanguageState.translate("live.inline_default_title", lang = AppLanguage.FR))
        assertEquals("Live TV", AppLanguageState.translate("live.inline_default_title", lang = AppLanguage.EN))
        assertEquals("Chaîne 12 ⏎", AppLanguageState.translate("live.numeric_zap", "12", lang = AppLanguage.FR))
        assertEquals("Channel 12 ⏎", AppLanguageState.translate("live.numeric_zap", "12", lang = AppLanguage.EN))

        assertEquals("Films", AppLanguageState.translate("movies.title", lang = AppLanguage.FR))
        assertEquals("Movies", AppLanguageState.translate("movies.title", lang = AppLanguage.EN))

        assertEquals("Séries", AppLanguageState.translate("series.title", lang = AppLanguage.FR))
        assertEquals("Series", AppLanguageState.translate("series.title", lang = AppLanguage.EN))
        assertEquals("1 saison", AppLanguageState.translate("series.season_one", 1, lang = AppLanguage.FR))
        assertEquals("1 season", AppLanguageState.translate("series.season_one", 1, lang = AppLanguage.EN))
        assertEquals("3 saisons", AppLanguageState.translate("series.season_many", 3, lang = AppLanguage.FR))
        assertEquals("3 seasons", AppLanguageState.translate("series.season_many", 3, lang = AppLanguage.EN))
    }

    @Test
    fun `category search keys translate properly in FR and EN`() {
        assertEquals("Catégories…", AppLanguageState.translate("categories.search_chip", lang = AppLanguage.FR))
        assertEquals("Categories…", AppLanguageState.translate("categories.search_chip", lang = AppLanguage.EN))
        assertEquals("Rechercher une catégorie…", AppLanguageState.translate("categories.search_placeholder", lang = AppLanguage.FR))
        assertEquals("Search category…", AppLanguageState.translate("categories.search_placeholder", lang = AppLanguage.EN))
        assertEquals("Fermer le lecteur", AppLanguageState.translate("live.close_player", lang = AppLanguage.FR))
        assertEquals("Close player", AppLanguageState.translate("live.close_player", lang = AppLanguage.EN))
    }

    @Test
    fun `filterCategories matches case-insensitively and handles blank or missing queries`() {
        val categories = listOf("Sénégal", "Sports HD", "Cinéma", "Documentaire")
        assertEquals(categories, filterCategories(categories, ""))
        assertEquals(categories, filterCategories(categories, "   "))
        assertEquals(listOf("Sports HD"), filterCategories(categories, "sport"))
        assertEquals(listOf("Sénégal", "Sports HD"), filterCategories(categories, "s"))
        assertTrue(filterCategories(categories, "anime").isEmpty())
    }
}
