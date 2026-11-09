package com.linknest.linknest

import android.annotation.SuppressLint
import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodChannel

/**
 * 进程级 LocalOnlyHotspot 持有者。
 *
 * reservation 不能跟随 Activity 重建而丢失；共享期间由前台 Service 保持进程，
 * 本对象负责保留 reservation，并把系统停止事件即时送给 Flutter。
 */
object LocalHotspotManager {
    private const val TAG = "LinkNest"

    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var startResult: MethodChannel.Result? = null
    private var generation = 0
    private var stopRequested = false
    private var currentSsid = ""
    private var currentPassword = ""

    @Volatile
    private var stateListener: ((Map<String, Any?>) -> Unit)? = null

    fun setStateListener(listener: ((Map<String, Any?>) -> Unit)?) {
        stateListener = listener
    }

    @Synchronized
    fun info(): Map<String, Any?> = mapOf(
        "supported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O),
        "ssid" to currentSsid,
        "password" to currentPassword,
        "running" to (reservation != null && currentSsid.isNotEmpty()),
    )

    @RequiresApi(Build.VERSION_CODES.O)
    @SuppressLint("MissingPermission")
    @Synchronized
    fun start(context: Context, result: MethodChannel.Result) {
        if (reservation != null && currentSsid.isNotEmpty()) {
            result.success(info())
            return
        }
        if (startResult != null) {
            result.error("HOTSPOT_STARTING", "热点正在启动", null)
            return
        }

        generation += 1
        val requestGeneration = generation
        stopRequested = false
        startResult = result
        Log.d(TAG, "请求启动 LocalOnlyHotspot generation=$requestGeneration")
        val wifi = context.applicationContext
            .getSystemService(Context.WIFI_SERVICE) as WifiManager
        try {
            wifi.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(value: WifiManager.LocalOnlyHotspotReservation) {
                        handleStarted(requestGeneration, value)
                    }

                    override fun onStopped() {
                        handleStopped(requestGeneration)
                    }

                    override fun onFailed(reason: Int) {
                        handleFailed(requestGeneration, reason)
                    }
                },
                null,
            )
        } catch (error: SecurityException) {
            clearIfCurrent(requestGeneration)
            resultOnceError(
                "HOTSPOT_PERMISSION_DENIED",
                "系统拒绝开启热点：${error.message}",
            )
        } catch (error: Exception) {
            clearIfCurrent(requestGeneration)
            Log.d(TAG, "配置 LocalOnlyHotspot 失败 reason=${error.javaClass.simpleName}")
            resultOnceError("HOTSPOT_UNAVAILABLE", "系统无法开启临时热点")
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    @Synchronized
    private fun handleStarted(
        requestGeneration: Int,
        value: WifiManager.LocalOnlyHotspotReservation,
    ) {
        if (requestGeneration == generation && reservation != null && startResult == null) {
            Log.d(TAG, "忽略重复的热点启动回调 generation=$requestGeneration")
            return
        }
        if (requestGeneration != generation || stopRequested || startResult == null) {
            value.close()
            Log.d(TAG, "忽略迟到的热点启动回调 generation=$requestGeneration")
            return
        }
        reservation = value
        val configuration = value.wifiConfiguration
        currentSsid = configuration?.SSID?.trim('"') ?: ""
        currentPassword = configuration?.preSharedKey ?: ""
        Log.d(
            TAG,
            "临时热点已启动 generation=$requestGeneration " +
                "ssidPresent=${currentSsid.isNotEmpty()} " +
                "passwordPresent=${currentPassword.isNotEmpty()}",
        )
        resultOnceSuccess(info())
        notifyState("started", unexpected = false)
    }

    @Synchronized
    private fun handleStopped(requestGeneration: Int) {
        if (requestGeneration != generation) {
            Log.d(TAG, "忽略过期的热点停止回调 generation=$requestGeneration")
            return
        }
        val unexpected = !stopRequested
        reservation = null
        clearCredentials()
        if (startResult != null) {
            resultOnceError("HOTSPOT_STOPPED", "热点在启动完成前被系统停止")
        }
        Log.d(
            TAG,
            "收到热点停止回调 generation=$requestGeneration unexpected=$unexpected",
        )
        notifyState("stopped", unexpected = unexpected)
    }

    @Synchronized
    private fun handleFailed(requestGeneration: Int, reason: Int) {
        if (requestGeneration != generation) {
            Log.d(
                TAG,
                "忽略过期的热点启动失败回调 generation=$requestGeneration reason=$reason",
            )
            return
        }
        if (reservation != null && startResult == null) {
            Log.d(
                TAG,
                "忽略重复的热点启动失败回调 generation=$requestGeneration reason=$reason",
            )
            return
        }
        val unexpected = !stopRequested
        reservation = null
        clearCredentials()
        Log.d(
            TAG,
            "收到热点启动失败回调 generation=$requestGeneration " +
                "reason=$reason unexpected=$unexpected",
        )
        resultOnceError("HOTSPOT_UNAVAILABLE", "系统无法开启热点，reason=$reason")
        notifyState("failed", unexpected = unexpected, reason = reason)
    }

    @Synchronized
    fun close() {
        Log.d(TAG, "请求关闭临时热点 generation=$generation")
        stopRequested = true
        resultOnceError("HOTSPOT_CANCELLED", "热点启动已取消")
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                reservation?.close()
            }
        } catch (error: Exception) {
            Log.d(TAG, "关闭临时热点失败 reason=${error.javaClass.simpleName}")
        }
        reservation = null
        clearCredentials()
    }

    @Synchronized
    private fun clearIfCurrent(requestGeneration: Int) {
        if (requestGeneration != generation) return
        reservation = null
        clearCredentials()
    }

    private fun clearCredentials() {
        currentSsid = ""
        currentPassword = ""
    }

    private fun resultOnceSuccess(value: Any?) {
        val pending = startResult ?: return
        startResult = null
        pending.success(value)
    }

    private fun resultOnceError(code: String, message: String) {
        val pending = startResult ?: return
        startResult = null
        pending.error(code, message, null)
    }

    private fun notifyState(state: String, unexpected: Boolean, reason: Int? = null) {
        val value = mutableMapOf<String, Any?>(
            "state" to state,
            "unexpected" to unexpected,
        )
        if (reason != null) value["reason"] = reason
        stateListener?.invoke(value)
    }
}
