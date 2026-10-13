package com.dhanuk.ovidai

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context

/**
 * Periodic safety net used when exact alarms are not allowed (the inexact
 * alarm may be deferred for hours by Doze or OEM policy). Every ~15 minutes
 * (Android's minimum period; the OS may batch it later) the job checks the
 * persisted deadline and, when it has passed, fires the same path as the
 * alarm. This is the platform scheduler WorkManager itself uses on API 23+,
 * without adding a dependency.
 */
class ScheduleFallbackJob : JobService() {
    companion object {
        const val JOB_ID = 41_011
        const val PERIOD_MS = 15 * 60 * 1000L

        fun ensure(context: Context) {
            val scheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as? JobScheduler ?: return
            if (scheduler.allPendingJobs.any { it.id == JOB_ID }) return
            val job = JobInfo.Builder(JOB_ID, ComponentName(context, ScheduleFallbackJob::class.java))
                .setPeriodic(PERIOD_MS)
                .setPersisted(true) // survives reboot (RECEIVE_BOOT_COMPLETED)
                .build()
            try { scheduler.schedule(job) } catch (_: Exception) { }
        }

        fun cancel(context: Context) {
            val scheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as? JobScheduler ?: return
            scheduler.cancel(JOB_ID)
        }

        /** Pure decision, unit-tested: fire when a deadline exists and is due. */
        fun isDue(deadline: Long, now: Long, stopped: Boolean): Boolean =
            !stopped && deadline > 0 && deadline <= now
    }

    override fun onStartJob(params: JobParameters?): Boolean {
        val deadline = BackgroundScheduleState.nextDeadline(this)
        val stopped = BackgroundScheduleState.stopped(this)
        if (stopped || deadline <= 0) {
            cancel(this)
        } else if (isDue(deadline, System.currentTimeMillis(), stopped)) {
            BackgroundScheduleState.fire(this)
        }
        return false
    }

    override fun onStopJob(params: JobParameters?): Boolean = true
}
