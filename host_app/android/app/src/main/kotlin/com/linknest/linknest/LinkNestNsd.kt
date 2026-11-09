package com.linknest.linknest

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address

/** Android NSD is kept native so an old device's registration callback cannot block the UI. */
internal class LinkNestNsd(context: Context) {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val handler = Handler(Looper.getMainLooper())
    private var generation = 0
    private var registration: NsdManager.RegistrationListener? = null
    private var registrationLock: WifiManager.MulticastLock? = null
    private var pendingRetry: Runnable? = null
    private var registrationWatchdog: Runnable? = null
    private var activeSearch: Search? = null

    fun advertise(attributes: Map<String, String>, port: Int) {
        stopAdvertising()
        if (port !in 1..65535 || attributes["sid"].isNullOrBlank()) return
        val current = generation
        registrationLock = acquireLock("LinkNestHostNsd")
        register(attributes, port, current, 0)
    }

    private fun register(attributes: Map<String, String>, port: Int, current: Int, attempt: Int) {
        if (current != generation) return
        val service = NsdServiceInfo().apply {
            serviceName = "LinkNest-${attributes["sid"]!!.take(24)}"
            serviceType = "_linknest._tcp"
            setPort(port)
            attributes.forEach { (key, value) -> setAttribute(key, value) }
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                handler.post {
                    if (current != generation || registration !== this) return@post
                    registrationWatchdog?.let(handler::removeCallbacks)
                    registrationWatchdog = null
                    Log.d("LinkNest", "局域网空间广告已注册 name=${info.serviceName} port=$port")
                }
            }
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                handler.post {
                    if (current != generation || registration !== this) return@post
                    registrationWatchdog?.let(handler::removeCallbacks)
                    registrationWatchdog = null
                    registration = null
                    Log.w("LinkNest", "局域网空间广告注册失败 code=$errorCode attempt=$attempt")
                    if (attempt >= 3) return@post
                    pendingRetry = Runnable {
                        pendingRetry = null
                        register(attributes, port, current, attempt + 1)
                    }.also { handler.postDelayed(it, 1000L shl attempt) }
                }
            }
            override fun onServiceUnregistered(info: NsdServiceInfo) {
                Log.d("LinkNest", "局域网空间广告已注销")
            }
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w("LinkNest", "局域网空间广告注销失败 code=$errorCode")
            }
        }
        registration = listener
        try {
            nsd.registerService(service, NsdManager.PROTOCOL_DNS_SD, listener)
            registrationWatchdog = Runnable {
                if (current != generation || registration !== listener) return@Runnable
                Log.w("LinkNest", "局域网空间广告回调超时 attempt=$attempt")
                try { nsd.unregisterService(listener) } catch (_: Exception) { }
                listener.onRegistrationFailed(service, -2)
            }.also { handler.postDelayed(it, 5000) }
            Log.d("LinkNest", "已提交局域网空间广告注册 attempt=$attempt")
        } catch (error: Exception) {
            listener.onRegistrationFailed(service, -1)
            Log.w("LinkNest", "局域网空间广告提交失败", error)
        }
    }

    fun stopAdvertising() {
        generation++
        pendingRetry?.let(handler::removeCallbacks)
        pendingRetry = null
        registrationWatchdog?.let(handler::removeCallbacks)
        registrationWatchdog = null
        registration?.let {
            try { nsd.unregisterService(it) } catch (_: Exception) { }
        }
        registration = null
        registrationLock?.let { if (it.isHeld) it.release() }
        registrationLock = null
    }

    fun close() {
        activeSearch?.finish()
        stopAdvertising()
    }

    fun discover(timeoutMs: Int, result: MethodChannel.Result) {
        activeSearch?.finish()
        Search(timeoutMs.coerceIn(500, 5000), result).also {
            activeSearch = it
            it.start()
        }
    }

    private inner class Search(
        private val timeoutMs: Int,
        private val result: MethodChannel.Result,
    ) {
        private val found = linkedMapOf<String, NsdServiceInfo>()
        private val resolved = mutableListOf<Map<String, Any>>()
        private val lock = acquireLock("LinkNestGuestNsd")
        private var listener: NsdManager.DiscoveryListener? = null
        private var finished = false
        private var resolving = false
        private val timeout = Runnable { stopBrowsingAndResolve() }

        fun start() {
            val currentListener = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(type: String) {
                    Log.d("LinkNest", "局域网空间搜索已启动")
                }
                override fun onStartDiscoveryFailed(type: String, code: Int) {
                    Log.w("LinkNest", "局域网空间搜索启动失败 code=$code")
                    handler.post { finish() }
                }
                override fun onStopDiscoveryFailed(type: String, code: Int) {
                    Log.w("LinkNest", "局域网空间搜索停止失败 code=$code")
                }
                override fun onDiscoveryStopped(type: String) {}
                override fun onServiceFound(info: NsdServiceInfo) {
                    handler.post {
                        if (finished) return@post
                        found[info.serviceName] = info
                        Log.d("LinkNest", "发现局域网空间广告 name=${info.serviceName}")
                    }
                }
                override fun onServiceLost(info: NsdServiceInfo) {
                    handler.post { found.remove(info.serviceName) }
                }
            }
            listener = currentListener
            try {
                nsd.discoverServices("_linknest._tcp", NsdManager.PROTOCOL_DNS_SD, currentListener)
                handler.postDelayed(timeout, timeoutMs.toLong())
            } catch (error: Exception) {
                Log.w("LinkNest", "局域网空间搜索提交失败", error)
                finish()
            }
        }

        private fun stopBrowsingAndResolve() {
            if (finished || resolving) return
            resolving = true
            listener?.let { try { nsd.stopServiceDiscovery(it) } catch (_: Exception) { } }
            listener = null
            resolveNext(found.values.take(8).iterator())
        }

        private fun resolveNext(queue: Iterator<NsdServiceInfo>) {
            if (finished) return
            if (!queue.hasNext()) { finish(); return }
            val item = queue.next()
            var complete = false
            lateinit var limit: Runnable
            fun advance(info: NsdServiceInfo?) {
                if (complete || finished) return
                complete = true
                handler.removeCallbacks(limit)
                info?.let(::record)
                resolveNext(queue)
            }
            limit = Runnable { advance(null) }
            handler.postDelayed(limit, 1500)
            try {
                nsd.resolveService(item, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, code: Int) {
                        Log.w("LinkNest", "局域网空间地址解析失败 code=$code")
                        handler.post { advance(null) }
                    }
                    override fun onServiceResolved(info: NsdServiceInfo) {
                        handler.post { advance(info) }
                    }
                })
            } catch (error: Exception) {
                Log.w("LinkNest", "局域网空间地址解析提交失败", error)
                advance(null)
            }
        }

        private fun record(info: NsdServiceInfo) {
            val addresses = if (Build.VERSION.SDK_INT >= 34) info.hostAddresses else listOfNotNull(info.host)
            val ipv4 = addresses.filterIsInstance<Inet4Address>()
                .mapNotNull { it.hostAddress?.takeIf(::isSupportedLanIpv4) }
            val txt = info.attributes.mapValues { (_, bytes) -> bytes.toString(Charsets.UTF_8) }
            resolved += mapOf("port" to info.port, "addresses" to ipv4, "txt" to txt)
        }

        fun finish() {
            if (finished) return
            finished = true
            handler.removeCallbacks(timeout)
            listener?.let { try { nsd.stopServiceDiscovery(it) } catch (_: Exception) { } }
            listener = null
            if (lock?.isHeld == true) lock.release()
            if (activeSearch === this) activeSearch = null
            Log.d("LinkNest", "局域网空间搜索结束 count=${resolved.size}")
            result.success(resolved)
        }
    }

    private fun acquireLock(tag: String): WifiManager.MulticastLock? = try {
        wifi.createMulticastLock(tag).apply {
            setReferenceCounted(false)
            acquire()
        }
    } catch (error: Exception) {
        Log.w("LinkNest", "获取组播锁失败", error)
        null
    }
}
