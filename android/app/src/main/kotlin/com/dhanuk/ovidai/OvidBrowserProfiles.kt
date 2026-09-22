package com.dhanuk.ovidai

import android.webkit.CookieManager
import android.webkit.WebView
import androidx.webkit.Profile
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature

/**
 * Per-session browser identities built on the AndroidX WebKit multi-profile API.
 *
 * WHY: every chat session must own its OWN cookie jar / web storage, so a
 * Google login performed in chat A is invisible from chat B (session
 * isolation). The profile is named after the session id, so isolation also
 * survives an app restart for free — the same session gets the same profile
 * back.
 *
 * RESTART SHARING: once per launch the caller may ask for the accumulated
 * cookies to be propagated into every session profile ("share logins on
 * restart"). That is done with [shareCookies] because androidx.webkit 1.12
 * (the version pinned by webview_flutter_android 3.16.9) has no
 * `Profile.setProfileData` — only cookie propagation is possible. Cookies are
 * what carries a login for Google/GitHub/etc., so this is the meaningful part.
 *
 * FALLBACK: MULTI_PROFILE needs a WebView implementing the Profile API
 * (WebView 125+). On older WebViews, in unit tests, and on non-Android
 * platforms every helper here is a no-op and tabs keep using the process-wide
 * cookie jar — the previous shared behaviour. Nothing crashes.
 */
object OvidBrowserProfiles {

    /** True when the installed WebView supports the Profile API. */
    fun supported(): Boolean = try {
        WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)
    } catch (t: Throwable) {
        false
    }

    /**
     * Bind [webView] to the cookie/storage profile [profileName].
     *
     * MUST run before the WebView navigates or evaluates any JavaScript
     * (`WebViewCompat.setProfile` throws IllegalStateException otherwise), and
     * cannot be re-applied to the same WebView — the Dart side calls this
     * exactly once, right after the controller is created and before the first
     * load.
     *
     * @return true when the profile was applied.
     */
    fun bind(webView: WebView, profileName: String): Boolean {
        if (profileName.isBlank() || !supported()) return false
        return try {
            WebViewCompat.setProfile(webView, profileName)
            true
        } catch (t: Throwable) {
            // Already navigated / profile already set / provider quirk: the tab
            // keeps the default shared jar rather than crashing the browser.
            false
        }
    }

    /** Every profile name the WebView provider currently holds. */
    fun profileNames(): List<String> {
        if (!supported()) return emptyList()
        return try {
            ProfileStore.getInstance().allProfileNames.toList()
        } catch (t: Throwable) {
            emptyList()
        }
    }

    /** Drop [profileName] (its cookie jar and web storage) if it exists. */
    fun delete(profileName: String): Boolean {
        if (profileName.isBlank() || !supported()) return false
        return try {
            // NOTE: deliberately NOT calling getProfile() first — loading a
            // profile into memory makes deleteProfile throw
            // IllegalStateException ("loaded in the memory using
            // getOrCreateProfile or getProfile"). deleteProfile itself reports
            // whether the profile existed.
            ProfileStore.getInstance().deleteProfile(profileName)
        } catch (t: Throwable) {
            // Live WebViews still hold the profile (IllegalStateException) or
            // the name is the default profile (IllegalArgumentException). The
            // Dart side re-queues the delete for the next launch.
            false
        }
    }

    /**
     * Cookie managers for [profileNames], skipping names the provider does not
     * know. Never contains the default profile unless it was named explicitly.
     */
    private fun cookieManagers(profileNames: List<String>): List<CookieManager> {
        if (!supported()) return emptyList()
        val store = try {
            ProfileStore.getInstance()
        } catch (t: Throwable) {
            return emptyList()
        }
        val out = ArrayList<CookieManager>(profileNames.size)
        for (name in profileNames) {
            try {
                val profile: Profile = store.getProfile(name) ?: continue
                out.add(profile.cookieManager)
            } catch (t: Throwable) {
                // UnsupportedOperationException on providers without the API.
            }
        }
        return out
    }

    /**
     * Copy the cookie jar of every profile in [profileNames] into every other
     * one, restricted to [urls] (the origins the user actually browsed — the
     * platform offers no way to enumerate a jar, so origins must be supplied).
     *
     * The first non-blank cookie header found for an origin wins and is written
     * to the remaining profiles. `CookieManager.setCookie` replaces by
     * name+domain+path, so re-running this is idempotent and never duplicates.
     *
     * @return number of (profile, origin) writes performed.
     */
    fun shareCookies(profileNames: List<String>, urls: List<String>): Int {
        if (urls.isEmpty()) return 0
        val managers = cookieManagers(profileNames)
        if (managers.size < 2) return 0
        var writes = 0
        for (url in urls) {
            if (url.isBlank()) continue
            val header = firstCookieHeader(managers, url) ?: continue
            val pairs = cookiePairs(header)
            if (pairs.isEmpty()) continue
            for (manager in managers) {
                try {
                    if (manager.getCookie(url) == header) continue
                    // setCookie takes exactly ONE cookie per call, so a merged
                    // header has to be replayed pair by pair.
                    for (pair in pairs) {
                        manager.setCookie(url, pair)
                        writes++
                    }
                    manager.flush()
                } catch (t: Throwable) {
                    // Ignore a single profile failure; the rest still sync.
                }
            }
        }
        return writes
    }

    /**
     * Wipe cookies in [profileNames].
     *
     * With no [urls] the whole jar of each profile is removed
     * (`CookieManager.removeAllCookies`); with [urls] only the cookies actually
     * present for those origins are expired, because the platform has no
     * per-origin bulk delete. `CookieManager` has no API to enumerate a jar, so
     * the headers are read first and each pair is expired by name.
     *
     * @return number of (profile, cookie) removals performed.
     */
    fun clearCookies(profileNames: List<String>, urls: List<String>): Int {
        val managers = cookieManagers(profileNames)
        if (managers.isEmpty()) return 0
        if (urls.isEmpty()) {
            var removed = 0
            for (manager in managers) {
                try {
                    manager.removeAllCookies(null)
                    manager.flush()
                    removed++
                } catch (t: Throwable) {
                }
            }
            return removed
        }
        var writes = 0
        for (url in urls) {
            if (url.isBlank()) continue
            for (manager in managers) {
                try {
                    val header = manager.getCookie(url) ?: continue
                    for (pair in cookiePairs(header)) {
                        val name = pair.substringBefore('=')
                        if (name.isBlank()) continue
                        // An expired cookie of the same name/path removes it.
                        manager.setCookie(url, "$name=; Max-Age=0; path=/")
                        writes++
                    }
                    manager.flush()
                } catch (t: Throwable) {
                }
            }
        }
        return writes
    }

    /**
     * The `name=value` pairs a cookie header contains, as separate cookies.
     * `CookieManager.setCookie` accepts exactly ONE cookie per call, so a
     * merged header must be split before writing it anywhere else.
     */
    fun cookiePairs(header: String?): List<String> {
        if (header.isNullOrBlank()) return emptyList()
        return header.split(';')
            .map { it.trim() }
            .filter { it.isNotEmpty() && it.contains('=') }
    }

    private fun firstCookieHeader(managers: List<CookieManager>, url: String): String? {
        for (manager in managers) {
            try {
                val cookie = manager.getCookie(url)
                if (!cookie.isNullOrBlank()) return cookie
            } catch (t: Throwable) {
            }
        }
        return null
    }
}
