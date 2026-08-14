package com.github.raoxwup.haka_comic

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.Executors

class FolderPickerPlugin(
    private val activity: FlutterFragmentActivity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "haka_comic/folder_picker"
        private const val REQUEST_CODE_PICK_DIRECTORY = 0xF017
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private var pendingResult: MethodChannel.Result? = null
    private var recursive = true
    private var pickMode = PickMode.SNAPSHOT

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "pickDirectorySnapshot" -> startPickDirectory(call, result, PickMode.SNAPSHOT)
                "pickWritableDirectory" -> startPickDirectory(call, result, PickMode.WRITABLE)
                "hasPersistedPermission" -> result.success(
                    hasPersistedPermission(requireTreeUri(call), requireWrite = true),
                )
                "resolveTreePath" -> result.success(resolveTreePath(requireTreeUri(call)))
                "areTreesNested" -> result.success(
                    areTreesNested(
                        Uri.parse(
                            call.argument<String>("firstTreeUri")
                                ?: throw IllegalArgumentException("firstTreeUri is required"),
                        ),
                        Uri.parse(
                            call.argument<String>("secondTreeUri")
                                ?: throw IllegalArgumentException("secondTreeUri is required"),
                        ),
                    ),
                )
                "fileExists" -> runStorageCall(result) {
                    val entry = resolveEntry(
                        requireTreeUri(call),
                        requireRelativePath(call),
                    )
                    entry != null && !entry.isDirectory && isNonEmptyDocument(entry)
                }
                "directoryExists" -> runStorageCall(result) {
                    val relativePath = requireRelativePath(call)
                    if (relativePath.isBlank()) {
                        true
                    } else {
                        resolveEntry(requireTreeUri(call), relativePath)?.isDirectory == true
                    }
                }
                "writeFile" -> runStorageCall(result) {
                    writeFile(
                        treeUri = requireTreeUri(call),
                        relativePath = requireRelativePath(call),
                        sourcePath = call.argument<String>("sourcePath")
                            ?: throw IllegalArgumentException("sourcePath is required"),
                    )
                    null
                }
                "materializeDirectory" -> runStorageCall(result) {
                    materializeDirectory(
                        treeUri = requireTreeUri(call),
                        relativePath = requireRelativePath(call),
                    )
                }
                "materializeFile" -> runStorageCall(result) {
                    materializeFile(
                        treeUri = requireTreeUri(call),
                        relativePath = requireRelativePath(call),
                    )
                }
                "deleteDirectory" -> runStorageCall(result) {
                    deleteDirectory(
                        treeUri = requireTreeUri(call),
                        relativePath = requireRelativePath(call),
                    )
                    null
                }
                "directoryStats" -> runStorageCall(result) {
                    directoryStats(
                        treeUri = requireTreeUri(call),
                        relativePath = requireRelativePath(call),
                    )
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error(
                "invalid_arguments",
                error.message ?: "Invalid folder picker arguments.",
                null,
            )
        }
    }

    private fun isNonEmptyDocument(entry: DocumentEntry): Boolean {
        if (entry.size > 0L) return true
        return try {
            activity.contentResolver.openInputStream(entry.documentUri)?.use { input ->
                input.read() >= 0
            } ?: false
        } catch (_: Exception) {
            false
        }
    }

    private fun documentSize(entry: DocumentEntry): Long {
        if (entry.size > 0L) return entry.size

        try {
            val descriptorLength = activity.contentResolver.openAssetFileDescriptor(
                entry.documentUri,
                "r",
            )?.use { descriptor -> descriptor.length }
            if (descriptorLength != null && descriptorLength >= 0L) {
                return descriptorLength
            }
        } catch (_: Exception) {
        }

        return try {
            activity.contentResolver.openInputStream(entry.documentUri)?.use { input ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                var total = 0L
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                }
                total
            } ?: 0L
        } catch (_: Exception) {
            0L
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE_PICK_DIRECTORY) {
            return false
        }

        val pending = pendingResult ?: return false
        pendingResult = null

        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            pending.success(null)
            return true
        }

        val treeUri = data.data ?: run {
            pending.success(null)
            return true
        }

        val requestedFlags = Intent.FLAG_GRANT_READ_URI_PERMISSION or
            if (pickMode == PickMode.WRITABLE) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0
        val grantedFlags = data.flags and requestedFlags
        val permissionFlags = if (grantedFlags != 0) {
            grantedFlags
        } else {
            requestedFlags
        }

        try {
            activity.contentResolver.takePersistableUriPermission(treeUri, permissionFlags)
        } catch (_: SecurityException) {
            // Some providers do not offer persistable permissions. Immediate reads still work.
        }

        try {
            val rootDocumentUri = DocumentsContract.buildDocumentUriUsingTree(
                treeUri,
                DocumentsContract.getTreeDocumentId(treeUri),
            )
            val folderName = queryDisplayName(rootDocumentUri).orEmpty().ifBlank { "folder" }
            if (pickMode == PickMode.WRITABLE) {
                if (!hasPersistedPermission(treeUri, requireWrite = true)) {
                    throw SecurityException("The selected provider did not grant persistent write access.")
                }
                pending.success(
                    mapOf(
                        "uri" to treeUri.toString(),
                        "name" to folderName,
                    ),
                )
            } else {
                val snapshot = createSnapshot(
                    treeUri = treeUri,
                    rootDocumentUri = rootDocumentUri,
                    folderName = folderName,
                    recursive = recursive,
                )
                pending.success(snapshot)
            }
        } catch (e: Exception) {
            pending.error(
                "snapshot_failed",
                e.message ?: "Failed to create folder snapshot.",
                null,
            )
        }

        return true
    }

    private fun startPickDirectory(
        call: MethodCall,
        result: MethodChannel.Result,
        mode: PickMode,
    ) {
        if (pendingResult != null) {
            result.error("busy", "Another folder picker request is already running.", null)
            return
        }

        recursive = call.argument<Boolean>("recursive") ?: true
        pickMode = mode
        pendingResult = result

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if (mode == PickMode.WRITABLE) {
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            }
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }
        activity.startActivityForResult(intent, REQUEST_CODE_PICK_DIRECTORY)
    }

    private fun createSnapshot(
        treeUri: Uri,
        rootDocumentUri: Uri,
        folderName: String,
        recursive: Boolean,
    ): Map<String, Any> {
        val snapshotsRoot = File(activity.cacheDir, "folder_picker")
        if (!snapshotsRoot.exists()) {
            snapshotsRoot.mkdirs()
        }

        val snapshotDir = File(
            snapshotsRoot,
            "${System.currentTimeMillis()}_${UUID.randomUUID()}_${sanitizeForPath(folderName)}",
        )
        if (!snapshotDir.mkdirs()) {
            throw IllegalStateException("Failed to create snapshot directory.")
        }

        val files = mutableListOf<Map<String, Any?>>()
        copyChildren(
            treeUri = treeUri,
            parentDocumentUri = rootDocumentUri,
            destinationDir = snapshotDir,
            snapshotRoot = snapshotDir,
            recursive = recursive,
            files = files,
        )

        return mapOf(
            "name" to folderName,
            "localPath" to snapshotDir.absolutePath,
            "files" to files,
        )
    }

    private fun copyChildren(
        treeUri: Uri,
        parentDocumentUri: Uri,
        destinationDir: File,
        snapshotRoot: File,
        recursive: Boolean,
        files: MutableList<Map<String, Any?>>,
    ) {
        for (entry in queryChildren(treeUri, parentDocumentUri)) {
            val destination = File(destinationDir, entry.displayName)
            if (entry.isDirectory) {
                if (!recursive) {
                    continue
                }
                if (!destination.exists()) {
                    destination.mkdirs()
                }
                copyChildren(
                    treeUri = treeUri,
                    parentDocumentUri = entry.documentUri,
                    destinationDir = destination,
                    snapshotRoot = snapshotRoot,
                    recursive = true,
                    files = files,
                )
                continue
            }

            copyUriToFile(entry.documentUri, destination)
            files.add(
                mapOf(
                    "name" to entry.displayName,
                    "relativePath" to relativePath(snapshotRoot, destination),
                    "localPath" to destination.absolutePath,
                    "size" to entry.size,
                    "mimeType" to entry.mimeType,
                ),
            )
        }
    }

    private fun queryChildren(treeUri: Uri, parentDocumentUri: Uri): List<DocumentEntry> {
        val resolver = activity.contentResolver
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            DocumentsContract.getDocumentId(parentDocumentUri),
        )
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
        )

        val result = mutableListOf<DocumentEntry>()
        resolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            val documentIdIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val displayNameIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeTypeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val sizeIndex = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)

            while (cursor.moveToNext()) {
                val documentId = cursor.getString(documentIdIndex)
                val displayName = cursor.getString(displayNameIndex) ?: continue
                val mimeType = cursor.getString(mimeTypeIndex)
                val size = if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                    cursor.getLong(sizeIndex)
                } else {
                    0L
                }
                val documentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
                result.add(
                    DocumentEntry(
                        documentUri = documentUri,
                        displayName = displayName,
                        mimeType = mimeType,
                        size = size,
                        isDirectory = mimeType == DocumentsContract.Document.MIME_TYPE_DIR,
                    ),
                )
            }
        }

        return result
    }

    private fun findChild(
        treeUri: Uri,
        parentDocumentUri: Uri,
        name: String,
    ): DocumentEntry? {
        return queryChildren(treeUri, parentDocumentUri).firstOrNull {
            it.displayName == name
        }
    }

    private fun resolveEntry(treeUri: Uri, relativePath: String): DocumentEntry? {
        val parts = pathParts(relativePath)
        if (parts.isEmpty()) return null

        var parent = rootDocumentUri(treeUri)
        var current: DocumentEntry? = null
        for ((index, part) in parts.withIndex()) {
            current = findChild(treeUri, parent, part) ?: return null
            if (index < parts.lastIndex && !current.isDirectory) return null
            parent = current.documentUri
        }
        return current
    }

    private fun ensureDirectory(
        treeUri: Uri,
        parts: List<String>,
    ): Uri {
        var parent = rootDocumentUri(treeUri)
        for (part in parts) {
            val existing = findChild(treeUri, parent, part)
            if (existing != null) {
                if (!existing.isDirectory) {
                    throw IllegalStateException("A file already exists at $part")
                }
                parent = existing.documentUri
                continue
            }

            parent = DocumentsContract.createDocument(
                activity.contentResolver,
                parent,
                DocumentsContract.Document.MIME_TYPE_DIR,
                part,
            ) ?: throw IllegalStateException("Unable to create directory $part")
        }
        return parent
    }

    private fun writeFile(treeUri: Uri, relativePath: String, sourcePath: String) {
        requirePersistedPermission(treeUri, requireWrite = true)
        val source = File(sourcePath)
        if (!source.isFile) {
            throw IllegalArgumentException("Source file does not exist: $sourcePath")
        }

        val parts = pathParts(relativePath)
        if (parts.isEmpty()) {
            throw IllegalArgumentException("relativePath is required")
        }

        val parent = ensureDirectory(treeUri, parts.dropLast(1))
        val fileName = parts.last()
        val existing = findChild(treeUri, parent, fileName)
        if (existing?.isDirectory == true) {
            throw IllegalStateException("A directory already exists at $relativePath")
        }
        val temporaryName = "$fileName.part"
        val temporaryEntry = findChild(treeUri, parent, temporaryName)
        if (temporaryEntry?.isDirectory == true) {
            throw IllegalStateException("A directory already exists at $temporaryName")
        }
        val temporaryUri = temporaryEntry?.documentUri ?: DocumentsContract.createDocument(
            activity.contentResolver,
            parent,
            mimeTypeFor(fileName),
            temporaryName,
        ) ?: throw IllegalStateException("Unable to create temporary file $relativePath")

        try {
            activity.contentResolver.openOutputStream(temporaryUri, "wt")?.use { output ->
                source.inputStream().use { input -> input.copyTo(output) }
            } ?: throw IllegalStateException("Unable to write file $relativePath")

            val written = findChild(treeUri, parent, temporaryName)
                ?: throw IllegalStateException("Temporary file is missing: $relativePath")
            if (documentSize(written) != source.length()) {
                throw IllegalStateException("Temporary file size mismatch: $relativePath")
            }

            if (existing != null) {
                val deleted = DocumentsContract.deleteDocument(
                    activity.contentResolver,
                    existing.documentUri,
                )
                if (!deleted) {
                    throw IllegalStateException("Unable to replace file $relativePath")
                }
            }
            DocumentsContract.renameDocument(
                activity.contentResolver,
                temporaryUri,
                fileName,
            ) ?: throw IllegalStateException("Unable to finalize file $relativePath")
        } catch (error: Exception) {
            try {
                DocumentsContract.deleteDocument(activity.contentResolver, temporaryUri)
            } catch (_: Exception) {
            }
            throw error
        }
    }

    private fun materializeDirectory(treeUri: Uri, relativePath: String): String {
        requirePersistedPermission(treeUri, requireWrite = false)
        val source = if (relativePath.isBlank()) {
            DocumentEntry(
                documentUri = rootDocumentUri(treeUri),
                displayName = "downloads",
                mimeType = DocumentsContract.Document.MIME_TYPE_DIR,
                size = 0L,
                isDirectory = true,
            )
        } else {
            resolveEntry(treeUri, relativePath)
                ?: throw IllegalStateException("Directory does not exist: $relativePath")
        }
        if (!source.isDirectory) {
            throw IllegalStateException("Path is not a directory: $relativePath")
        }

        val materializedRoot = File(activity.cacheDir, "download_materialized")
        materializedRoot.mkdirs()
        val destination = File(
            materializedRoot,
            "${treeUri.toString().hashCode()}_${relativePath.hashCode()}",
        )
        if (destination.exists()) destination.deleteRecursively()
        if (!destination.mkdirs()) {
            throw IllegalStateException("Unable to create materialized directory")
        }

        copyDocumentDirectory(treeUri, source.documentUri, destination)
        return destination.absolutePath
    }

    private fun materializeFile(treeUri: Uri, relativePath: String): String {
        requirePersistedPermission(treeUri, requireWrite = false)
        val source = resolveEntry(treeUri, relativePath)
            ?: throw IllegalStateException("File does not exist: $relativePath")
        if (source.isDirectory) {
            throw IllegalStateException("Path is not a file: $relativePath")
        }

        val materializedRoot = File(activity.cacheDir, "download_materialized_files")
        materializedRoot.mkdirs()
        val extension = source.displayName.substringAfterLast('.', "")
        val suffix = if (extension.isBlank()) "" else ".$extension"
        val destination = File(
            materializedRoot,
            "${treeUri.toString().hashCode()}_${relativePath.hashCode()}$suffix",
        )
        copyUriToFile(source.documentUri, destination)
        return destination.absolutePath
    }

    private fun copyDocumentDirectory(treeUri: Uri, source: Uri, destination: File) {
        for (entry in queryChildren(treeUri, source)) {
            val target = File(destination, sanitizeForPath(entry.displayName))
            if (entry.isDirectory) {
                target.mkdirs()
                copyDocumentDirectory(treeUri, entry.documentUri, target)
            } else {
                copyUriToFile(entry.documentUri, target)
            }
        }
    }

    private fun deleteDirectory(treeUri: Uri, relativePath: String) {
        requirePersistedPermission(treeUri, requireWrite = true)
        if (relativePath.isBlank()) {
            throw IllegalArgumentException("Deleting the selected root is not allowed")
        }
        val entry = resolveEntry(treeUri, relativePath) ?: return
        if (!DocumentsContract.deleteDocument(activity.contentResolver, entry.documentUri)) {
            throw IllegalStateException("Unable to delete directory $relativePath")
        }
    }

    private fun directoryStats(treeUri: Uri, relativePath: String): Map<String, Long> {
        requirePersistedPermission(treeUri, requireWrite = false)
        val root = if (relativePath.isBlank()) {
            rootDocumentUri(treeUri)
        } else {
            val entry = resolveEntry(treeUri, relativePath)
                ?: return mapOf("fileCount" to 0L, "totalBytes" to 0L)
            if (!entry.isDirectory) {
                return mapOf("fileCount" to 1L, "totalBytes" to documentSize(entry))
            }
            entry.documentUri
        }
        val stats = collectStats(treeUri, root)
        return mapOf("fileCount" to stats.first, "totalBytes" to stats.second)
    }

    private fun collectStats(treeUri: Uri, parent: Uri): Pair<Long, Long> {
        var count = 0L
        var bytes = 0L
        for (entry in queryChildren(treeUri, parent)) {
            if (entry.isDirectory) {
                val child = collectStats(treeUri, entry.documentUri)
                count += child.first
                bytes += child.second
            } else if (!entry.displayName.endsWith(".part")) {
                count += 1
                bytes += documentSize(entry)
            }
        }
        return count to bytes
    }

    private fun rootDocumentUri(treeUri: Uri): Uri {
        return DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )
    }

    private fun resolveTreePath(treeUri: Uri): String? {
        if (treeUri.authority != "com.android.externalstorage.documents") return null
        val documentId = DocumentsContract.getTreeDocumentId(treeUri)
        val parts = documentId.split(':', limit = 2)
        val volumeId = parts.firstOrNull() ?: return null
        val relativePath = parts.getOrNull(1).orEmpty()
        val volumeRoot = if (volumeId.equals("primary", ignoreCase = true)) {
            Environment.getExternalStorageDirectory()
        } else {
            File("/storage/$volumeId")
        }
        return if (relativePath.isBlank()) {
            volumeRoot.canonicalPath
        } else {
            File(volumeRoot, relativePath).canonicalPath
        }
    }

    private fun areTreesNested(firstTreeUri: Uri, secondTreeUri: Uri): Boolean {
        if (firstTreeUri == secondTreeUri) return true
        if (firstTreeUri.authority != secondTreeUri.authority) return false
        return try {
            val firstRoot = rootDocumentUri(firstTreeUri)
            val secondRoot = rootDocumentUri(secondTreeUri)
            DocumentsContract.isChildDocument(activity.contentResolver, firstRoot, secondRoot) ||
                DocumentsContract.isChildDocument(activity.contentResolver, secondRoot, firstRoot)
        } catch (_: Exception) {
            false
        }
    }

    private fun pathParts(relativePath: String): List<String> {
        return relativePath
            .replace('\\', '/')
            .split('/')
            .filter { it.isNotBlank() }
            .onEach {
                if (it == "." || it == "..") {
                    throw IllegalArgumentException("Invalid path component")
                }
            }
    }

    private fun mimeTypeFor(fileName: String): String {
        return when (fileName.substringAfterLast('.', "").lowercase()) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "webp" -> "image/webp"
            "gif" -> "image/gif"
            "pdf" -> "application/pdf"
            "zip" -> "application/zip"
            else -> "application/octet-stream"
        }
    }

    private fun requireTreeUri(call: MethodCall): Uri {
        val value = call.argument<String>("treeUri")
            ?: throw IllegalArgumentException("treeUri is required")
        return Uri.parse(value)
    }

    private fun requireRelativePath(call: MethodCall): String {
        return call.argument<String>("relativePath") ?: ""
    }

    private fun hasPersistedPermission(treeUri: Uri, requireWrite: Boolean): Boolean {
        return activity.contentResolver.persistedUriPermissions.any {
            it.uri == treeUri && it.isReadPermission && (!requireWrite || it.isWritePermission)
        }
    }

    private fun requirePersistedPermission(treeUri: Uri, requireWrite: Boolean) {
        if (!hasPersistedPermission(treeUri, requireWrite)) {
            throw SecurityException("The selected folder permission is no longer available.")
        }
    }

    private fun runStorageCall(
        result: MethodChannel.Result,
        block: () -> Any?,
    ) {
        ioExecutor.execute {
            try {
                val value = block()
                activity.runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                activity.runOnUiThread {
                    result.error(
                        "storage_failed",
                        e.message ?: "Storage operation failed.",
                        null,
                    )
                }
            }
        }
    }

    private fun queryDisplayName(documentUri: Uri): String? {
        val projection = arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        activity.contentResolver.query(documentUri, projection, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                if (index >= 0) {
                    return cursor.getString(index)
                }
            }
        }
        return null
    }

    private fun copyUriToFile(sourceUri: Uri, destination: File) {
        destination.parentFile?.mkdirs()
        activity.contentResolver.openInputStream(sourceUri)?.use { input ->
            FileOutputStream(destination).use { output ->
                input.copyTo(output)
            }
        } ?: throw IllegalStateException("Unable to open input stream for $sourceUri")
    }

    private fun relativePath(root: File, target: File): String {
        val rootPath = root.absolutePath
        val targetPath = target.absolutePath
        if (!targetPath.startsWith(rootPath)) {
            return target.name
        }
        return targetPath
            .removePrefix(rootPath)
            .trimStart(File.separatorChar)
            .replace(File.separatorChar, '/')
    }

    private fun sanitizeForPath(name: String): String {
        val sanitized = name.replace(Regex("""[\\/\u0000]"""), "_")
        return if (sanitized == "." || sanitized == "..") "_$sanitized" else sanitized
    }

    private data class DocumentEntry(
        val documentUri: Uri,
        val displayName: String,
        val mimeType: String?,
        val size: Long,
        val isDirectory: Boolean,
    )

    private enum class PickMode {
        SNAPSHOT,
        WRITABLE,
    }
}
