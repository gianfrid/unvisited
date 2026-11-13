package com.example.unvisited

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Parcelable
import android.os.PowerManager
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val HOST_CHANNEL = "unvisited/host"
        private const val SHARED_CHANNEL = "unvisited/shared"
        private const val SEND_ACTION = "android.intent.action.SEND"
        private const val PICK_DIR_REQUEST = 4941

        /** Track file extensions accepted by the unified import pipeline.
         *  Matched case-insensitively, mirroring the Dart-side folder scan. */
        private val TRACK_EXTENSIONS = setOf("gpx", "fit", "kmz", "kml", "tcx")

        /** Guard against pathological (or cyclic) SAF trees while recursing. */
        private const val MAX_TREE_DEPTH = 32

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

    // Pending result of an in-flight `pickDirectory` call, delivered once the
    // system directory picker returns.
    private var pendingDirResult: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())

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

    /**
     * Lets the user pick a folder via the Storage Access Framework and returns
     * its tree URI, or null when the pick was cancelled.
     *
     * SAF needs no storage permissions, unlike raw-path directory access which
     * scoped storage has made impossible on Android 13+ (and never existed for
     * USB-OTG providers like a Garmin watch).
     */
    private fun pickSafDirectory(result: MethodChannel.Result) {
        if (pendingDirResult != null) {
            result.error("already_active", "A directory request is already pending.", null)
            return
        }
        pendingDirResult = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            startActivityForResult(intent, PICK_DIR_REQUEST)
        } catch (e: ActivityNotFoundException) {
            pendingDirResult = null
            result.error(
                "explorer_not_found",
                "Can't find a valid activity to handle the request. " +
                    "Make sure you have a file explorer installed.",
                null,
            )
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_DIR_REQUEST) return
        val result = pendingDirResult
        pendingDirResult = null
        result ?: return

        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) { // user cancelled the picker
            result.success(null)
            return
        }
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
        } catch (e: SecurityException) {
            // Persisting is only an optimization for re-scans; the grant held
            // by this process works for the scan that follows immediately.
        }
        result.success(uri.toString())
    }

    /**
     * Recursively scans a SAF tree on a worker thread, copies every supported
     * track file into a cache-staging directory (content:// URIs are not
     * directly readable from Dart) and answers with `{path, name}` maps.
     * Failed single files are skipped; one bad export must not abort the scan.
     */
    private fun listSafTrackFiles(treeUriString: String, result: MethodChannel.Result) {
        Thread {
            val files = mutableListOf<Map<String, String>>()
            var error: Exception? = null
            try {
                val treeUri = Uri.parse(treeUriString)
                scanSafTree(
                    treeUri,
                    DocumentsContract.getTreeDocumentId(treeUri),
                    0,
                    stagingDir(),
                    files,
                )
            } catch (e: Exception) {
                error = e
            }
            val payload = files
            val err = error
            mainHandler.post {
                try {
                    if (err != null) {
                        result.error("saf_error", err.message ?: "SAF scan failed", null)
                    } else {
                        result.success(payload)
                    }
                } catch (e: Exception) {
                    // The engine went away mid-scan (activity destroyed).
                }
            }
        }.start()
    }

    private fun stagingDir(): File {
        val dir = File(cacheDir, "saf_import_${System.currentTimeMillis()}")
        dir.mkdirs()
        return dir
    }

    private fun scanSafTree(
        treeUri: Uri,
        parentDocId: String,
        depth: Int,
        stagingDir: File,
        out: MutableList<Map<String, String>>,
    ) {
        if (depth > MAX_TREE_DEPTH) return
        val childrenUri =
            DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)
        val cursor = contentResolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            ),
            null,
            null,
            null,
        ) ?: return
        cursor.use { c ->
            val idIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            while (c.moveToNext()) {
                val docId = if (idIdx >= 0) c.getString(idIdx) else null
                val name = if (nameIdx >= 0) c.getString(nameIdx) else null
                val mime = if (mimeIdx >= 0) c.getString(mimeIdx) else null
                if (docId == null || name == null) continue
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    scanSafTree(treeUri, docId, depth + 1, stagingDir, out)
                } else if (name.substringAfterLast('.', "").lowercase() in TRACK_EXTENSIONS) {
                    copySafDocument(treeUri, docId, name, stagingDir, out)
                }
            }
        }
    }

    private fun copySafDocument(
        treeUri: Uri,
        docId: String,
        name: String,
        stagingDir: File,
        out: MutableList<Map<String, String>>,
    ) {
        try {
            val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
            contentResolver.openInputStream(fileUri)?.use { input ->
                val dest = uniqueDest(stagingDir, name)
                dest.outputStream().use { output -> input.copyTo(output) }
                out.add(mapOf("path" to dest.absolutePath, "name" to name))
            }
        } catch (e: Exception) {
            // Skip unreadable files; the rest of the folder still imports.
        }
    }

    /** Same basename in different subfolders would collide in staging. */
    private fun uniqueDest(dir: File, name: String): File {
        val safe = name.replace(Regex("""[\\/:*?"<>|]"""), "_")
        var candidate = File(dir, safe)
        if (!candidate.exists()) return candidate
        val dot = safe.lastIndexOf('.')
        val base = if (dot > 0) safe.substring(0, dot) else safe
        val ext = if (dot > 0) safe.substring(dot) else ""
        var i = 1
        do {
            candidate = File(dir, "$base ($i++)$ext")
        } while (candidate.exists())
        return candidate
    }

    override fun configureFlutterEngine(
        flutterEngine: io.flutter.embedding.engine.FlutterEngine
    ) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HOST_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getFilesDir" -> result.success(filesDir.absolutePath)
                    // Dart resolves a writable cache root for the map tile
                    // cache; without this method it falls back to a relative
                    // path that is unwritable on Android, which stalls every
                    // tile load.
                    "getCacheDir" -> result.success(cacheDir.absolutePath)
                    // Build time (latest commit time) baked by gradle at
                    // build time; null outside a git checkout, so the Dart
                    // side falls back to the plain "dev" tag.
                    "getBuildTime" -> {
                        val t = BuildConfig.BUILD_TIME
                        if (t.isEmpty()) result.success(null) else result.success(t)
                    }
                    "pickDirectory" -> pickSafDirectory(result)
                    "listTrackFiles" ->
                        listSafTrackFiles(call.arguments?.toString() ?: "", result)
                    // Battery-optimization state for the recording advisory
                    // in Settings: the state read and the soft tap-through
                    // to the system settings screen. Deliberately not the
                    // direct REQUEST_IGNORE_BATTERY_OPTIMIZATIONS intent —
                    // that is the aggressive flow Play flags (research
                    // report), and the advisory stays non-blocking.
                    "batteryOptimizationExcluded" -> {
                        val pm = getSystemService(POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }
                    "openBatteryOptimizationSettings" -> {
                        try {
                            startActivity(
                                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                            )
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("unavailable", "No battery settings screen", null)
                        }
                    }
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
        pendingDirResult = null
        sharedChannel = null
        super.onDestroy()
    }
}
