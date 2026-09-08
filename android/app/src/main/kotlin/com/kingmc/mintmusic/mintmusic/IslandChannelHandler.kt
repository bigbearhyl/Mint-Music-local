package com.kingmc.mintmusic.mintmusic

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.kingmc.mintmusic.mintmusic.island.DesktopLyric
import com.kingmc.mintmusic.mintmusic.island.DynamicIsland
import com.kingmc.mintmusic.mintmusic.MintNotificationManager

/**
 * Flutter 与原生灵动岛 (Dynamic Island) + 自定义通知栏 之间的桥接。
 *
 * Dart 侧通过 MethodChannel 'com.mintmusic/island' 控制悬浮窗和通知:
 * show / hide / toggle / setMeta / setCover / setLyric / setLyricWords /
 * setProgress / setBackgroundMode /
 * updateNotifMeta / updateNotifCover / updateNotifOverlayStates / cancelNotif
 *
 * 悬浮窗内控制按钮 (prev / next / toggle / fav) 通过 MethodChannel 回传 Dart,
 * 由 Dart 侧 PlaybackController 处理。
 *
 * 通知栏按钮点击通过 NotifActionReceiver → MintNotificationManager 回传。
 */
class IslandChannelHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.mintmusic/island"
        const val REQUEST_OVERLAY = 10001
    }

    private lateinit var channel: MethodChannel
    private val mainHandler = Handler(Looper.getMainLooper())

    /** 自定义通知管理器 */
    private lateinit var notifManager: MintNotificationManager

    /** 气泡/通知栏拉起播放页的请求：Dart 侧监听就绪前先缓存，就绪后由它取走 */
    private var pendingOpenPlayer = false

    fun attach(engine: FlutterEngine) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)

        // 初始化自定义通知管理器并设置回调
        notifManager = MintNotificationManager.getInstance(context)
        notifManager.actionDispatcher = { action ->
            mainHandler.post { handleNotifAction(action) }
        }

        DynamicIsland.setCommandCallback { cmd ->
            mainHandler.post {
                channel.invokeMethod("command", mapOf("cmd" to cmd))
            }
        }
    }

    /** Activity 收到 openPlayer（灵动岛点击/通知栏）时调用 */
    fun notifyOpenPlayer() {
        pendingOpenPlayer = true
        mainHandler.post {
            if (::channel.isInitialized) {
                channel.invokeMethod("openPlayer", null)
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "show" -> {
                if (!canDrawOverlays()) {
                    requestOverlayPermission()
                    result.success(false)
                } else {
                    DynamicIsland.show(context)
                    result.success(true)
                }
            }
            "hide" -> {
                DynamicIsland.hide()
                result.success(true)
            }
            "toggle" -> {
                if (!canDrawOverlays() && !DynamicIsland.isShowing()) {
                    requestOverlayPermission()
                    result.success(false)
                } else {
                    DynamicIsland.toggle(context)
                    result.success(DynamicIsland.isShowing())
                }
            }
            "setMeta" -> {
                val title = call.argument<String>("title") ?: ""
                val artist = call.argument<String>("artist") ?: ""
                val playing = call.argument<Boolean>("playing") ?: false
                val fav = call.argument<Boolean>("fav") ?: false
                DynamicIsland.setMeta(title, artist, playing)
                DynamicIsland.setFav(fav)
                result.success(true)
            }
            "setCover" -> {
                val path = call.argument<String>("path")
                val bytes = call.argument<ByteArray>("bytes")
                val bitmap = when {
                    bytes != null -> BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                    path != null -> loadBitmap(path)
                    else -> null
                }
                DynamicIsland.setCover(bitmap)
                result.success(true)
            }
            "setLyric" -> {
                val text = call.argument<String>("text") ?: ""
                val start = (call.argument<Number>("start") ?: 0).toLong()
                val end = (call.argument<Number>("end") ?: 0).toLong()
                DynamicIsland.setLyric(text, start, end)
                DesktopLyric.setLyric(text)
                result.success(true)
            }
            "setLyricWords" -> {
                val text = call.argument<String>("text") ?: ""
                val start = (call.argument<Number>("start") ?: 0).toLong()
                val end = (call.argument<Number>("end") ?: 0).toLong()
                val words = call.argument<List<List<Any>>>("words")
                DynamicIsland.setLyricWords(text, start, end, parseWords(words))
                // 桌面歌词只显示整行文字，不需要逐字时间轴；YRC 歌曲也必须推送
                DesktopLyric.setLyric(text)
                result.success(true)
            }
            "setProgress" -> {
                val pos = (call.argument<Number>("position") ?: 0).toLong()
                val dur = (call.argument<Number>("duration") ?: 0).toLong()
                DynamicIsland.setProgress(pos, dur)
                result.success(true)
            }
            "setBackgroundMode" -> {
                val bg = call.argument<Boolean>("background") ?: false
                DynamicIsland.setBackgroundMode(bg)
                result.success(true)
            }
            "setFav" -> {
                val fav = call.argument<Boolean>("fav") ?: false
                DynamicIsland.setFav(fav)
                result.success(true)
            }
            "toggleLyric" -> {
                if (!canDrawOverlays()) {
                    requestOverlayPermission()
                    result.success(false)
                } else {
                    result.success(DesktopLyric.toggle(context))
                }
            }
            "lyricShowing" -> result.success(DesktopLyric.isShowing())
            "consumeOpenPlayer" -> {
                val pending = pendingOpenPlayer
                pendingOpenPlayer = false
                result.success(pending)
            }
            // ---- 自定义通知栏方法 ----
            "updateNotifMeta" -> {
                val title = call.argument<String>("title") ?: ""
                val artist = call.argument<String>("artist") ?: ""
                val playing = call.argument<Boolean>("playing") ?: false
                val fav = call.argument<Boolean>("fav") ?: false
                notifManager.updateMeta(title, artist, playing, fav)
                result.success(true)
            }
            "updateNotifCover" -> {
                val url = call.argument<String>("url")
                val bytes = call.argument<ByteArray>("bytes")
                when {
                    bytes != null -> {
                        val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                        notifManager.setCoverBitmap(bmp)
                        notifManager.refresh()
                    }
                    url != null -> notifManager.setCoverUrl(url)
                    else -> notifManager.setCoverBitmap(null)
                }
                result.success(true)
            }
            "updateNotifOverlayStates" -> {
                val lyricShowing = call.argument<Boolean>("lyricShowing") ?: false
                val islandShowing = call.argument<Boolean>("islandShowing") ?: false
                notifManager.updateOverlayStates(lyricShowing, islandShowing)
                result.success(true)
            }
            "setDesktopLyricLocked" -> {
                val locked = call.argument<Boolean>("locked") ?: false
                DesktopLyric.setLocked(locked)
                notifManager.updateDesktopLyricLocked(locked)
                result.success(DesktopLyric.isLocked())
            }
            "desktopLyricLocked" -> result.success(DesktopLyric.isLocked())
            "updateNotifLockState" -> {
                val locked = call.argument<Boolean>("locked") ?: DesktopLyric.isLocked()
                notifManager.updateDesktopLyricLocked(locked)
                result.success(true)
            }
            "cancelNotif" -> {
                notifManager.cancel()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun canDrawOverlays(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(context)
        } else {
            true
        }
    }

    private fun requestOverlayPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:${context.packageName}")
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        }
    }

    private fun loadBitmap(path: String): Bitmap? {
        return try {
            if (path.startsWith("content://")) {
                val uri = Uri.parse(path)
                context.contentResolver.openFileDescriptor(uri, "r")?.use { fd ->
                    BitmapFactory.decodeFileDescriptor(fd.fileDescriptor)
                }
            } else if (path.startsWith("http")) {
                null
            } else {
                BitmapFactory.decodeFile(path)
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun parseWords(list: List<List<Any>>?): Array<LongArray>? {
        if (list == null) return null
        return Array(list.size) { i ->
            val item = list[i]
            longArrayOf(
                (item[0] as Number).toLong(),
                (item[1] as Number).toLong(),
                (item[2] as Number).toLong()
            )
        }
    }

    /** 处理自定义通知栏按钮点击，转发给 Flutter 侧 */
    private fun handleNotifAction(action: String) {
        when (action) {
            MintNotificationManager.ACTION_CLOSE -> {
                // 关闭：停止播放并取消通知
                notifManager.cancel()
                channel.invokeMethod("command", mapOf("cmd" to "close"))
            }
            MintNotificationManager.ACTION_FAV,
            MintNotificationManager.ACTION_PREV,
            MintNotificationManager.ACTION_NEXT,
            MintNotificationManager.ACTION_TOGGLE,
            MintNotificationManager.ACTION_LYRIC,
            MintNotificationManager.ACTION_ISLAND,
            MintNotificationManager.ACTION_LOCK -> {
                // 转发给 Flutter 统一处理（与灵动岛按钮复用 command 通道）
                val cmd = when (action) {
                    MintNotificationManager.ACTION_FAV -> "fav"
                    MintNotificationManager.ACTION_PREV -> "prev"
                    MintNotificationManager.ACTION_NEXT -> "next"
                    MintNotificationManager.ACTION_TOGGLE -> "toggle"
                    MintNotificationManager.ACTION_LYRIC -> "toggleDesktopLyric"
                    MintNotificationManager.ACTION_ISLAND -> "toggleIsland"
                    MintNotificationManager.ACTION_LOCK -> "toggleDesktopLyricLock"
                    else -> action
                }
                channel.invokeMethod("command", mapOf("cmd" to cmd))
            }
        }
    }
}
