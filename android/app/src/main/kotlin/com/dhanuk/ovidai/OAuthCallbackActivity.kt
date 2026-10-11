package com.dhanuk.ovidai

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Receives the MCP OAuth redirect (`com.dhanuk.ovidai://oauth/callback?...`)
 * from the Custom Tab / browser and hands it to the existing [MainActivity].
 *
 * MainActivity is `singleTop` with an empty task affinity, so letting the
 * browser target it directly would stack a second Flutter activity above the
 * Custom Tab. This trampoline forwards the VIEW intent with
 * NEW_TASK | CLEAR_TOP | SINGLE_TOP: the existing task is reused, the Custom
 * Tab above MainActivity is cleared, and `app_links` receives the URI through
 * `onNewIntent` (or `getInitialLink` after process death).
 */
class OAuthCallbackActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val data = intent?.data
        if (data != null && data.scheme == "com.dhanuk.ovidai" && data.host == "oauth") {
            val forward = Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                setData(data)
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                )
            }
            startActivity(forward)
        }
        finish()
    }
}
