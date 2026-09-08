package com.kingmc.mintmusic.mintmusic

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.widget.RemoteViews
import android.util.Log
import java.net.HttpURLConnection
import java.net.URL

/**
 * Mint Music 自定义媒体通知管理器（iMusic 同款 RemoteViews 布局）。
 *
 * 替代 audio_service 插件的默认 MediaStyle 通知，提供完整控制按钮：
 * 收藏 / 上一首 / 播放暂停 / 下一首 / 桌面歌词 / 灵动岛 / 关闭
 *
 * 通过 IslandChannelHandler (MethodChannel) 接收 Flutter 侧状态更新。
 */
class MintNotificationManager private constructor(private val context: Context) {

    companion object {
        private const val TAG = "MintNotif"
        private const val NOTIF_ID = 0xC01 // 与 audio_service 的 ID 区开

        const val CHANNEL_ID = "com.mintmusic.channel.custom_notif"
        private const val CHANNEL_NAME = "Mint Music"

        // Intent actions
        const val ACTION_PREV = "com.mintmusic.PREV"
        const val ACTION_NEXT = "com.mintmusic.NEXT"
        const val ACTION_TOGGLE = "com.mintmusic.TOGGLE"
        const val ACTION_FAV = "com.mintmusic.FAV"
        const val ACTION_LYRIC = "com.mintmusic.LYRIC"
        const val ACTION_ISLAND = "com.mintmusic.ISLAND"
        const val ACTION_LOCK = "com.mintmusic.LOCK"
        const val ACTION_CLOSE = "com.mintmusic.CLOSE"

        @Volatile private var instance: MintNotificationManager? = null

        fun getInstance(ctx: Context): MintNotificationManager {
            return instance ?: synchronized(this) {
                instance ?: MintNotificationManager(ctx.applicationContext).also { instance = it }
            }
        }

        /** 供 BroadcastReceiver 调用（@JvmStatic 使 Java 可直接调用） */
        @JvmStatic
        fun dispatchAction(action: String) {
            instance?.actionDispatcher?.invoke(action)
        }
    }

    private val nm: NotificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val mainHandler = Handler(Looper.getMainLooper())

    // 可变状态（任意线程读写，build/refresh 统一在主线程）
    @Volatile var title: String = ""
        set(v) { field = v ?: ""; refresh() }
    @Volatile var artist: String = ""
        set(v) { field = v ?: ""; refresh() }
    @Volatile var isPlaying: Boolean = false
        set(v) { field = v; refresh() }
    @Volatile var isFav: Boolean = false
        set(v) { field = v; refresh() }
    @Volatile var isLyricShowing: Boolean = false
    @Volatile var isIslandShowing: Boolean = false
    @Volatile var isDesktopLyricLocked: Boolean = false
    @Volatile private var coverBitmap: Bitmap? = null
    @Volatile private var coverUrl: String = ""

    /** 通知栏按钮动作回调（由 IslandChannelHandler 设置） */
    var actionDispatcher: ((String) -> Unit)? = null

    init { createChannel() }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW).apply {
                description = "Mint Music 播放控制"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            nm.createNotificationChannel(channel)
        }
    }

    // ======================== 状态更新 API ========================

    fun setCoverBitmap(bmp: Bitmap?) {
        coverBitmap = bmp
        coverUrl = ""
        refresh()
    }

    /** 异步下载封面并刷新通知 */
    fun setCoverUrl(url: String?) {
        if (url.isNullOrEmpty() || url == coverUrl) return
        coverUrl = url
        Thread({
            try {
                val conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = 8000
                conn.readTimeout = 8000
                conn.setRequestProperty("User-Agent",
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
                val bmp = BitmapFactory.decodeStream(conn.inputStream)
                conn.disconnect()
                if (bmp != null && url == coverUrl) {
                    coverBitmap = bmp
                    refresh()
                }
            } catch (e: Exception) {
                Log.w(TAG, "下载封面失败: ${e.message}")
            }
        }, "notif-cover-dl").start()
    }

    /** 批量更新元数据并立即刷新 */
    fun updateMeta(title: String?, artist: String?, playing: Boolean, fav: Boolean) {
        this.title = title ?: ""
        this.artist = artist ?: ""
        isPlaying = playing
        isFav = fav
        refresh()
    }

    /** 更新悬浮窗状态按钮颜色并刷新 */
    fun updateOverlayStates(lyricShowing: Boolean, islandShowing: Boolean) {
        isLyricShowing = lyricShowing
        isIslandShowing = islandShowing
        refresh()
    }

    /** 更新桌面歌词锁定状态（解锁=绿色对勾亮，关锁=常规黑），用于通知栏高亮 */
    fun updateDesktopLyricLocked(locked: Boolean) {
        isDesktopLyricLocked = locked
        refresh()
    }

    // ======================== 通知构建 ========================

    fun refresh() {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            buildAndPost()
        } else {
            mainHandler.post(::buildAndPost)
        }
    }

    private fun buildAndPost() {
        try {
            val n = buildNotification()
            nm.notify(NOTIF_ID, n)
        } catch (e: Exception) {
            Log.e(TAG, "刷新通知失败", e)
        }
    }

    private fun buildNotification(): Notification {
        val rv = RemoteViews(context.packageName, R.layout.notification_music)

        // 文字
        rv.setTextViewText(R.id.n_title, if (title.isEmpty()) "Mint Music" else title)
        rv.setTextViewText(R.id.n_artist, if (artist.isEmpty()) "点开选歌" else artist)

        // 播放/暂停图标
        rv.setImageViewResource(R.id.n_toggle, if (isPlaying) R.drawable.n_pause else R.drawable.n_play)

        // 收藏图标
        rv.setImageViewResource(R.id.n_fav, if (isFav) R.drawable.n_heart_filled else R.drawable.n_heart)

        // 封面
        if (coverBitmap != null) {
            rv.setImageViewBitmap(R.id.n_cover, coverBitmap)
        } else {
            rv.setImageViewResource(R.id.n_cover, R.mipmap.logo)
        }

        // 状态按钮着色：开启=绿色(#31C27C)，未开启=常规深色
        val green = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            context.getColor(R.color.notif_state_on)
        } else {
            0x31C27C
        }
        val primaryColor = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            context.getColor(R.color.notif_primary)
        } else {
            0x1A1A1A
        }

        // 桌面歌词 / 灵动岛按钮文字颜色
        rv.setTextColor(R.id.n_lyric, if (isLyricShowing) green else primaryColor)
        rv.setTextColor(R.id.n_island, if (isIslandShowing) green else primaryColor)

        // 桌面歌词锁定按钮：图标随状态切换（开锁/关锁），锁定时绿色高亮
        rv.setImageViewResource(R.id.n_lock, if (isDesktopLyricLocked) R.drawable.n_lock_closed else R.drawable.n_lock_open)

        // 图标按钮着色：与"词/岛"同套逻辑 —— 常态黑色，词/岛开启态绿色，收藏开启态红色。
        // RemoteViews 对 ImageView 用 setColorFilter 强制着色，不依赖 drawable 本色
        // （drawable 来自 iMusic 深色通知栏，存在白色版本，浅色背景上会看不清）。
        rv.setInt(R.id.n_fav, "setColorFilter",
            if (isFav) context.getColor(R.color.notif_fav_on) else primaryColor)
        rv.setInt(R.id.n_lock, "setColorFilter", if (isDesktopLyricLocked) green else primaryColor)
        rv.setInt(R.id.n_prev, "setColorFilter", primaryColor)
        rv.setInt(R.id.n_toggle, "setColorFilter", primaryColor)
        rv.setInt(R.id.n_next, "setColorFilter", primaryColor)
        rv.setInt(R.id.n_close, "setColorFilter", primaryColor)

        // 点击事件
        rv.setOnClickPendingIntent(R.id.n_fav, pi(ACTION_FAV))
        rv.setOnClickPendingIntent(R.id.n_lock, pi(ACTION_LOCK))
        rv.setOnClickPendingIntent(R.id.n_prev, pi(ACTION_PREV))
        rv.setOnClickPendingIntent(R.id.n_toggle, pi(ACTION_TOGGLE))
        rv.setOnClickPendingIntent(R.id.n_next, pi(ACTION_NEXT))
        rv.setOnClickPendingIntent(R.id.n_lyric, pi(ACTION_LYRIC))
        rv.setOnClickPendingIntent(R.id.n_island, pi(ACTION_ISLAND))
        rv.setOnClickPendingIntent(R.id.n_close, pi(ACTION_CLOSE))

        // 点击封面 → 打开应用
        val openIntent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK)
        rv.setOnClickPendingIntent(R.id.n_cover,
            PendingIntent.getActivity(context, NOTIF_ID + 1, openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))

        // 构建 Notification
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            Notification.Builder(context)
        }

        return builder.setContent(rv)
            .setSmallIcon(R.drawable.ic_notif_app)
            .setColor(0x31C27C)
            .setContentTitle(if (title.isEmpty()) "Mint Music" else title)
            .setContentText(artist)
            .setOngoing(isPlaying)
            .setOnlyAlertOnce(true)
            .setCustomContentView(rv)
            .setCustomBigContentView(rv)
            .build()
    }

    private fun pi(action: String): PendingIntent {
        val intent = Intent(action)
            .setPackage(context.packageName)
            .putExtra("action", action)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getBroadcast(context, action.hashCode(), intent, flags)
    }

    /** 关闭自定义通知（停止播放时调用） */
    fun cancel() {
        nm.cancel(NOTIF_ID)
    }
}
