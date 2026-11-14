package com.pcoundia.buntu.core.designsystem.i18n

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.Locale

enum class AppLanguage(val code: String, val label: String) {
    FR("fr", "Français"),
    EN("en", "English"),
    ;

    val locale: Locale
        get() = when (this) {
            FR -> Locale.FRENCH
            EN -> Locale.ENGLISH
        }

    companion object {
        fun fromCode(code: String?): AppLanguage =
            entries.firstOrNull { it.code.equals(code, ignoreCase = true) } ?: FR
    }
}

object AppLanguageState {
    const val PREFS_NAME = "buntu_app_preferences"
    const val PREF_KEY = "buntu_app_language"

    private val _language = MutableStateFlow(AppLanguage.FR)
    val language: StateFlow<AppLanguage> = _language.asStateFlow()

    val current: AppLanguage
        get() = _language.value

    fun init(context: Context) {
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val saved = prefs.getString(PREF_KEY, null)
        _language.value = AppLanguage.fromCode(saved)
    }

    fun setLanguage(lang: AppLanguage, context: Context? = null) {
        _language.value = lang
        if (context != null) {
            context.applicationContext
                .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(PREF_KEY, lang.code)
                .apply()
        }
    }

    fun translate(key: String, lang: AppLanguage = _language.value): String {
        return when (lang) {
            AppLanguage.FR -> frStrings[key] ?: key
            AppLanguage.EN -> enStrings[key] ?: frStrings[key] ?: key
        }
    }

    fun translate(key: String, vararg args: Any, lang: AppLanguage = _language.value): String {
        val template = translate(key, lang)
        return if (args.isEmpty()) {
            template
        } else {
            String.format(lang.locale, template, *args)
        }
    }
}

@Composable
fun rememberAppLanguage(): AppLanguage {
    val lang by AppLanguageState.language.collectAsState()
    return lang
}

@Composable
fun t(key: String): String {
    val lang = rememberAppLanguage()
    return AppLanguageState.translate(key, lang)
}

@Composable
fun t(key: String, vararg args: Any): String {
    val lang = rememberAppLanguage()
    return AppLanguageState.translate(key, *args, lang = lang)
}
