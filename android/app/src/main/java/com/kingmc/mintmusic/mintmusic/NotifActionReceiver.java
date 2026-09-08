package com.kingmc.mintmusic.mintmusic;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * 自定义通知栏按钮点击广播接收器。
 *
 * 在 AndroidManifest 中静态注册，接收 MintNotificationManager
 * 各控制按钮的 PendingIntent 广播，转发给回调链：
 * BroadcastReceiver → MintNotificationManager.dispatchAction()
 * → actionDispatcher → IslandChannelHandler → MethodChannel → Flutter
 */
public class NotifActionReceiver extends BroadcastReceiver {

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null) return;
        String action = intent.getAction();
        if (action == null) return;

        // 转发给 MintNotificationManager (Kotlin, @JvmStatic)
        MintNotificationManager.dispatchAction(action);
    }
}
