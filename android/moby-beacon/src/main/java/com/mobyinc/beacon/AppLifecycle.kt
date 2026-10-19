package com.mobyinc.beacon

import android.os.Handler
import android.os.Looper
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner

/** Receives the app's foreground changes. Called on the main thread in production. */
internal interface LifecycleListener {
    /** The app came to the foreground (`ProcessLifecycleOwner` `ON_START`). */
    fun onStart()

    /** The app left the foreground (`ProcessLifecycleOwner` `ON_STOP`). */
    fun onStop()
}

/**
 * Delivers foreground changes to a [LifecycleListener]. [ProcessLifecycleSource]
 * is the production implementation; tests drive a fake directly.
 */
internal interface LifecycleSource {
    /** Starts delivering changes to [listener]. */
    fun start(listener: LifecycleListener)

    /** Stops delivering changes. A change already in flight may still arrive. */
    fun stop()
}

/**
 * Observes [ProcessLifecycleOwner]. Registration happens on the main thread;
 * [start] and [stop] post there when called elsewhere, in order, so a [stop]
 * that comes before the posted registration runs simply skips it.
 */
internal class ProcessLifecycleSource : LifecycleSource {
    @Volatile private var stopped = false
    @Volatile private var observer: DefaultLifecycleObserver? = null

    override fun start(listener: LifecycleListener) {
        val observer = object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) = listener.onStart()
            override fun onStop(owner: LifecycleOwner) = listener.onStop()
        }
        this.observer = observer
        runOnMain {
            // stop() may have run first; adding now would leak the observer.
            if (!stopped) ProcessLifecycleOwner.get().lifecycle.addObserver(observer)
        }
    }

    override fun stop() {
        stopped = true
        runOnMain {
            observer?.let { ProcessLifecycleOwner.get().lifecycle.removeObserver(it) }
        }
    }

    private companion object {
        val mainHandler: Handler by lazy { Handler(Looper.getMainLooper()) }

        fun runOnMain(block: () -> Unit) {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                block()
            } else {
                mainHandler.post { block() }
            }
        }
    }
}
