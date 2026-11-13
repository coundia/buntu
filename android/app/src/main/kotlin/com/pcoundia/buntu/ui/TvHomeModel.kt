package com.pcoundia.buntu.ui

import com.pcoundia.buntu.navigation.BuntuRoutes

/** What the TV home offers: the same three sections and shortcuts as the Samsung TV home (`HomeView.tsx`). */
object TvHomeModel {
    const val TAGLINE = "Votre télévision, simplement."
    const val HEADLINE = "Que voulez-vous regarder ?"
    const val WELCOME = "BIENVENUE CHEZ VOUS"

    enum class Section(val route: String, val title: String, val subtitle: String, val detail: String) {
        LIVE(BuntuRoutes.LIVE, "Live", "En direct", "Vos chaînes et le guide TV"),
        MOVIES(BuntuRoutes.MOVIES, "Films", "À votre rythme", "Le cinéma, quand vous voulez"),
        SERIES(BuntuRoutes.SERIES, "Séries", "Épisode après épisode", "Retrouvez vos séries préférées"),
    }

    /** `route` is `null` for « Quitter ». */
    enum class Shortcut(val route: String?, val title: String) {
        SOURCES(BuntuRoutes.SOURCES, "Sources"),
        DEVICES(BuntuRoutes.DEVICES, "Appareils"),
        SETTINGS(BuntuRoutes.SETTINGS, "Réglages"),
        EXIT(null, "Quitter"),
    }

    fun clock(hour: Int, minute: Int): String = "%02d:%02d".format(hour, minute)

    /** The TV opens on the home chooser once an account exists; first launch goes through onboarding. */
    fun startDestination(isTelevision: Boolean, onboardingDone: Boolean): String = when {
        !onboardingDone -> BuntuRoutes.ONBOARDING
        isTelevision -> BuntuRoutes.HOME
        else -> BuntuRoutes.LIVE
    }
}
