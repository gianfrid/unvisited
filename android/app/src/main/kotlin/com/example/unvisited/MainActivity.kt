package com.example.unvisited

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Parcelable
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val HOST_CHANNEL = "unvisited/host"
        private const val SHARED_CHANNEL = "unvisited/shared"
        private const val SEND_ACTION = "android.intent.action.SEND"

        /** Share-intent mimetypes accepted by the unified import pipeline. */
        private val SHARED_MIMES = setOf(
            "application/gpx+xml",
            "application/vnd.google-earth.kmz",
            "application/vnd.google-earth.kml+xml",
            "application/vnd.garmin.fit",
            "application/fit",
            "application/octet-stream", // .fit / .gpx exports without a typed mime
        )
    }

    private var sharedChannel: MethodChannel? = null
    private var pendingSharedArgs: Map<String, Any>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleSharedIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleSharedIntent(intent)
    }

    private fun handleSharedIntent(intent: Intent?) {
        if (intent == null || intent.action != SEND_ACTION) return
        @Suppress("DEPRECATION")
        val shared: Uri =
            (intent.getParcelableExtra<Parcelable>(Intent.EXTRA_STREAM) as? Uri)
                ?: (intent.data ?: return)
        val mime = intent.type?.substringBefore(';')?.trim()?.lowercase()
        if (mime != null && mime !in SHARED_MIMES) return

        // Copy the SAF stream into the cache dir so Dart can read the bytes;
        // content:// URIs are not directly readable from Dart.
        val name = queryDisplayName(shared)
            ?: "shared_${System.currentTimeMillis()}.gpx"
        val temp = File(cacheDir, "shared_$name")
        try {
            contentResolver.openInputStream(shared)?.use { input ->
                temp.outputStream().use { output -> input.copyTo(output) }
            } ?: return
        } catch (e: Exception) {
            return
        }

        val args: Map<String, Any> =
            mapOf("path" to temp.absolutePath, "name" to name)
        val channel = sharedChannel
        if (channel != null) {
            channel.invokeMethod("sharedTrack", args)
        } else {
            pendingSharedArgs = args
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null, null, null
            )?.use { cursor ->
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && cursor.moveToFirst()) cursor.getString(idx) else null
            }
        } catch (e: Exception) {
            null
        }
    }

    override fun configureFlutterEngine(
        flutterEngine: io.flutter.embedding.engine.FlutterEngine
    ) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HOST_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getFilesDir" -> result.success(filesDir.absolutePath)
                    else -> result.notImplemented()
                }
            }

        val shared = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, SHARED_CHANNEL
        )
        sharedChannel = shared
        shared.setMethodCallHandler { call, result ->
            when (call.method) {
                // Dart listener is up: flush anything shared while cold starting.
                "ready" -> {
                    pendingSharedArgs?.let { shared.invokeMethod("sharedTrack", it) }
                    pendingSharedArgs = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        sharedChannel = null
        super.onDestroy()
    }
}
