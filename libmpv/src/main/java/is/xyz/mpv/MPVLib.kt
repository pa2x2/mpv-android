package `is`.xyz.mpv

import android.content.Context
import android.graphics.Bitmap
import android.view.Surface

/**
 * Wrapper for native library
 *
 * MPVLib doesn't load its native libraries: the host must load them before the first call to
 * any of the `external` functions, once per process, dependencies first. The order for each ABI
 * is in the `assets/libmpv/load-order.json` that comes with the libraries (in the AAR and as a
 * release asset), and is `libplayer.so`, which holds these functions, last. An app that bundles
 * the libraries in its own APK can call `System.loadLibrary("mpv")` and then `("player")`, and
 * the linker finds the rest next to them. Using MPVLib before that fails with
 * `UnsatisfiedLinkError` but leaves the class usable once the libraries are loaded.
 */
@Suppress("unused")
object MPVLib {
    /**
     * The level of the JNI glue between this class and `libplayer.so`: the `external` functions
     * and what the native side looks up in Java, listed in `libmpv/glue/level-<N>.txt`. The
     * native libraries of any release with the same level work with this class, so a host may
     * load newer ones than it was built with. The release build fails if the glue changes and
     * this doesn't go up.
     */
    const val GLUE_LEVEL: Int = 1

    external fun create(appctx: Context)
    external fun init()
    external fun destroy()
    external fun attachSurface(surface: Surface)
    external fun detachSurface()

    external fun command(cmd: Array<out String>)

    external fun setOptionString(name: String, value: String): Int

    external fun grabThumbnail(dimension: Int): Bitmap?

    external fun getPropertyInt(property: String): Int?
    external fun setPropertyInt(property: String, value: Int)
    external fun getPropertyDouble(property: String): Double?
    external fun setPropertyDouble(property: String, value: Double)
    external fun getPropertyBoolean(property: String): Boolean?
    external fun setPropertyBoolean(property: String, value: Boolean)
    external fun getPropertyString(property: String): String?
    external fun setPropertyString(property: String, value: String)

    external fun observeProperty(property: String, format: Int)

    private val observers = mutableListOf<EventObserver>()

    @JvmStatic
    fun addObserver(o: EventObserver) {
        synchronized(observers) {
            observers.add(o)
        }
    }

    @JvmStatic
    fun removeObserver(o: EventObserver) {
        synchronized(observers) {
            observers.remove(o)
        }
    }

    @JvmStatic
    fun eventProperty(property: String, value: Long) {
        synchronized(observers) {
            for (o in observers)
                o.eventProperty(property, value)
        }
    }

    @JvmStatic
    fun eventProperty(property: String, value: Boolean) {
        synchronized(observers) {
            for (o in observers)
                o.eventProperty(property, value)
        }
    }

    @JvmStatic
    fun eventProperty(property: String, value: Double) {
        synchronized(observers) {
            for (o in observers)
                o.eventProperty(property, value)
        }
    }

    @JvmStatic
    fun eventProperty(property: String, value: String) {
        synchronized(observers) {
            for (o in observers)
                o.eventProperty(property, value)
        }
    }

    @JvmStatic
    fun eventProperty(property: String) {
        synchronized(observers) {
            for (o in observers)
                o.eventProperty(property)
        }
    }

    @JvmStatic
    fun event(eventId: Int) {
        synchronized(observers) {
            for (o in observers)
                o.event(eventId)
        }
    }

    @JvmStatic
    fun eventEndFile(reason: Int, error: Int, errorMessage: String?, playlistEntryId: Long) {
        val endFile = EndFile(reason, error, errorMessage, playlistEntryId)
        synchronized(observers) {
            for (o in observers)
                o.eventEndFile(endFile)
        }
    }

    private val log_observers = mutableListOf<LogObserver>()

    @JvmStatic
    fun addLogObserver(o: LogObserver) {
        synchronized(log_observers) {
            log_observers.add(o)
        }
    }

    @JvmStatic
    fun removeLogObserver(o: LogObserver) {
        synchronized(log_observers) {
            log_observers.remove(o)
        }
    }

    @JvmStatic
    fun logMessage(prefix: String, level: Int, text: String) {
        synchronized(log_observers) {
            for (o in log_observers)
                o.logMessage(prefix, level, text)
        }
    }

    interface EventObserver {
        fun eventProperty(property: String)
        fun eventProperty(property: String, value: Long)
        fun eventProperty(property: String, value: Boolean)
        fun eventProperty(property: String, value: String)
        fun eventProperty(property: String, value: Double)
        fun event(eventId: Int)

        /**
         * Why a file stopped playing or failed to open. Called on the event thread just before
         * `event(MPV_EVENT_END_FILE)`. Does nothing unless overridden.
         */
        fun eventEndFile(endFile: EndFile) {}
    }

    /**
     * mpv's `mpv_event_end_file`.
     *
     * @property reason one of [MpvEndFileReason]; treat unknown values as unknown
     * @property error with [MpvEndFileReason.MPV_END_FILE_REASON_ERROR], one of [MpvError]
     *   (negative) giving the approximate cause; 0 otherwise
     * @property errorMessage mpv's text for [error] (`mpv_error_string()`), e.g. "loading
     *   failed"; null when [error] is 0. The detailed cause (such as `[stream] Failed to open`)
     *   is only in the log.
     * @property playlistEntryId the playlist entry ID (`playlist/N/id`) of the file that ended
     */
    data class EndFile(
        val reason: Int,
        val error: Int,
        val errorMessage: String?,
        val playlistEntryId: Long,
    )

    interface LogObserver {
        fun logMessage(prefix: String, level: Int, text: String)
    }

    object MpvFormat {
        const val MPV_FORMAT_NONE: Int = 0
        const val MPV_FORMAT_STRING: Int = 1
        const val MPV_FORMAT_OSD_STRING: Int = 2
        const val MPV_FORMAT_FLAG: Int = 3
        const val MPV_FORMAT_INT64: Int = 4
        const val MPV_FORMAT_DOUBLE: Int = 5
        const val MPV_FORMAT_NODE: Int = 6
        const val MPV_FORMAT_NODE_ARRAY: Int = 7
        const val MPV_FORMAT_NODE_MAP: Int = 8
        const val MPV_FORMAT_BYTE_ARRAY: Int = 9
    }

    object MpvEvent {
        const val MPV_EVENT_NONE: Int = 0
        const val MPV_EVENT_SHUTDOWN: Int = 1
        const val MPV_EVENT_LOG_MESSAGE: Int = 2
        const val MPV_EVENT_GET_PROPERTY_REPLY: Int = 3
        const val MPV_EVENT_SET_PROPERTY_REPLY: Int = 4
        const val MPV_EVENT_COMMAND_REPLY: Int = 5
        const val MPV_EVENT_START_FILE: Int = 6
        const val MPV_EVENT_END_FILE: Int = 7
        const val MPV_EVENT_FILE_LOADED: Int = 8
        @Deprecated("")
        const val MPV_EVENT_IDLE: Int = 11
        @Deprecated("")
        const val MPV_EVENT_TICK: Int = 14
        const val MPV_EVENT_CLIENT_MESSAGE: Int = 16
        const val MPV_EVENT_VIDEO_RECONFIG: Int = 17
        const val MPV_EVENT_AUDIO_RECONFIG: Int = 18
        const val MPV_EVENT_SEEK: Int = 20
        const val MPV_EVENT_PLAYBACK_RESTART: Int = 21
        const val MPV_EVENT_PROPERTY_CHANGE: Int = 22
        const val MPV_EVENT_QUEUE_OVERFLOW: Int = 24
        const val MPV_EVENT_HOOK: Int = 25
    }

    object MpvEndFileReason {
        const val MPV_END_FILE_REASON_EOF: Int = 0
        const val MPV_END_FILE_REASON_STOP: Int = 2
        const val MPV_END_FILE_REASON_QUIT: Int = 3
        const val MPV_END_FILE_REASON_ERROR: Int = 4
        const val MPV_END_FILE_REASON_REDIRECT: Int = 5
    }

    object MpvError {
        const val MPV_ERROR_SUCCESS: Int = 0
        const val MPV_ERROR_EVENT_QUEUE_FULL: Int = -1
        const val MPV_ERROR_NOMEM: Int = -2
        const val MPV_ERROR_UNINITIALIZED: Int = -3
        const val MPV_ERROR_INVALID_PARAMETER: Int = -4
        const val MPV_ERROR_OPTION_NOT_FOUND: Int = -5
        const val MPV_ERROR_OPTION_FORMAT: Int = -6
        const val MPV_ERROR_OPTION_ERROR: Int = -7
        const val MPV_ERROR_PROPERTY_NOT_FOUND: Int = -8
        const val MPV_ERROR_PROPERTY_FORMAT: Int = -9
        const val MPV_ERROR_PROPERTY_UNAVAILABLE: Int = -10
        const val MPV_ERROR_PROPERTY_ERROR: Int = -11
        const val MPV_ERROR_COMMAND: Int = -12
        const val MPV_ERROR_LOADING_FAILED: Int = -13
        const val MPV_ERROR_AO_INIT_FAILED: Int = -14
        const val MPV_ERROR_VO_INIT_FAILED: Int = -15
        const val MPV_ERROR_NOTHING_TO_PLAY: Int = -16
        const val MPV_ERROR_UNKNOWN_FORMAT: Int = -17
        const val MPV_ERROR_UNSUPPORTED: Int = -18
        const val MPV_ERROR_NOT_IMPLEMENTED: Int = -19
        const val MPV_ERROR_GENERIC: Int = -20
    }

    object MpvLogLevel {
        const val MPV_LOG_LEVEL_NONE: Int = 0
        const val MPV_LOG_LEVEL_FATAL: Int = 10
        const val MPV_LOG_LEVEL_ERROR: Int = 20
        const val MPV_LOG_LEVEL_WARN: Int = 30
        const val MPV_LOG_LEVEL_INFO: Int = 40
        const val MPV_LOG_LEVEL_V: Int = 50
        const val MPV_LOG_LEVEL_DEBUG: Int = 60
        const val MPV_LOG_LEVEL_TRACE: Int = 70
    }
}
