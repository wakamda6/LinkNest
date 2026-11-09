package com.linknest.linknest

import android.annotation.SuppressLint
import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.net.Inet4Address

/** 进程级持有 Guest 的局域网请求，不能随扫码页或相机暂停而释放。所有状态在主线程修改。 */
@SuppressLint("MissingPermission")
@Suppress("DEPRECATION")
object GuestWifiManager {
    private val handler = Handler(Looper.getMainLooper())
    private class Request(val id: Long, var reply: ((String) -> Unit)?) {
        var callback: ConnectivityManager.NetworkCallback? = null
        var network: Network? = null
        var addedNetworkId: Int? = null
        var targetNetworkId: Int? = null
        var timeout: Runnable? = null
    }
    private var current: Request? = null
    private var appContext: Context? = null
    var stateListener: ((Map<String, Any>) -> Unit)? = null
    val network: Network? get() = current?.network

    fun connect(context: Context, id: Long, ssid: String, password: String,
                security: String, hidden: Boolean, reply: (String) -> Unit) {
        release()
        appContext = context.applicationContext
        val request = Request(id, reply)
        current = request
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
        Log.d("LinkNest", "开始请求访客 Wi-Fi 连接 requestId=$id sdk=${Build.VERSION.SDK_INT}")
        request.timeout = Runnable {
            if (current === request) finishFailure(request, "timeout")
        }.also { handler.postDelayed(it, 40_000) }
        try {
            if (!wifi.isWifiEnabled) {
                finishFailure(request, "wifiOff")
                return
            }
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                    handler.post { acceptNetwork(request, network, properties) }
                }
                override fun onUnavailable() {
                    handler.post { finishFailure(request, "unavailable") }
                }
                override fun onLost(network: Network) {
                    handler.post {
                        if (current !== request || request.network != network) return@post
                        Log.d("LinkNest", "访客 Wi-Fi 网络已丢失 requestId=$id")
                        finishFailure(request, "unavailable")
                        stateListener?.invoke(mapOf("requestId" to id, "state" to "lost"))
                    }
                }
            }
            request.callback = callback
            val builder = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val specifier = WifiNetworkSpecifier.Builder().setSsid(ssid).setIsHiddenSsid(hidden)
                if (security == "wpa2") specifier.setWpa2Passphrase(password)
                connectivity.requestNetwork(builder.setNetworkSpecifier(specifier.build()).build(), callback)
            } else {
                // 仅 Android 8/9 使用旧接口，复用已有配置而不覆盖其密码。
                val quotedSsid = quote(ssid)
                val existing = wifi.configuredNetworks?.firstOrNull {
                    it.SSID == quotedSsid && it.allowedKeyManagement.get(
                        if (security == "open") WifiConfiguration.KeyMgmt.NONE else WifiConfiguration.KeyMgmt.WPA_PSK
                    )
                }
                val networkId = existing?.networkId ?: wifi.addNetwork(WifiConfiguration().apply {
                    SSID = quotedSsid
                    hiddenSSID = hidden
                    if (security == "open") allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE)
                    else {
                        allowedKeyManagement.set(WifiConfiguration.KeyMgmt.WPA_PSK)
                        preSharedKey = quote(password)
                    }
                }).also { if (it >= 0) request.addedNetworkId = it }
                if (networkId < 0) {
                    finishFailure(request, "failed")
                    return
                }
                request.targetNetworkId = networkId
                connectivity.registerNetworkCallback(builder.build(), callback)
                if (!wifi.enableNetwork(networkId, true)) {
                    finishFailure(request, "failed")
                    return
                }
                // 已经连接目标网络时，注册回调仍会提供当前 LinkProperties。
            }
        } catch (error: Exception) {
            Log.d("LinkNest", "请求访客 Wi-Fi 失败 reason=${error.javaClass.simpleName}")
            finishFailure(request, if (error is SecurityException) "permissionDenied" else "failed")
        }
    }

    private fun acceptNetwork(request: Request, network: Network, properties: LinkProperties) {
        if (current !== request) return
        try {
            bindReadyNetwork(request, network, properties)
        } catch (error: Exception) {
            Log.d("LinkNest", "确认访客 Wi-Fi 网络失败 reason=${error.javaClass.simpleName}")
            finishFailure(request, if (error is SecurityException) "permissionDenied" else "failed")
        }
    }

    private fun bindReadyNetwork(request: Request, network: Network, properties: LinkProperties) {
        val context = appContext ?: return
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        if (request.targetNetworkId != null) {
            val wifi = context.getSystemService(WifiManager::class.java)
            val info = wifi.connectionInfo
            if (info.networkId != request.targetNetworkId) return
            // 旧网络的迟到 LinkProperties 不能被误认为新热点已就绪。
            if (properties.linkAddresses.none { link ->
                    val bytes = link.address.address
                    bytes.size == 4 && bytes.indices.all { index ->
                        (bytes[index].toInt() and 255) == (info.ipAddress ushr (index * 8) and 255)
                    }
                }) return
        }
        if (properties.linkAddresses.none {
                it.address is Inet4Address &&
                    it.address.hostAddress?.let(::isSupportedLanIpv4) == true
            }) return
        if (request.network == network && request.reply == null) return
        if (!connectivity.bindProcessToNetwork(network)) {
            finishFailure(request, "failed")
            return
        }
        request.network = network
        request.timeout?.let(handler::removeCallbacks)
        request.timeout = null
        val reply = request.reply
        request.reply = null
        Log.d("LinkNest", "访客 Wi-Fi 已就绪并绑定 App 网络 requestId=${request.id}")
        reply?.invoke("connected")
    }

    private fun finishFailure(request: Request, status: String) {
        if (current !== request) return
        release(request.id, status)
    }

    fun release(id: Long? = null, status: String = "cancelled") {
        val request = current ?: return
        if (id != null && request.id != id) return
        current = null // 先失效请求，防止 unregister 引起迟到回调。
        request.timeout?.let(handler::removeCallbacks)
        val context = appContext
        if (context != null) {
            val connectivity = context.getSystemService(ConnectivityManager::class.java)
            try {
                if (request.network != null && connectivity.boundNetworkForProcess == request.network) {
                    connectivity.bindProcessToNetwork(null)
                }
            } catch (error: Exception) {
                Log.d("LinkNest", "解除访客 Wi-Fi 绑定失败 reason=${error.javaClass.simpleName}")
            }
            try { request.callback?.let(connectivity::unregisterNetworkCallback) }
            catch (error: Exception) {
                Log.d("LinkNest", "注销访客 Wi-Fi 回调失败 reason=${error.javaClass.simpleName}")
            }
            try { request.addedNetworkId?.let { context.getSystemService(WifiManager::class.java).removeNetwork(it) } }
            catch (error: Exception) {
                Log.d("LinkNest", "清理 App 新建 Wi-Fi 配置失败 reason=${error.javaClass.simpleName}")
            }
        }
        val reply = request.reply
        request.reply = null
        Log.d("LinkNest", "访客 Wi-Fi 请求已释放 requestId=${request.id} status=$status")
        reply?.invoke(status)
    }

    private fun quote(value: String) = "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
}
