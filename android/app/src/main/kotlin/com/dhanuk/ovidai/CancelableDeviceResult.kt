package com.dhanuk.ovidai

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/** Settles immediately on Stop; late callbacks cannot reply twice. */
internal class CancelableDeviceResult(private val delegate: MethodChannel.Result) : MethodChannel.Result {
    private val settled = AtomicBoolean(false)
    private val main = Handler(Looper.getMainLooper())
    val ticket = deviceActions.ticket { cancelled() }

    private fun reply(body: () -> Unit) {
        if (!settled.compareAndSet(false, true)) return
        ticket?.finish()
        if (Looper.myLooper() == Looper.getMainLooper()) body() else main.post { body() }
    }
    fun cancelled() = reply { delegate.error("CANCELLED", "Control stopped.", null) }
    override fun success(result: Any?) = reply { delegate.success(result) }
    override fun error(code: String, message: String?, details: Any?) =
        reply { delegate.error(code, message, details) }
    override fun notImplemented() = reply { delegate.notImplemented() }
}
