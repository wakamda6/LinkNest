package com.linknest.linknest

import android.Manifest
import android.annotation.SuppressLint
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.location.Geocoder
import android.location.LocationManager
import android.media.MediaMetadataRetriever
import android.media.MediaScannerConnection
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.BatteryManager
import android.os.Environment
import android.os.PowerManager
import android.os.StatFs
import android.os.SystemClock
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import androidx.annotation.RequiresApi
import androidx.exifinterface.media.ExifInterface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.util.Locale
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val channel = "linknest/native"
    private val linkNestNsd by lazy { LinkNestNsd(this) }

    private var addressesBeforeHotspot: Set<String> = emptySet()
    private data class PendingHotspotStart(
        val result: MethodChannel.Result,
    )

    private class OneShotResult(
        private val delegate: MethodChannel.Result,
    ) : MethodChannel.Result {
        private var submitted = false

        @Synchronized
        private fun submit(action: () -> Unit) {
            if (submitted) {
                Log.d("LinkNest", "忽略重复的平台通道回调")
                return
            }
            submitted = true
            action()
        }

        override fun success(result: Any?) = submit { delegate.success(result) }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) =
            submit { delegate.error(errorCode, errorMessage, errorDetails) }

        override fun notImplemented() = submit { delegate.notImplemented() }
    }

    private var pendingHotspotStart: PendingHotspotStart? = null
    private data class PendingGuestWifi(
        val id: Long, val ssid: String, val password: String,
        val security: String, val hidden: Boolean, val result: MethodChannel.Result,
        var cancelled: Boolean = false,
    )
    private var pendingGuestWifi: PendingGuestWifi? = null
    private var pendingPickResult: MethodChannel.Result? = null
    private var pendingSaveOperation: PendingSaveOperation? = null
    private var pendingHostServiceStart: PendingHostServiceStart? = null
    private var pendingGuestServiceStart: PendingGuestServiceStart? = null
    private val thumbnailExecutor = Executors.newFixedThreadPool(2)

    private data class PendingHostServiceStart(
        val spaceName: String,
        val onlineCount: Int,
        val result: MethodChannel.Result,
    )

    private data class PendingGuestServiceStart(
        val direction: String,
        val fileName: String,
        val totalBytes: Long,
        val result: MethodChannel.Result,
    )

    private data class SaveFile(
        val path: String,
        val name: String,
        val mimeType: String,
    )

    private data class PendingSaveOperation(
        val destination: String,
        val files: List<SaveFile>,
        val kind: String,
        val result: MethodChannel.Result,
    )

    companion object {
        private const val REQUEST_HOTSPOT_PERMISSION = 1001
        private const val REQUEST_SAVE_PERMISSION = 1002
        private const val REQUEST_PICK = 1003
        private const val REQUEST_NOTIFICATION_PERMISSION = 1004
        private const val REQUEST_MEDIA_LOCATION_PERMISSION = 1005
        private const val REQUEST_GUEST_WIFI_PERMISSION = 1006
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
        GuestWifiManager.stateListener = { state -> methodChannel.invokeMethod("guestWifiChanged", state) }
        LocalHotspotManager.setStateListener { state ->
            runOnUiThread {
                methodChannel.invokeMethod("hotspotStateChanged", state)
            }
        }
        methodChannel
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "joinGuestWifi" -> joinGuestWifi(PendingGuestWifi(
                        call.argument<Number>("requestId")?.toLong() ?: -1,
                        call.argument<String>("ssid") ?: "",
                        call.argument<String>("password") ?: "",
                        call.argument<String>("security") ?: "",
                        call.argument<Boolean>("hidden") == true,
                        OneShotResult(result),
                    ))
                    "releaseGuestWifi" -> {
                        val id = call.argument<Number>("requestId")?.toLong()
                        pendingGuestWifi?.takeIf { it.id == id }?.let {
                            it.cancelled = true
                            it.result.success(mapOf("status" to "cancelled"))
                        }
                        if (id != null) GuestWifiManager.release(id)
                        result.success(null)
                    }
                    "openWifiSettings" -> {
                        try {
                            startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                            result.success(true)
                        } catch (_: Exception) { result.success(false) }
                    }
                    "getLocalIp" -> result.success(getLocalIp())
                    "getLocalAddresses" -> result.success(
                        getLocalAddresses(call.argument<Boolean>("diagnostic") == true)
                    )
                    "getCurrentWifiSsid" -> result.success(getCurrentWifiSsid())
                    "discoverSpaces" -> linkNestNsd.discover(
                        call.argument<Int>("timeoutMs") ?: 3000,
                        OneShotResult(result),
                    )
                    "startSpaceAdvertisement" -> {
                        val attrs = listOf("pv", "sid", "sname", "sess", "token", "addr")
                            .associateWith { call.argument<String>(it) ?: "" }
                        linkNestNsd.advertise(attrs, call.argument<Int>("port") ?: 8080)
                        result.success(null)
                    }
                    "stopSpaceAdvertisement" -> {
                        linkNestNsd.stopAdvertising()
                        result.success(null)
                    }
                    "getWifiGatewayCandidates" -> result.success(getWifiGatewayCandidates())
                    "getHotspotInfo" -> result.success(getHotspotInfo())
                    "startHotspot" -> startHotspot(OneShotResult(result))
                    "stopHotspot" -> {
                        stopHotspot()
                        result.success(null)
                    }
                    "setKeepAwake" -> {
                        setKeepAwake(call.argument<Boolean>("enabled") == true)
                        result.success(null)
                    }
                    "startHostForegroundService" -> {
                        startHostForegroundService(
                            call.argument<String>("spaceName") ?: "",
                            call.argument<Int>("onlineCount") ?: 0,
                            result,
                        )
                    }
                    "updateHostForegroundService" -> {
                        HostForegroundService.update(
                            applicationContext,
                            call.argument<String>("spaceName") ?: "",
                            call.argument<Int>("onlineCount") ?: 0,
                        )
                        result.success(null)
                    }
                    "stopHostForegroundService" -> {
                        HostForegroundService.stop(applicationContext)
                        result.success(null)
                    }
                    "startGuestTransferService" -> {
                        startGuestTransferForegroundService(
                            call.argument<String>("direction") ?: "upload",
                            call.argument<String>("fileName") ?: "媒体文件",
                            call.argument<Number>("totalBytes")?.toLong() ?: 0L,
                            result,
                        )
                    }
                    "updateGuestTransferService" -> {
                        GuestTransferForegroundService.update(
                            applicationContext,
                            call.argument<String>("direction") ?: "upload",
                            call.argument<String>("fileName") ?: "媒体文件",
                            call.argument<Number>("completedBytes")?.toLong() ?: 0L,
                            call.argument<Number>("totalBytes")?.toLong() ?: 0L,
                        )
                        result.success(null)
                    }
                    "stopGuestTransferService" -> {
                        GuestTransferForegroundService.stop(applicationContext)
                        result.success(null)
                    }
                    "getPowerState" -> result.success(getPowerState())
                    "getFreeDiskBytes" -> {
                        val bytes = StatFs(filesDir.absolutePath).availableBytes
                        Log.d("LinkNest", "可用存储空间已读取 bytes=$bytes")
                        result.success(bytes)
                    }
                    "getAppVersion" -> {
                        @Suppress("DEPRECATION")
                        val version = packageManager.getPackageInfo(packageName, 0).versionName
                        result.success(version ?: "unknown")
                    }
                    "makeThumbnail" -> {
                        val path = call.argument<String>("path")
                        val kind = call.argument<String>("kind") ?: ""
                        val target = call.argument<Int>("target") ?: 512
                        thumbnailExecutor.execute {
                            val bytes = makeThumbnail(path, kind, target)
                            runOnUiThread { result.success(bytes) }
                        }
                    }
                    "readPhotoCoordinates" -> {
                        val path = call.argument<String>("path")
                        thumbnailExecutor.execute {
                            val coordinates = readPhotoCoordinates(path)
                            runOnUiThread { result.success(coordinates) }
                        }
                    }
                    "reverseGeocode" -> reverseGeocode(
                        call.argument<Number>("latitude")?.toDouble(),
                        call.argument<Number>("longitude")?.toDouble(),
                        result,
                    )
                    "pickFromAlbum" -> {
                        pendingPickResult = result
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                            checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) !=
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(
                                arrayOf(Manifest.permission.ACCESS_MEDIA_LOCATION),
                                REQUEST_MEDIA_LOCATION_PERMISSION,
                            )
                        } else {
                            openAlbumPicker()
                        }
                    }
                    "saveToAlbum" -> {
                        val path = call.argument<String>("path")
                        val name = call.argument<String>("name") ?: ""
                        val kind = call.argument<String>("kind") ?: ""
                        val mimeType = call.argument<String>("mimeType")
                            ?: "application/octet-stream"
                        val file = SaveFile(path ?: "", name, mimeType)
                        saveWithPermission("album", listOf(file), kind, result)
                    }
                    "saveLivePhoto" -> {
                        val files = listOf(
                            SaveFile(
                                call.argument<String>("photoPath") ?: "",
                                call.argument<String>("photoName") ?: "photo.heic",
                                "image/heic",
                            ),
                            SaveFile(
                                call.argument<String>("pairedVideoPath") ?: "",
                                call.argument<String>("pairedVideoName") ?: "video.mov",
                                "video/quicktime",
                            ),
                        )
                        saveWithPermission("files", files, "", result)
                    }
                    "saveToFiles" -> {
                        val values = call.argument<List<Map<String, Any?>>>("files") ?: emptyList()
                        val files = values.mapNotNull { value ->
                            val path = value["path"]?.toString() ?: return@mapNotNull null
                            SaveFile(
                                path,
                                value["name"]?.toString() ?: File(path).name,
                                value["mimeType"]?.toString() ?: "application/octet-stream",
                            )
                        }
                        saveWithPermission("files", files, "", result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun getLocalIp(): String {
        return getLocalAddresses().firstOrNull()?.get("address")?.toString() ?: ""
    }

    private fun getLocalAddresses(diagnostic: Boolean = false): List<Map<String, Any>> {
        return try {
            val candidates = mutableListOf<Map<String, Any>>()
            val connectedWifiAddresses = getConnectedWifiAddresses()
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces.hasMoreElements()) {
                val networkInterface = interfaces.nextElement()
                val isUp = networkInterface.isUp
                val isLoopback = networkInterface.isLoopback
                if (diagnostic) {
                    Log.d(
                        "LinkNest",
                        "Host interface diagnostic interface=${networkInterface.name} " +
                            "up=$isUp loopback=$isLoopback",
                    )
                }
                if (!isUp || isLoopback) continue
                val name = networkInterface.name.lowercase()
                if (name.startsWith("tun") || name.startsWith("p2p")) {
                    if (diagnostic) {
                        Log.d(
                            "LinkNest",
                            "Host interface diagnostic interface=${networkInterface.name} " +
                                "excludedReason=virtualInterface",
                        )
                    }
                    continue
                }
                val addresses = networkInterface.inetAddresses
                while (addresses.hasMoreElements()) {
                    val address = addresses.nextElement()
                    if (address !is Inet4Address || address.isLoopbackAddress) continue
                    val value = address.hostAddress ?: continue
                    val isSiteLocal = address.isSiteLocalAddress
                    val isSupported = isSiteLocal && isSupportedLanIpv4(value)
                    val isHotspotInterface = name.startsWith("ap") ||
                        name.contains("softap") || name.contains("hotspot") || name.contains("swlan")
                    val isWifiInterface = name.contains("wlan") || name.contains("wifi") ||
                        isHotspotInterface
                    val isConnectedWifiAddress = value in connectedWifiAddresses
                    val priority = when {
                        isConnectedWifiAddress -> 40
                        isWifiInterface && value !in addressesBeforeHotspot -> 100
                        isHotspotInterface -> 80
                        isWifiInterface -> 40
                        else -> 20
                    }
                    if (diagnostic) {
                        Log.d(
                            "LinkNest",
                            "Host address diagnostic interface=${networkInterface.name} " +
                                "address=$value siteLocal=$isSiteLocal " +
                                "supported=$isSupported " +
                                "connectedWifi=$isConnectedWifiAddress " +
                                "presentBeforeHotspot=${value in addressesBeforeHotspot} " +
                                "priority=${if (isSupported) priority else "rejected"}",
                        )
                    }
                    if (!isSupported) continue
                    candidates.add(
                        mapOf(
                            "address" to value,
                            "interface" to networkInterface.name,
                            "priority" to priority,
                            "networkType" to if (isConnectedWifiAddress) "wifi" else "other",
                        )
                    )
                }
            }
            candidates.sortedByDescending { it["priority"] as Int }.also {
                if (diagnostic) {
                    Log.d("LinkNest", "Host address diagnostic acceptedCandidates=$it")
                }
            }
        } catch (e: Exception) {
            Log.d("LinkNest", "获取本机网络地址失败", e)
            emptyList()
        }
    }

    private fun getConnectedWifiAddresses(): Set<String> {
        return try {
            val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val networks = buildList {
                GuestWifiManager.network?.let(::add)
                connectivity.activeNetwork?.let(::add)
                connectivity.allNetworks.forEach { network ->
                    if (!contains(network)) add(network)
                }
            }
            networks.asSequence()
                .filter { network ->
                    connectivity.getNetworkCapabilities(network)
                        ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                }
                .mapNotNull(connectivity::getLinkProperties)
                .flatMap { properties -> properties.linkAddresses.asSequence() }
                .mapNotNull { linkAddress ->
                    (linkAddress.address as? Inet4Address)?.hostAddress
                }
                .toSet()
        } catch (error: Exception) {
            Log.d(
                "LinkNest",
                "获取已连接 Wi-Fi 本机地址失败 reason=${error.javaClass.simpleName}",
            )
            emptySet()
        }
    }

    /**
     * 返回当前 Wi-Fi 的 IPv4 网关候选。Local-only Wi-Fi 在部分系统上不作为
     * activeNetwork，因此同时检查全部 Wi-Fi Network，并用子网首地址兜底。
     */
    private fun getWifiGatewayCandidates(): List<String> {
        val values = linkedSetOf<String>()
        try {
            val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val networks = buildList {
                GuestWifiManager.network?.let(::add)
                connectivity.activeNetwork?.let(::add)
                connectivity.allNetworks.forEach { network ->
                    if (!contains(network)) add(network)
                }
            }
            for (network in networks) {
                val capabilities = connectivity.getNetworkCapabilities(network) ?: continue
                if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
                val properties = connectivity.getLinkProperties(network) ?: continue
                properties.routes.forEach { route ->
                    val gateway = route.gateway
                    if (route.isDefaultRoute && gateway is Inet4Address) {
                        gateway.hostAddress
                            ?.takeIf(::isSupportedLanIpv4)
                            ?.let(values::add)
                    }
                }
                properties.linkAddresses.forEach { linkAddress ->
                    val address = linkAddress.address
                    if (address is Inet4Address) {
                        subnetFirstHost(address, linkAddress.prefixLength)
                            ?.takeIf(::isSupportedLanIpv4)
                            ?.let(values::add)
                    }
                }
            }
        } catch (error: Exception) {
            Log.d(
                "LinkNest",
                "获取 Wi-Fi 网关候选地址失败 reason=${error.javaClass.simpleName}",
            )
        }
        Log.d("LinkNest", "已获取 Wi-Fi 网关候选地址 count=${values.size}")
        return values.toList()
    }

    private fun subnetFirstHost(address: Inet4Address, prefixLength: Int): String? {
        if (prefixLength !in 8..30) return null
        val bytes = address.address
        var raw = 0L
        for (byte in bytes) raw = (raw shl 8) or (byte.toInt() and 0xff).toLong()
        val mask = (0xffffffffL shl (32 - prefixLength)) and 0xffffffffL
        val firstHost = ((raw and mask) + 1L) and 0xffffffffL
        val output = ByteArray(4) { index ->
            ((firstHost shr ((3 - index) * 8)) and 0xff).toByte()
        }
        return InetAddress.getByAddress(output).hostAddress
    }

    private fun getHotspotInfo(): Map<String, Any?> {
        return LocalHotspotManager.info()
    }

    private fun startHotspot(result: MethodChannel.Result) {
        Log.d("LinkNest", "收到启动 Android 临时热点请求 sdk=${Build.VERSION.SDK_INT}")
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(
                mapOf("supported" to false, "message" to "需要 Android 8.0 (API 26)+")
            )
            return
        }
        if (LocalHotspotManager.info()["running"] == true) {
            result.success(getHotspotInfo())
            return
        }
        addressesBeforeHotspot = getLocalAddresses()
            .mapNotNull { it["address"]?.toString() }
            .toSet()
        val permissions = requiredHotspotPermissions()
        if (permissions.any { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }) {
            pendingHotspotStart = PendingHotspotStart(result)
            requestPermissions(permissions, REQUEST_HOTSPOT_PERMISSION)
            return
        }
        doStartLocalOnlyHotspot(result)
    }

    /// 各 Android 版本开热点所需的运行时权限：
    /// - API 33+：NEARBY_WIFI_DEVICES
    /// - API 26~32：ACCESS_FINE_LOCATION
    private fun requiredHotspotPermissions(): Array<String> =
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ->
                arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES)
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
                arrayOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION,
                )
            else -> arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    @RequiresApi(Build.VERSION_CODES.O)
    @SuppressLint("MissingPermission")
    private fun doStartLocalOnlyHotspot(result: MethodChannel.Result) {
        val permissions = requiredHotspotPermissions()
        if (permissions.any { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }) {
            result.error("HOTSPOT_PERMISSION_DENIED", "缺少开启热点所需权限", null)
            return
        }
        try {
            LocalHotspotManager.start(applicationContext, result)
        } catch (e: SecurityException) {
            result.error("HOTSPOT_PERMISSION_DENIED", "系统拒绝开启热点：${e.message}", null)
        } catch (e: Exception) {
            Log.d(
                "LinkNest",
                "启动 LocalOnlyHotspot 失败 reason=${e.javaClass.simpleName}",
            )
            result.error("HOTSPOT_UNAVAILABLE", "系统无法开启临时热点", null)
        }
    }

    private fun stopHotspot() {
        pendingHotspotStart?.result?.error(
            "HOTSPOT_CANCELLED",
            "热点启动已取消",
            null,
        )
        pendingHotspotStart = null
        LocalHotspotManager.close()
    }

    private fun setKeepAwake(enabled: Boolean) {
        runOnUiThread {
            if (enabled) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }

    private fun startHostForegroundService(
        spaceName: String,
        onlineCount: Int,
        result: MethodChannel.Result,
    ) {
        if (pendingHostServiceStart != null || pendingGuestServiceStart != null) {
            result.error(
                "FOREGROUND_SERVICE_PENDING",
                "前台服务正在等待通知权限结果",
                null,
            )
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            pendingHostServiceStart = PendingHostServiceStart(spaceName, onlineCount, result)
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_NOTIFICATION_PERMISSION,
            )
            return
        }
        finishHostForegroundServiceStart(spaceName, onlineCount, result)
    }

    private fun startGuestTransferForegroundService(
        direction: String,
        fileName: String,
        totalBytes: Long,
        result: MethodChannel.Result,
    ) {
        if (pendingHostServiceStart != null || pendingGuestServiceStart != null) {
            result.error(
                "FOREGROUND_SERVICE_PENDING",
                "前台服务正在等待通知权限结果",
                null,
            )
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            pendingGuestServiceStart = PendingGuestServiceStart(
                direction,
                fileName,
                totalBytes,
                result,
            )
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_NOTIFICATION_PERMISSION,
            )
            return
        }
        finishGuestTransferForegroundServiceStart(
            direction,
            fileName,
            totalBytes,
            result,
        )
    }

    private fun finishGuestTransferForegroundServiceStart(
        direction: String,
        fileName: String,
        totalBytes: Long,
        result: MethodChannel.Result,
    ) {
        try {
            GuestTransferForegroundService.start(
                applicationContext,
                direction,
                fileName,
                totalBytes,
            )
            result.success(
                mapOf(
                    "started" to true,
                    "notificationPermissionGranted" to notificationPermissionGranted(),
                )
            )
        } catch (error: Exception) {
            Log.e("LinkNest", "启动访客传输前台服务失败", error)
            result.error(
                "FOREGROUND_SERVICE_FAILED",
                "无法启动传输前台服务：${error.message}",
                null,
            )
        }
    }

    private fun finishHostForegroundServiceStart(
        spaceName: String,
        onlineCount: Int,
        result: MethodChannel.Result,
    ) {
        try {
            HostForegroundService.start(applicationContext, spaceName, onlineCount)
            result.success(
                mapOf(
                    "started" to true,
                    "notificationPermissionGranted" to notificationPermissionGranted(),
                )
            )
        } catch (error: Exception) {
            Log.e("LinkNest", "启动发起者共享前台服务失败", error)
            result.error(
                "FOREGROUND_SERVICE_FAILED",
                "无法启动共享前台服务：${error.message}",
                null,
            )
        }
    }

    private fun notificationPermissionGranted(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED

    private fun getPowerState(): Map<String, Any?> {
        val batteryManager = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val capacity = batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        Log.d(
            "LinkNest",
            "设备电源状态已读取 capacity=$capacity charging=$charging lowPower=${powerManager.isPowerSaveMode}",
        )
        return mapOf(
            "level" to if (capacity in 0..100) capacity / 100.0 else null,
            "charging" to charging,
            "lowPowerMode" to powerManager.isPowerSaveMode,
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_PICK) {
            val result = pendingPickResult
            pendingPickResult = null
            if (result == null) return
            if (resultCode != RESULT_OK || data == null) {
                Log.d("LinkNest", "用户取消相册媒体选择")
                result.success(emptyList<String>())
                return
            }
            try {
                val uris = mutableListOf<Uri>()
                val clipData = data.clipData
                if (clipData != null) {
                    for (i in 0 until clipData.itemCount) {
                        uris.add(clipData.getItemAt(i).uri)
                    }
                } else {
                    data.data?.let { uris.add(it) }
                }
                val items = uris.mapNotNull { uri ->
                    val name = queryDisplayName(uri) ?: "media_${System.currentTimeMillis()}"
                    val dest = copyUriToCache(uri, name)
                    if (dest != null) mapOf("path" to dest, "name" to name) else null
                }
                Log.d("LinkNest", "相册媒体选择处理完成 selected=${uris.size} imported=${items.size}")
                result.success(items)
            } catch (e: Exception) {
                Log.d("LinkNest", "处理相册媒体选择失败 reason=${e.javaClass.simpleName}")
                result.error("PICK_FAIL", e.message, null)
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_GUEST_WIFI_PERMISSION) {
            val pending = pendingGuestWifi
            pendingGuestWifi = null
            if (pending == null || pending.cancelled) return
            val granted = guestWifiPermissions().all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
            Log.d("LinkNest", "访客 Wi-Fi 权限结果 granted=$granted")
            if (granted) connectGuestWifi(pending)
            else pending.result.success(mapOf("status" to "permissionDenied"))
        } else if (requestCode == REQUEST_HOTSPOT_PERMISSION) {
            val pending = pendingHotspotStart
            pendingHotspotStart = null
            if (pending == null) return
            if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED } &&
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
            ) {
                doStartLocalOnlyHotspot(pending.result)
            } else {
                pending.result.error("HOTSPOT_PERMISSION_DENIED", "需要系统授权才能开启热点", null)
            }
        } else if (requestCode == REQUEST_SAVE_PERMISSION) {
            val pending = pendingSaveOperation
            pendingSaveOperation = null
            if (pending == null) return
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                pending.result.success(runLegacySave(pending))
            } else {
                pending.result.success(
                    saveResult("permissionDenied", "需要存储权限才能保存文件")
                )
            }
        } else if (requestCode == REQUEST_NOTIFICATION_PERMISSION) {
            val pending = pendingHostServiceStart
            pendingHostServiceStart = null
            if (pending != null) {
                finishHostForegroundServiceStart(
                    pending.spaceName,
                    pending.onlineCount,
                    pending.result,
                )
                return
            }
            val guestPending = pendingGuestServiceStart
            pendingGuestServiceStart = null
            if (guestPending != null) {
                finishGuestTransferForegroundServiceStart(
                    guestPending.direction,
                    guestPending.fileName,
                    guestPending.totalBytes,
                    guestPending.result,
                )
            }
        } else if (requestCode == REQUEST_MEDIA_LOCATION_PERMISSION) {
            // 拒绝权限仍可选择媒体，只是系统可能移除照片位置元数据。
            Log.d(
                "LinkNest",
                "照片位置读取权限结果 granted=${grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED}",
            )
            if (pendingPickResult != null) openAlbumPicker()
        }
    }

    private fun openAlbumPicker() {
        Log.d("LinkNest", "正在打开相册媒体选择器")
        val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addCategory(Intent.CATEGORY_OPENABLE)
        }
        startActivityForResult(intent, REQUEST_PICK)
    }

    private fun readPhotoCoordinates(path: String?): Map<String, Double>? {
        if (path.isNullOrEmpty()) return null
        return try {
            val coordinates = ExifInterface(path).latLong ?: return null
            Log.d("LinkNest", "已读取照片 GPS 信息")
            mapOf("latitude" to coordinates[0], "longitude" to coordinates[1])
        } catch (error: Exception) {
            Log.d("LinkNest", "读取照片 GPS 信息失败 reason=${error.javaClass.simpleName}")
            null
        }
    }

    private fun reverseGeocode(
        latitude: Double?,
        longitude: Double?,
        result: MethodChannel.Result,
    ) {
        if (latitude == null || longitude == null ||
            latitude !in -90.0..90.0 || longitude !in -180.0..180.0
        ) {
            result.success(null)
            return
        }
        val geocoder = Geocoder(this, Locale.getDefault())
        if (!Geocoder.isPresent()) {
            Log.d("LinkNest", "系统反向地理编码服务不可用")
            result.success(null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            geocoder.getFromLocation(
                latitude,
                longitude,
                1,
                object : Geocoder.GeocodeListener {
                    override fun onGeocode(addresses: MutableList<android.location.Address>) {
                        runOnUiThread { result.success(formatPlace(addresses.firstOrNull())) }
                    }

                    override fun onError(errorMessage: String?) {
                        Log.d("LinkNest", "照片地点反向解析失败")
                        runOnUiThread { result.success(null) }
                    }
                },
            )
            return
        }
        thumbnailExecutor.execute {
            @Suppress("DEPRECATION")
            val address = try {
                geocoder.getFromLocation(latitude, longitude, 1)?.firstOrNull()
            } catch (error: Exception) {
                Log.d("LinkNest", "照片地点反向解析失败 reason=${error.javaClass.simpleName}")
                null
            }
            runOnUiThread { result.success(formatPlace(address)) }
        }
    }

    private fun formatPlace(address: android.location.Address?): String? {
        if (address == null) return null
        val parts = listOf(address.adminArea, address.locality, address.subLocality)
            .mapNotNull { it?.trim()?.takeIf(String::isNotEmpty) }
            .distinct()
        return (if (parts.isEmpty()) address.countryName?.trim() else parts.joinToString(" · "))
            ?.takeIf(String::isNotEmpty)
    }

    private fun makeThumbnail(path: String?, kind: String, target: Int): ByteArray? {
        if (path == null) return null
        val f = File(path)
        if (!f.exists()) {
            Log.d("LinkNest", "生成缩略图失败：源文件不存在")
            return null
        }
        val startedAt = SystemClock.elapsedRealtime()
        return try {
            val bitmap = if (kind == "video") {
                val retriever = MediaMetadataRetriever()
                try {
                    retriever.setDataSource(path)
                    val durationMs = retriever
                        .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                        ?.toLongOrNull() ?: 0L
                    val timeUs = thumbnailTimeUs(durationMs)
                    Log.d(
                        "LinkNest",
                        "开始提取视频缩略图帧 durationMs=$durationMs timeUs=$timeUs target=$target"
                    )
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                        val scaledFrame = try {
                            scaledVideoFrame(retriever, timeUs, target)
                        } catch (e: Exception) {
                            Log.d("LinkNest", "按目标尺寸取视频帧失败，改用普通取帧", e)
                            null
                        }
                        scaledFrame ?: retriever.getFrameAtTime(
                                timeUs,
                                MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                            )
                    } else {
                        retriever.getFrameAtTime(
                            timeUs,
                            MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                        )
                    }
                } finally {
                    retriever.release()
                }
            } else {
                decodeSampledBitmap(path, target)
            }
            if (bitmap == null) {
                Log.d("LinkNest", "媒体缩略图解码失败 kind=$kind")
                return null
            }
            val scaled = scaleBitmap(bitmap, target)
            try {
                val out = ByteArrayOutputStream()
                if (!scaled.compress(Bitmap.CompressFormat.JPEG, 80, out)) {
                    return null
                }
                out.toByteArray()
            } finally {
                if (scaled !== bitmap) scaled.recycle()
                bitmap.recycle()
            }
        } catch (e: Exception) {
            Log.d("LinkNest", "生成媒体缩略图异常 kind=$kind reason=${e.javaClass.simpleName}")
            null
        } finally {
            Log.d(
                "LinkNest",
                "媒体缩略图生成结束 kind=$kind target=$target elapsedMs=${SystemClock.elapsedRealtime() - startedAt}"
            )
        }
    }

    private fun thumbnailTimeUs(durationMs: Long): Long {
        if (durationMs <= 0L) return 1_000_000L
        val seconds = if (durationMs < 2_000L) {
            durationMs / 2_000.0
        } else {
            (durationMs / 1_000.0 * 0.1).coerceIn(1.0, 5.0)
        }
        return (seconds * 1_000_000L).toLong()
    }

    @RequiresApi(Build.VERSION_CODES.O_MR1)
    private fun scaledVideoFrame(
        retriever: MediaMetadataRetriever,
        timeUs: Long,
        target: Int
    ): Bitmap? {
        val width = retriever
            .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
            ?.toIntOrNull() ?: return null
        val height = retriever
            .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
            ?.toIntOrNull() ?: return null
        if (width <= 0 || height <= 0) return null
        val rotation = retriever
            .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
            ?.toIntOrNull() ?: 0
        val displayWidth = if (rotation == 90 || rotation == 270) height else width
        val displayHeight = if (rotation == 90 || rotation == 270) width else height
        val scale = minOf(1.0, target.toDouble() / maxOf(displayWidth, displayHeight))
        val outputWidth = maxOf(1, (displayWidth * scale).toInt())
        val outputHeight = maxOf(1, (displayHeight * scale).toInt())
        return retriever.getScaledFrameAtTime(
            timeUs,
            MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            outputWidth,
            outputHeight
        )
    }

    override fun onDestroy() {
        if (!isChangingConfigurations) linkNestNsd.close()
        pendingGuestWifi?.result?.success(mapOf("status" to "cancelled"))
        pendingGuestWifi = null
        GuestWifiManager.stateListener = null
        if (!isChangingConfigurations) GuestWifiManager.release()
        thumbnailExecutor.shutdownNow()
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun getCurrentWifiSsid(): String {
        return try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifi.connectionInfo?.ssid?.takeIf { it != WifiManager.UNKNOWN_SSID }
                ?.removeSurrounding("\"") ?: ""
        } catch (error: Exception) {
            Log.d("LinkNest", "读取当前 Wi-Fi 名称失败 reason=${error.javaClass.simpleName}")
            ""
        }
    }

    private fun guestWifiPermissions(): Array<String> = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES)
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        else -> arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    private fun joinGuestWifi(pending: PendingGuestWifi) {
        if (pendingGuestWifi != null) {
            pending.result.success(mapOf("status" to "busy"))
            return
        }
        if (pending.id < 0 || pending.ssid.toByteArray(Charsets.UTF_8).size !in 1..32 ||
            pending.ssid.contains('\u0000') || pending.security !in setOf("open", "wpa2") ||
            (pending.security == "wpa2" && (pending.password.length !in 8..63 || pending.password.any { it.code !in 32..126 }))) {
            pending.result.success(mapOf("status" to "unsupported"))
            return
        }
        val permissions = guestWifiPermissions()
        if (permissions.any { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }) {
            pendingGuestWifi = pending
            try { requestPermissions(permissions, REQUEST_GUEST_WIFI_PERMISSION) }
            catch (_: Exception) {
                pendingGuestWifi = null
                pending.result.success(mapOf("status" to "permissionDenied"))
            }
        } else connectGuestWifi(pending)
    }

    private fun connectGuestWifi(pending: PendingGuestWifi) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            val location = getSystemService(Context.LOCATION_SERVICE) as LocationManager
            val enabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) location.isLocationEnabled
                else location.isProviderEnabled(LocationManager.GPS_PROVIDER) || location.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
            if (!enabled) {
                pending.result.success(mapOf("status" to "locationOff"))
                return
            }
        }
        GuestWifiManager.connect(applicationContext, pending.id, pending.ssid, pending.password,
            pending.security, pending.hidden) { status -> pending.result.success(mapOf("status" to status)) }
    }

    private fun decodeSampledBitmap(path: String, target: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        var sample = 1
        val maxDim = maxOf(bounds.outWidth, bounds.outHeight)
        while (maxDim / (sample * 2) >= target) {
            sample *= 2
        }
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = BitmapFactory.decodeFile(path, opts) ?: return null
        return applyExifOrientation(path, decoded)
    }

    private fun applyExifOrientation(path: String, decoded: Bitmap): Bitmap {
        return try {
            val exif = ExifInterface(path)
            val rotation = exif.rotationDegrees
            val flipped = exif.isFlipped
            if (rotation == 0 && !flipped) return decoded

            val matrix = Matrix().apply {
                if (flipped) postScale(-1f, 1f)
                if (rotation != 0) postRotate(rotation.toFloat())
            }
            val oriented = Bitmap.createBitmap(
                decoded,
                0,
                0,
                decoded.width,
                decoded.height,
                matrix,
                true
            )
            if (oriented !== decoded) decoded.recycle()
            Log.d(
                "LinkNest",
                "图片缩略图已应用 EXIF 方向 rotation=$rotation flipped=$flipped"
            )
            oriented
        } catch (e: Exception) {
            Log.d("LinkNest", "读取图片 EXIF 方向失败 reason=${e.javaClass.simpleName}")
            decoded
        }
    }

    @SuppressLint("UseKtx")
    private fun scaleBitmap(src: Bitmap, target: Int): Bitmap {
        val maxDim = maxOf(src.width, src.height)
        if (maxDim <= target) return src
        val scale = target.toFloat() / maxDim.toFloat()
        val nw = (src.width * scale).toInt().coerceAtLeast(1)
        val nh = (src.height * scale).toInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(src, nw, nh, true)
    }

    // ===== 从相册选择 + 保存到相册 =====

    private fun copyUriToCache(uri: Uri, name: String): String? {
        return try {
            val dir = File(cacheDir, "pick")
            dir.mkdirs()
            val dest = File(dir, "${System.currentTimeMillis()}_$name")
            val readableUri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
            ) {
                try {
                    MediaStore.setRequireOriginal(uri)
                } catch (_: Exception) {
                    uri
                }
            } else {
                uri
            }
            val input = contentResolver.openInputStream(readableUri) ?: return null
            input.use { inStream ->
                dest.outputStream().use { outStream -> inStream.copyTo(outStream) }
            }
            dest.absolutePath
        } catch (e: Exception) {
            null
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && cursor.moveToFirst()) cursor.getString(idx) else null
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun saveWithPermission(
        destination: String,
        files: List<SaveFile>,
        kind: String,
        result: MethodChannel.Result,
    ) {
        if (files.isEmpty()) {
            result.success(saveResult("failed", "没有可保存的文件"))
            return
        }
        if (destination == "album") {
            val file = files.singleOrNull()
            if (file == null || !isAlbumSupported(file.name)) {
                result.success(saveResult("unsupported", "该格式不能保存到系统相册"))
                return
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val value = if (destination == "album") {
                val file = files.single()
                val saved = saveToAlbumMediaStore(file.path, file.name, kind, file.mimeType)
                if (saved) saveResult("saved", savedCount = 1)
                else saveResult("failed", "保存到系统相册失败")
            } else {
                saveToDownloadsMediaStore(files)
            }
            result.success(value)
            return
        }
        if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(
                runLegacySave(PendingSaveOperation(destination, files, kind, result))
            )
            return
        }
        pendingSaveOperation = PendingSaveOperation(destination, files, kind, result)
        requestPermissions(
            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
            REQUEST_SAVE_PERMISSION,
        )
    }

    private fun runLegacySave(operation: PendingSaveOperation): Map<String, Any> {
        if (operation.destination == "album") {
            val file = operation.files.single()
            val saved = saveToAlbumLegacy(
                file.path,
                file.name,
                operation.kind,
                file.mimeType,
            )
            return if (saved) saveResult("saved", savedCount = 1)
            else saveResult("failed", "保存到系统相册失败")
        }
        return saveToDownloadsLegacy(operation.files)
    }

    private fun saveResult(
        status: String,
        message: String = "",
        savedCount: Int = 0,
    ): Map<String, Any> = mapOf(
        "status" to status,
        "message" to message,
        "savedCount" to savedCount,
    )

    private fun isAlbumSupported(name: String): Boolean =
        name.substringAfterLast('.', "").lowercase() in setOf(
            "jpg", "jpeg", "png", "heic", "heif", "gif", "webp",
            "mp4", "mov", "m4v", "3gp",
        )

    private fun saveToAlbumMediaStore(
        path: String?,
        name: String,
        kind: String,
        mimeType: String,
    ): Boolean {
        if (path == null) return false
        val f = File(path)
        if (!f.exists()) return false
        var insertedUri: Uri? = null
        return try {
            val mime = normalizedMediaMimeType(name, mimeType)
            val isVideo = kind == "video" || mime.startsWith("video/")
            Log.d("LinkNest", "开始保存媒体到相册 kind=$kind mime=$mime")
            val collection = if (isVideo) {
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            } else {
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            }
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, if (name.isNotEmpty()) name else f.name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(
                    MediaStore.MediaColumns.RELATIVE_PATH,
                    if (isVideo) "Movies/LinkNest" else "Pictures/LinkNest"
                )
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(collection, values) ?: return false
            insertedUri = uri
            val out = contentResolver.openOutputStream(uri)
                ?: throw IllegalStateException("MediaStore 输出流不可用")
            out.use { o -> f.inputStream().use { i -> i.copyTo(o) } }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            if (contentResolver.update(uri, values, null, null) != 1) {
                throw IllegalStateException("MediaStore 无法完成写入")
            }
            insertedUri = null
            true
        } catch (e: Exception) {
            insertedUri?.let { uri ->
                try {
                    contentResolver.delete(uri, null, null)
                } catch (cleanupError: Exception) {
                    Log.d("LinkNest", "清理相册临时记录失败", cleanupError)
                }
            }
            Log.d("LinkNest", "保存媒体到相册失败", e)
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun saveToAlbumLegacy(
        path: String?,
        name: String,
        kind: String,
        mimeType: String,
    ): Boolean {
        if (path == null) return false
        val f = File(path)
        if (!f.exists()) return false
        return try {
            val mime = normalizedMediaMimeType(name, mimeType)
            val isVideo = kind == "video" || mime.startsWith("video/")
            val base = Environment.getExternalStoragePublicDirectory(
                if (isVideo) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES
            )
            val dir = File(base, "LinkNest")
            dir.mkdirs()
            val dest = File(dir, if (name.isNotEmpty()) name else f.name)
            f.inputStream().use { inStream ->
                dest.outputStream().use { outStream -> inStream.copyTo(outStream) }
            }
            MediaScannerConnection.scanFile(
                applicationContext,
                arrayOf(dest.absolutePath),
                arrayOf(mime),
                null
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun saveToDownloadsMediaStore(files: List<SaveFile>): Map<String, Any> {
        val inserted = mutableListOf<Uri>()
        return try {
            for (item in files) {
                val source = File(item.path)
                if (!source.exists()) throw IllegalStateException("待保存文件不存在")
                val displayName = File(item.name).name.ifEmpty { source.name }
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                    put(
                        MediaStore.MediaColumns.MIME_TYPE,
                        normalizedMediaMimeType(displayName, item.mimeType),
                    )
                    put(
                        MediaStore.MediaColumns.RELATIVE_PATH,
                        "${Environment.DIRECTORY_DOWNLOADS}/LinkNest",
                    )
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    values,
                ) ?: throw IllegalStateException("Downloads 无法创建文件")
                inserted.add(uri)
                contentResolver.openOutputStream(uri)?.use { output ->
                    source.inputStream().use { input -> input.copyTo(output) }
                } ?: throw IllegalStateException("Downloads 输出流不可用")
            }
            for (uri in inserted) {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.IS_PENDING, 0)
                }
                if (contentResolver.update(uri, values, null, null) != 1) {
                    throw IllegalStateException("Downloads 无法完成写入")
                }
            }
            Log.d("LinkNest", "文件已保存到 Downloads count=${inserted.size}")
            saveResult("saved", savedCount = inserted.size)
        } catch (error: Exception) {
            for (uri in inserted) {
                try {
                    contentResolver.delete(uri, null, null)
                } catch (cleanupError: Exception) {
                    Log.d("LinkNest", "清理 Downloads 临时记录失败", cleanupError)
                }
            }
            Log.d("LinkNest", "保存文件到 Downloads 失败", error)
            saveResult("failed", "保存到 Downloads 失败")
        }
    }

    @Suppress("DEPRECATION")
    private fun saveToDownloadsLegacy(files: List<SaveFile>): Map<String, Any> {
        val created = mutableListOf<File>()
        return try {
            val directory = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "LinkNest",
            )
            if (!directory.exists() && !directory.mkdirs()) {
                throw IllegalStateException("无法创建 Downloads/LinkNest")
            }
            for (item in files) {
                val source = File(item.path)
                if (!source.exists()) throw IllegalStateException("待保存文件不存在")
                val requestedName = File(item.name).name.ifEmpty { source.name }
                val destination = uniqueDestination(directory, requestedName)
                source.inputStream().use { input ->
                    destination.outputStream().use { output -> input.copyTo(output) }
                }
                created.add(destination)
            }
            MediaScannerConnection.scanFile(
                applicationContext,
                created.map { it.absolutePath }.toTypedArray(),
                files.map { normalizedMediaMimeType(it.name, it.mimeType) }.toTypedArray(),
                null,
            )
            Log.d("LinkNest", "文件已通过兼容方式保存到 Downloads count=${created.size}")
            saveResult("saved", savedCount = created.size)
        } catch (error: Exception) {
            for (file in created) {
                try {
                    file.delete()
                } catch (_: Exception) {}
            }
            Log.d("LinkNest", "通过兼容方式保存文件失败", error)
            saveResult("failed", "保存到 Downloads 失败")
        }
    }

    private fun uniqueDestination(directory: File, requestedName: String): File {
        val safeName = requestedName.ifEmpty { "LinkNest-${System.currentTimeMillis()}" }
        var destination = File(directory, safeName)
        if (!destination.exists()) return destination
        val dot = safeName.lastIndexOf('.')
        val base = if (dot > 0) safeName.substring(0, dot) else safeName
        val extension = if (dot > 0) safeName.substring(dot) else ""
        var index = 1
        while (destination.exists()) {
            destination = File(directory, "$base ($index)$extension")
            index++
        }
        return destination
    }

    private fun normalizedMediaMimeType(name: String, supplied: String): String {
        val mapped = mediaMimeType(name.substringAfterLast('.', "").lowercase())
        return if (supplied != "application/octet-stream") supplied else mapped
    }

    private fun mediaMimeType(ext: String): String {
        return when (ext) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "heic" -> "image/heic"
            "heif" -> "image/heif"
            "bmp" -> "image/bmp"
            "tif", "tiff" -> "image/tiff"
            "mp4", "m4v" -> "video/mp4"
            "mov" -> "video/quicktime"
            "3gp" -> "video/3gpp"
            "mkv" -> "video/x-matroska"
            "webm" -> "video/webm"
            "avi" -> "video/x-msvideo"
            "mpeg", "mpg" -> "video/mpeg"
            else -> "application/octet-stream"
        }
    }
}
