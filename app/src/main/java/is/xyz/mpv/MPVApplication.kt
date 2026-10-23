package `is`.xyz.mpv

import android.app.Application

class MPVApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // MPVLib leaves loading to the app. libplayer.so's other dependencies (FFmpeg, libc++)
        // are found next to it in the APK.
        System.loadLibrary("mpv")
        System.loadLibrary("player")
    }
}
