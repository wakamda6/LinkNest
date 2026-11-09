import AVFoundation
import CoreLocation
import Darwin
import Flutter
import ImageIO
import NetworkExtension
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pickerDelegate: PickerDelegate?
  private var documentExportDelegate: DocumentExportDelegate?
  private var nativeChannel: FlutterMethodChannel?
  private var guestBackgroundTask: UIBackgroundTaskIdentifier = .invalid
  private let reverseGeocoder = CLGeocoder()
  private let guestWifi = GuestWifiJoiner()
  private var bonjourRegistration: UnsafeMutableRawPointer?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationWillTerminate(_ application: UIApplication) {
    stopSpaceAdvertisement()
    super.applicationWillTerminate(application)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let livePhotoRegistrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "linknest.livePhotoView"
    ) {
      livePhotoRegistrar.register(
        LivePhotoViewFactory(messenger: livePhotoRegistrar.messenger()),
        withId: "linknest/live-photo"
      )
    } else {
      print("[LinkNest] 无法注册 PHLivePhotoView 平台视图")
    }

    // Flutter 3.47 隐式引擎模型：binaryMessenger 经 applicationRegistrar 获取。
    let messenger = engineBridge.applicationRegistrar.messenger()
    let channel = FlutterMethodChannel(name: "linknest/native", binaryMessenger: messenger)
    nativeChannel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "joinGuestWifi":
        self.guestWifi.join(arguments: call.arguments, addressReady: {
          Self.localAddresses().contains { ($0["interface"] as? String)?.hasPrefix("en") == true }
        }, result: result)
      case "releaseGuestWifi":
        if let id = (call.arguments as? [String: Any])?["requestId"] as? NSNumber {
          self.guestWifi.release(id: id.int64Value)
        }
        result(nil)
      case "openWifiSettings":
        // iOS 没有公开的 Wi-Fi 设置直达 API，由 Flutter 显示手动连接指引。
        result(false)
      case "getLocalIp":
        result(Self.localAddresses().first?["address"] ?? "")
      case "getLocalAddresses":
        result(Self.localAddresses())
      case "startSpaceAdvertisement":
        let args = call.arguments as? [String: Any] ?? [:]
        result(self.startSpaceAdvertisement(args))
      case "stopSpaceAdvertisement":
        self.stopSpaceAdvertisement()
        result(nil)
      case "getWifiGatewayCandidates":
        result(Self.wifiGatewayCandidates())
      case "startHotspot":
        // iOS 无公开 API 开启个人热点，只能引导用户手动开启。
        result(["supported": false, "message": "请在 设置/控制中心 手动开启个人热点"])
      case "stopHotspot":
        // iOS 热点由用户手动控制，App 侧无需操作。
        result(nil)
      case "setKeepAwake":
        let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
        UIApplication.shared.isIdleTimerDisabled = enabled
        result(nil)
      case "startHostForegroundService":
        // iOS 没有与 Android 前台 Service 对等的长期后台机制。
        result(["started": true, "notificationPermissionGranted": true])
      case "updateHostForegroundService", "stopHostForegroundService":
        result(nil)
      case "startGuestTransferService":
        self.startGuestBackgroundTask(result: result)
      case "updateGuestTransferService":
        // iOS 不显示常驻传输通知；有限后台任务只负责争取安全收尾时间。
        result(nil)
      case "stopGuestTransferService":
        self.endGuestBackgroundTask()
        result(nil)
      case "getPowerState":
        result(Self.powerState())
      case "getFreeDiskBytes":
        do {
          let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
          let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
          let bytes = values.volumeAvailableCapacityForImportantUsage ?? -1
          print("[LinkNest] 可用存储空间已读取 bytes=\(bytes)")
          result(bytes)
        } catch {
          print("[LinkNest] 读取可用存储空间失败 reason=\(type(of: error))")
          result(-1)
        }
      case "prepareLocalVideoPlayback":
        let args = call.arguments as? [String: String] ?? [:]
        let path = args["path"] ?? ""
        let ext = args["extension"]?.lowercased() ?? ""
        guard !path.isEmpty,
              ["mp4", "m4v", "mov", "3gp", "mkv", "webm", "avi", "mpeg", "mpg"].contains(ext),
              FileManager.default.fileExists(atPath: path) else {
          result(FlutterError(code: "VIDEO_LINK_INVALID", message: "视频路径或格式无效", details: nil))
          break
        }
        let temporary = FileManager.default.temporaryDirectory
          .appendingPathComponent("linknest-playback-\(UUID().uuidString).\(ext)")
        do {
          try FileManager.default.linkItem(
            at: URL(fileURLWithPath: path),
            to: temporary
          )
          result(temporary.path)
        } catch {
          result(FlutterError(
            code: "VIDEO_LINK_FAILED",
            message: "无法准备本地视频播放文件：\(error.localizedDescription)",
            details: nil
          ))
        }
      case "getAppVersion":
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
          as? String ?? "unknown"
        result(version)
      case "makeThumbnail":
        let path = (call.arguments as? [String: Any])?["path"] as? String
        let kind = (call.arguments as? [String: Any])?["kind"] as? String ?? ""
        let target = (call.arguments as? [String: Any])?["target"] as? Int ?? 512
        let name = (call.arguments as? [String: Any])?["name"] as? String ?? ""
        Self.makeThumbnail(path: path, kind: kind, target: target, name: name) { data in
          DispatchQueue.main.async { result(data) }
        }
      case "readPhotoCoordinates":
        let path = (call.arguments as? [String: Any])?["path"] as? String
        DispatchQueue.global(qos: .utility).async {
          let value = Self.readPhotoCoordinates(path: path)
          DispatchQueue.main.async { result(value) }
        }
      case "reverseGeocode":
        let arguments = call.arguments as? [String: Any]
        self.reverseGeocode(
          latitude: arguments?["latitude"] as? Double,
          longitude: arguments?["longitude"] as? Double,
          result: result
        )
      case "pickFromAlbum":
        self.presentPicker(result: result)
      case "saveToAlbum":
        let path = (call.arguments as? [String: Any])?["path"] as? String
        let name = (call.arguments as? [String: Any])?["name"] as? String ?? ""
        let kind = (call.arguments as? [String: Any])?["kind"] as? String ?? ""
        let mimeType = (call.arguments as? [String: Any])?["mimeType"] as? String
          ?? "application/octet-stream"
        Self.saveToAlbum(path: path, name: name, kind: kind, mimeType: mimeType) { value in
          result(value)
        }
      case "saveLivePhoto":
        let args = call.arguments as? [String: Any]
        Self.saveLivePhoto(
          photoPath: args?["photoPath"] as? String,
          photoName: args?["photoName"] as? String ?? "photo.heic",
          pairedVideoPath: args?["pairedVideoPath"] as? String,
          pairedVideoName: args?["pairedVideoName"] as? String ?? "video.mov"
        ) { value in
          result(value)
        }
      case "saveToFiles":
        self.presentDocumentExporter(arguments: call.arguments, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func readPhotoCoordinates(path: String?) -> [String: Double]? {
    guard let path = path,
          let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
          let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
          let rawLatitude = gps[kCGImagePropertyGPSLatitude] as? Double,
          let rawLongitude = gps[kCGImagePropertyGPSLongitude] as? Double else {
      print("[LinkNest] 照片不包含可读取的 GPS 信息")
      return nil
    }
    let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
    let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
    let latitude = latitudeRef.uppercased() == "S" ? -rawLatitude : rawLatitude
    let longitude = longitudeRef.uppercased() == "W" ? -rawLongitude : rawLongitude
    print("[LinkNest] 已读取照片 GPS 信息")
    return ["latitude": latitude, "longitude": longitude]
  }

  private func reverseGeocode(
    latitude: Double?,
    longitude: Double?,
    result: @escaping FlutterResult
  ) {
    guard let latitude = latitude, let longitude = longitude,
          (-90...90).contains(latitude), (-180...180).contains(longitude) else {
      result(nil)
      return
    }
    reverseGeocoder.reverseGeocodeLocation(
      CLLocation(latitude: latitude, longitude: longitude)
    ) { placemarks, error in
      if let error = error {
        print("[LinkNest] 照片地点反向解析不可用 reason=\(type(of: error))")
        result(nil)
        return
      }
      guard let placemark = placemarks?.first else {
        result(nil)
        return
      }
      let parts = [placemark.administrativeArea, placemark.locality, placemark.subLocality]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .reduce(into: [String]()) { values, part in
          if !values.contains(part) { values.append(part) }
        }
      let label = parts.isEmpty ? placemark.country : parts.joined(separator: " · ")
      result(label?.isEmpty == false ? label : nil)
    }
  }

  private func startGuestBackgroundTask(result: @escaping FlutterResult) {
    if guestBackgroundTask != .invalid {
      result(["started": true, "notificationPermissionGranted": true])
      return
    }
    guestBackgroundTask = UIApplication.shared.beginBackgroundTask(
      withName: "LinkNest Guest Transfer"
    ) { [weak self] in
      guard let self = self else { return }
    print("[LinkNest] 访客后台执行时间已到期")
      guard let channel = self.nativeChannel else {
        self.endGuestBackgroundTask()
        return
      }
      channel.invokeMethod("guestBackgroundTimeExpired", arguments: nil) { [weak self] _ in
        self?.endGuestBackgroundTask()
      }
    }
    let started = guestBackgroundTask != .invalid
    print("[LinkNest] 访客后台任务已启动 started=\(started)")
    result(["started": started, "notificationPermissionGranted": true])
  }

  private func endGuestBackgroundTask() {
    guard guestBackgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(guestBackgroundTask)
    guestBackgroundTask = .invalid
    print("[LinkNest] 访客后台任务已停止")
  }

  private func startSpaceAdvertisement(_ args: [String: Any]) -> FlutterError? {
    stopSpaceAdvertisement()
    guard let interface = args["interface"] as? String, !interface.isEmpty,
          let spaceId = args["sid"] as? String, !spaceId.isEmpty,
          let port = args["port"] as? Int, (1...65535).contains(port) else {
      return FlutterError(code: "NSD_INVALID", message: "缺少局域网广告接口或端口", details: nil)
    }
    var txt = Data()
    for key in ["pv", "sid", "sname", "sess", "token", "addr"] {
      guard let value = args[key] as? String else {
        return FlutterError(code: "NSD_INVALID", message: "局域网广告字段不完整", details: nil)
      }
      let entry = Data("\(key)=\(value)".utf8)
      guard entry.count <= 255 else {
        return FlutterError(code: "NSD_INVALID", message: "局域网广告字段过长", details: nil)
      }
      txt.append(UInt8(entry.count))
      txt.append(entry)
    }
    guard txt.count <= Int(UInt16.max) else {
      return FlutterError(code: "NSD_INVALID", message: "局域网广告内容过长", details: nil)
    }
    let registration = txt.withUnsafeBytes { bytes in
      LinkNestBonjourStart(
        interface,
        "LinkNest-\(spaceId.prefix(24))",
        UInt16(port),
        bytes.bindMemory(to: UInt8.self).baseAddress,
        UInt16(txt.count)
      )
    }
    guard let registration else {
      return FlutterError(code: "NSD_FAILED", message: "局域网空间广告注册失败", details: nil)
    }
    bonjourRegistration = registration
    print("[LinkNest] iOS 局域网空间广告已提交 interface=\(interface) port=\(port)")
    return nil
  }

  private func stopSpaceAdvertisement() {
    guard let registration = bonjourRegistration else { return }
    LinkNestBonjourStop(registration)
    bonjourRegistration = nil
    print("[LinkNest] iOS 局域网空间广告已停止")
  }

  /// 枚举实际可用的私网 IPv4。接口名只用于排序，不作为固定系统契约。
  static func localAddresses() -> [[String: Any]] {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
    defer { freeifaddrs(pointer) }

    var values: [[String: Any]] = []
    var current: UnsafeMutablePointer<ifaddrs>? = first
    while let item = current {
      defer { current = item.pointee.ifa_next }
      guard let socketAddress = item.pointee.ifa_addr,
            socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
      let flags = Int32(item.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

      let interface = String(cString: item.pointee.ifa_name)
      if interface.hasPrefix("pdp_ip") || interface.hasPrefix("utun") { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let status = getnameinfo(
        socketAddress,
        socklen_t(socketAddress.pointee.sa_len),
        &host,
        socklen_t(host.count),
        nil,
        0,
        NI_NUMERICHOST
      )
      guard status == 0 else { continue }
      let address = String(cString: host)
      guard isSupportedLanIPv4(address) else { continue }
      let kind: String
      if interface.hasPrefix("bridge") && address == "172.20.10.1" {
        kind = "hotspot"
      } else if LinkNestIsWifiInterface(interface) != 0 {
        kind = "wifi"
      } else {
        kind = "other"
      }
      let priority: Int
      if kind == "hotspot" {
        priority = 100
      } else if kind == "wifi" {
        priority = 50
      } else {
        priority = 20
      }
      values.append([
        "address": address,
        "interface": interface,
        "kind": kind,
        "priority": priority,
      ])
    }
    return values.sorted {
      ($0["priority"] as? Int ?? 0) > ($1["priority"] as? Int ?? 0)
    }
  }

  /// iOS 没有公开的 Wi-Fi 默认网关 API。对当前 en* 私网接口按实际子网掩码
  /// 计算首个主机地址；后续 HTTP 握手和 spaceId 校验会拒绝错误候选。
  static func wifiGatewayCandidates() -> [String] {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
    defer { freeifaddrs(pointer) }

    var values: [String] = []
    var seen = Set<String>()
    var current: UnsafeMutablePointer<ifaddrs>? = first
    while let item = current {
      defer { current = item.pointee.ifa_next }
      guard let socketAddress = item.pointee.ifa_addr,
            let socketMask = item.pointee.ifa_netmask,
            socketAddress.pointee.sa_family == UInt8(AF_INET),
            socketMask.pointee.sa_family == UInt8(AF_INET) else { continue }
      let flags = Int32(item.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
      let interface = String(cString: item.pointee.ifa_name)
      guard interface.hasPrefix("en") else { continue }

      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      var mask = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(
        socketAddress,
        socklen_t(socketAddress.pointee.sa_len),
        &host,
        socklen_t(host.count),
        nil,
        0,
        NI_NUMERICHOST
      ) == 0,
      getnameinfo(
        socketMask,
        socklen_t(socketMask.pointee.sa_len),
        &mask,
        socklen_t(mask.count),
        nil,
        0,
        NI_NUMERICHOST
      ) == 0 else { continue }

      let address = String(cString: host)
      guard isSupportedLanIPv4(address),
            let addressValue = ipv4Value(address),
            let maskValue = ipv4Value(String(cString: mask)) else { continue }
      let candidate = ipv4String((addressValue & maskValue) &+ 1)
      if isSupportedLanIPv4(candidate), seen.insert(candidate).inserted {
        values.append(candidate)
      }
    }
    print("[LinkNest] 已获取 Wi-Fi 网关候选地址 count=\(values.count)")
    return values
  }

  private static func ipv4Value(_ address: String) -> UInt32? {
    let parts = address.split(separator: ".").compactMap { UInt32($0) }
    guard parts.count == 4, parts.allSatisfy({ $0 <= 255 }) else { return nil }
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
  }

  private static func ipv4String(_ value: UInt32) -> String {
    "\((value >> 24) & 255).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)"
  }

  static func isSupportedLanIPv4(_ address: String) -> Bool {
    let fields = address.split(separator: ".", omittingEmptySubsequences: false)
    guard fields.count == 4 else { return false }
    let parts = fields.compactMap { Int($0) }
    guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
      return false
    }
    return parts[0] == 10
      || (parts[0] == 172 && (16...31).contains(parts[1]))
      || (parts[0] == 192 && parts[1] == 168)
  }

  static func powerState() -> [String: Any] {
    let device = UIDevice.current
    let monitoringWasEnabled = device.isBatteryMonitoringEnabled
    device.isBatteryMonitoringEnabled = true
    defer { device.isBatteryMonitoringEnabled = monitoringWasEnabled }
    let level = device.batteryLevel
    let charging = device.batteryState == .charging || device.batteryState == .full
    print(
      "[LinkNest] 已读取设备电源状态 level=\(level) charging=\(charging) "
        + "lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
    )
    let levelValue: Any = level >= 0 ? Double(level) : NSNull()
    return [
      "level": levelValue,
      "charging": charging,
      "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
    ]
  }

  // MARK: - 从相册选择（PHPicker，免权限）

  private func presentPicker(result: @escaping FlutterResult) {
    var config = PHPickerConfiguration(photoLibrary: .shared())
    config.filter = .any(of: [.images, .videos])
    config.selectionLimit = 0 // 0 = 不限数量
    config.preferredAssetRepresentationMode = .current // 保留当前资源表示，避免兼容性转码
    #if DEBUG
    print("[LinkNest] 相册诊断 选择器配置 format=current filter=images+videos")
    #endif
    if #available(iOS 15.0, *) {
      config.selection = .ordered
    }
    let picker = PHPickerViewController(configuration: config)
    let delegate = PickerDelegate(result: result) { [weak self] in
      self?.pickerDelegate = nil
    }
    picker.delegate = delegate
    pickerDelegate = delegate // 强引用，避免 delegate 被提前释放
    guard let top = UIApplication.shared.topViewController else {
      pickerDelegate = nil
      result(FlutterError(code: "NO_WINDOW", message: "无法获取顶层视图控制器", details: nil))
      return
    }
    top.present(picker, animated: true)
  }

  private func presentDocumentExporter(arguments: Any?, result: @escaping FlutterResult) {
    guard documentExportDelegate == nil else {
      result(Self.saveResult("failed", "已有文件保存操作正在进行"))
      return
    }
    let values = (arguments as? [String: Any])?["files"] as? [[String: Any]] ?? []
    guard !values.isEmpty else {
      result(Self.saveResult("failed", "没有可保存的文件"))
      return
    }
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("linknest-export-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
      var urls: [URL] = []
      var usedNames = Set<String>()
      for value in values {
        guard let path = value["path"] as? String,
              FileManager.default.fileExists(atPath: path) else {
          throw NSError(
            domain: "LinkNest",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "待保存文件不存在"]
          )
        }
        let requested = (value["name"] as? String) ?? URL(fileURLWithPath: path).lastPathComponent
        let name = Self.uniqueExportName(requested, usedNames: &usedNames)
        let destination = tempRoot.appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: destination)
        urls.append(destination)
      }
      guard let top = UIApplication.shared.topViewController else {
        try? FileManager.default.removeItem(at: tempRoot)
        result(Self.saveResult("failed", "无法显示系统文件选择器"))
        return
      }
      let delegate = DocumentExportDelegate(
        result: result,
        temporaryDirectory: tempRoot,
        expectedCount: urls.count
      ) { [weak self] in
        self?.documentExportDelegate = nil
      }
      documentExportDelegate = delegate
      let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
      picker.delegate = delegate
      picker.allowsMultipleSelection = false
      top.present(picker, animated: true)
      print("[LinkNest] 正在展示系统文件导出界面 count=\(urls.count)")
    } catch {
      try? FileManager.default.removeItem(at: tempRoot)
      print("[LinkNest] 准备系统文件导出失败 reason=\(type(of: error))")
      result(Self.saveResult("failed", "准备导出文件失败"))
    }
  }

  private static func uniqueExportName(_ value: String, usedNames: inout Set<String>) -> String {
    let raw = (value as NSString).lastPathComponent
    let safe = raw.isEmpty ? "LinkNest-file" : raw
    var candidate = safe
    var index = 1
    let ext = (safe as NSString).pathExtension
    let base = (safe as NSString).deletingPathExtension
    while usedNames.contains(candidate) {
      candidate = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
      index += 1
    }
    usedNames.insert(candidate)
    return candidate
  }

  // MARK: - 保存到相册

  static func saveToAlbum(
    path: String?,
    name: String = "",
    kind: String = "",
    mimeType: String = "application/octet-stream",
    completion: @escaping ([String: Any]) -> Void
  ) {
    guard let path = path, FileManager.default.fileExists(atPath: path) else {
      print("[LinkNest] 待保存到相册的文件不存在")
      completion(saveResult("failed", "待保存文件不存在"))
      return
    }
    let ext = (name as NSString).pathExtension.lowercased()
    let supported = [
      "jpg", "jpeg", "png", "heic", "heif", "gif", "webp",
      "mp4", "mov", "m4v", "3gp",
    ].contains(ext)
    guard supported else {
      completion(saveResult("unsupported", "该格式不能保存到系统相册"))
      return
    }
    requestPhotoAddAuthorization { authorized in
      guard authorized else {
        completion(saveResult("permissionDenied", "没有添加到系统相册的权限"))
        return
      }
      let url = URL(fileURLWithPath: path)
      let isVideo = kind == "video" || mimeType.hasPrefix("video/")
      print("[LinkNest] 开始保存媒体到相册 kind=\(kind) mime=\(mimeType) isVideo=\(isVideo)")
      let tempUrl = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + "." + ext)
      do {
        try FileManager.default.copyItem(at: url, to: tempUrl)
      } catch {
        print("[LinkNest] 准备相册媒体文件失败 reason=\(type(of: error))")
        completion(saveResult("failed", "准备相册文件失败"))
        return
      }
      PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCreationRequest.forAsset()
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = name.isEmpty ? tempUrl.lastPathComponent : name
        request.addResource(with: isVideo ? .video : .photo, fileURL: tempUrl, options: options)
      }) { ok, error in
        print("[LinkNest] 保存媒体到相册结束 success=\(ok) errorPresent=\(error != nil)")
        try? FileManager.default.removeItem(at: tempUrl)
        DispatchQueue.main.async {
          completion(
            ok && error == nil
              ? saveResult("saved", savedCount: 1)
              : saveResult("failed", "系统相册拒绝了该文件")
          )
        }
      }
    }
  }

  static func saveLivePhoto(
    photoPath: String?,
    photoName: String,
    pairedVideoPath: String?,
    pairedVideoName: String,
    completion: @escaping ([String: Any]) -> Void
  ) {
    guard let photoPath = photoPath,
          let pairedVideoPath = pairedVideoPath,
          FileManager.default.fileExists(atPath: photoPath),
          FileManager.default.fileExists(atPath: pairedVideoPath) else {
      print("[LinkNest] Live Photo 配对资源不存在")
      completion(saveResult("failed", "Live Photo 组成资源不完整"))
      return
    }
    requestPhotoAddAuthorization { authorized in
      guard authorized else {
        completion(saveResult("permissionDenied", "没有添加到系统相册的权限"))
        return
      }
      let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("linknest-live-save-\(UUID().uuidString)", isDirectory: true)
      do {
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let photoURL = tempRoot.appendingPathComponent(photoName)
        let videoURL = tempRoot.appendingPathComponent(pairedVideoName)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: photoPath), to: photoURL)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: pairedVideoPath), to: videoURL)
        PHPhotoLibrary.shared().performChanges({
          let request = PHAssetCreationRequest.forAsset()
          let photoOptions = PHAssetResourceCreationOptions()
          photoOptions.originalFilename = photoName
          request.addResource(with: .photo, fileURL: photoURL, options: photoOptions)
          let videoOptions = PHAssetResourceCreationOptions()
          videoOptions.originalFilename = pairedVideoName
          request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)
        }) { ok, error in
          print("[LinkNest] 保存 Live Photo 结束 success=\(ok) errorPresent=\(error != nil)")
          try? FileManager.default.removeItem(at: tempRoot)
          DispatchQueue.main.async {
            completion(
              ok && error == nil
                ? saveResult("saved", savedCount: 1)
                : saveResult("failed", "系统相册无法恢复该 Live Photo")
            )
          }
        }
      } catch {
        print("[LinkNest] 准备 Live Photo 临时资源失败 reason=\(type(of: error))")
        try? FileManager.default.removeItem(at: tempRoot)
        completion(saveResult("failed", "准备 Live Photo 资源失败"))
      }
    }
  }

  private static func requestPhotoAddAuthorization(completion: @escaping (Bool) -> Void) {
    let finish: (PHAuthorizationStatus) -> Void = { status in
      DispatchQueue.main.async {
        completion(status == .authorized || status == .limited)
      }
    }
    let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    if status == .notDetermined {
      PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: finish)
    } else {
      finish(status)
    }
  }

  fileprivate static func saveResult(
    _ status: String,
    _ message: String = "",
    savedCount: Int = 0
  ) -> [String: Any] {
    ["status": status, "message": message, "savedCount": savedCount]
  }

  /// 生成 JPEG 缩略图：图像用 ImageIO（原生解码 HEIC），视频用 AVAssetImageGenerator 异步取帧。
  /// `kind` 由服务端传入（image/video/other），原文件无扩展名、不能靠扩展名判断。
  /// `target` 为长边最大像素（网格 512，大图预览更高）。
  static func makeThumbnail(
    path: String?,
    kind: String = "",
    target: Int = 512,
    name: String = "",
    completion: @escaping (FlutterStandardTypedData?) -> Void
  ) {
    guard let path = path else {
      completion(nil)
      return
    }
    let url = URL(fileURLWithPath: path)
    print("[LinkNest] 开始生成媒体缩略图 kind=\(kind) target=\(target)")
    if kind == "video" {
      DispatchQueue.global(qos: .userInitiated).async {
        let prepareStarted = CFAbsoluteTimeGetCurrent()
        let prepared: (url: URL, mode: String)
        do {
          prepared = try prepareVideoURL(source: url, name: name)
        } catch {
          print("[LinkNest] 准备视频缩略图资源失败 reason=\(type(of: error))")
          completion(nil)
          return
        }
        let prepareMs = Int((CFAbsoluteTimeGetCurrent() - prepareStarted) * 1000)
        print("[LinkNest] 视频缩略图资源准备完成 mode=\(prepared.mode) elapsedMs=\(prepareMs)")
        videoThumbnail(url: prepared.url, target: target) { image in
          try? FileManager.default.removeItem(at: prepared.url)
          completion(image.flatMap { jpegData(from: $0, target: target) })
        }
      }
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        print("[LinkNest] 图片缩略图解码失败")
        completion(nil)
        return
      }
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: kCFBooleanTrue as Any,
        kCGImageSourceCreateThumbnailWithTransform: kCFBooleanTrue as Any,
        kCGImageSourceThumbnailMaxPixelSize: max(1, target),
        kCGImageSourceShouldCacheImmediately: kCFBooleanTrue as Any,
      ]
      guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
        print("[LinkNest] 图片缩略图方向变换失败")
        completion(nil)
        return
      }
      let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
      let orientation = properties?[kCGImagePropertyOrientation] ?? "unknown"
      print(
        "[LinkNest] 图片缩略图已应用 EXIF 方向 orientation=\(orientation) " +
        "output=\(img.width)x\(img.height)"
      )
      completion(jpegData(from: img, target: target))
    }
  }

  /// 视频缩略图：异步加载时长并取中间时间点；10 秒后取消，避免阻塞平台通道。
  static func videoThumbnail(
    url: URL,
    target: Int,
    completion: @escaping (CGImage?) -> Void
  ) {
    print("[LinkNest] 开始生成视频缩略图")
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: target, height: target)
    let tolerance = CMTime(seconds: 2, preferredTimescale: 600)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance
    let request = ThumbnailRequest(generator: generator, completion: completion)
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 10) {
      request.finish(nil, reason: "timeout")
    }
    asset.loadValuesAsynchronously(forKeys: ["duration"]) {
      var error: NSError?
      let status = asset.statusOfValue(forKey: "duration", error: &error)
      guard status == .loaded, error == nil else {
        print("[LinkNest] 加载视频时长失败 status=\(status.rawValue) errorPresent=\(error != nil)")
        request.finish(nil, reason: "duration")
        return
      }
      let duration = asset.duration.seconds
      let seconds = thumbnailTimeSeconds(duration: duration)
        print("[LinkNest] 视频缩略图取帧参数 duration=\(duration) seconds=\(seconds) target=\(target)")
      let time = NSValue(time: CMTime(seconds: seconds, preferredTimescale: 600))
      generator.generateCGImagesAsynchronously(forTimes: [time]) { _, image, _, status, error in
        if status == .succeeded, let image = image {
          request.finish(image, reason: "success")
        } else {
          print("[LinkNest] 视频缩略图取帧失败 status=\(status.rawValue) errorPresent=\(error != nil)")
          request.finish(nil, reason: "generator")
        }
      }
    }
  }

  /// 短视频取中点；其余取前 10%，并限制到 1...5 秒，避开常见开头黑场。
  static func thumbnailTimeSeconds(duration: Double) -> Double {
    guard duration.isFinite, duration > 0 else { return 1.0 }
    if duration < 2 { return duration / 2 }
    return min(5.0, max(1.0, duration * 0.1))
  }

  /// 原文件无扩展名。优先创建同卷硬链接提供容器扩展名，失败时才复制原文件。
  static func prepareVideoURL(source: URL, name: String) throws -> (url: URL, mode: String) {
    let ext = (name as NSString).pathExtension.lowercased()
    let finalExtension = ext.isEmpty ? "mov" : ext
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + "." + finalExtension)
    do {
      try FileManager.default.linkItem(at: source, to: temporary)
      return (temporary, "hard-link")
    } catch {
      print("[LinkNest] 创建缩略图硬链接失败，改用复制 reason=\(type(of: error))")
      try FileManager.default.copyItem(at: source, to: temporary)
      return (temporary, "copy")
    }
  }

  /// 将 CGImage 缩放到长边不超过 `target`、编码为 JPEG（UIGraphicsImageRenderer 处理 HDR 色彩空间）。
  static func jpegData(from cgImage: CGImage, target: Int = 512) -> FlutterStandardTypedData? {
    let maxDim = max(cgImage.width, cgImage.height)
    let scale: CGFloat = maxDim > target ? CGFloat(target) / CGFloat(maxDim) : 1.0
    let nw = max(1, Int(CGFloat(cgImage.width) * scale))
    let nh = max(1, Int(CGFloat(cgImage.height) * scale))
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: nw, height: nh))
    let image = renderer.image { _ in
      UIImage(cgImage: cgImage).draw(in: CGRect(x: 0, y: 0, width: nw, height: nh))
    }
    guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
    return FlutterStandardTypedData(bytes: data)
  }

  /// 从图片文件探测实际 UTI 的扩展名（避开 public.pvt 等私有扩展名）。
  static func detectImageExtension(_ url: URL) -> String? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let type = CGImageSourceGetType(src) else { return nil }
    return UTType(type as String)?.preferredFilenameExtension
  }
}

private final class ThumbnailRequest: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false
  private let generator: AVAssetImageGenerator
  private let completion: (CGImage?) -> Void

  init(generator: AVAssetImageGenerator, completion: @escaping (CGImage?) -> Void) {
    self.generator = generator
    self.completion = completion
  }

  func finish(_ image: CGImage?, reason: String) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    lock.unlock()
    if image == nil { generator.cancelAllCGImageGeneration() }
    print("[LinkNest] 视频缩略图生成结束 reason=\(reason) success=\(image != nil)")
    completion(image)
  }
}

// MARK: - 系统“文件”导出

private class DocumentExportDelegate: NSObject, UIDocumentPickerDelegate {
  private let result: FlutterResult
  private let temporaryDirectory: URL
  private let expectedCount: Int
  private let onFinished: () -> Void
  private var completed = false

  init(
    result: @escaping FlutterResult,
    temporaryDirectory: URL,
    expectedCount: Int,
    onFinished: @escaping () -> Void
  ) {
    self.result = result
    self.temporaryDirectory = temporaryDirectory
    self.expectedCount = expectedCount
    self.onFinished = onFinished
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    finish(AppDelegate.saveResult("saved", savedCount: expectedCount))
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(AppDelegate.saveResult("cancelled", "已取消保存"))
  }

  private func finish(_ value: [String: Any]) {
    guard !completed else { return }
    completed = true
    try? FileManager.default.removeItem(at: temporaryDirectory)
    let status = value["status"] ?? "unknown"
    print("[LinkNest] 系统文件导出结束 status=\(status)")
    result(value)
    onFinished()
  }
}

// MARK: - PHPicker 委托：把选中项按文件原样拷贝进临时目录

private class PickerDelegate: NSObject, PHPickerViewControllerDelegate {
  private let result: FlutterResult
  private let onFinished: () -> Void

  private func diagnostic(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[LinkNest] 相册诊断 \(message())")
    #endif
  }

  private func authorizationLabel(_ status: PHAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "未请求"
    case .restricted: return "系统限制"
    case .denied: return "已拒绝"
    case .authorized: return "完全授权"
    case .limited: return "部分授权"
    @unknown default: return "未知"
    }
  }

  private func isLivePhoto(_ item: PHPickerResult) -> Bool {
    item.itemProvider.canLoadObject(ofClass: PHLivePhoto.self)
  }

  #if DEBUG
  private func diagnoseSelection(_ item: PHPickerResult, index: Int) {
    let provider = item.itemProvider
    diagnostic(
      "选择项 index=\(index) " +
        "types=[\(provider.registeredTypeIdentifiers.joined(separator: ","))] " +
        "liveType=\(provider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier)) " +
        "liveObject=\(isLivePhoto(item)) " +
        "imageType=\(provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)) " +
        "movieType=\(provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)) " +
        "assetIdPresent=\(item.assetIdentifier != nil)"
    )

    let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    guard authorization == .authorized || authorization == .limited else {
      diagnostic("资产核对跳过 index=\(index) authorization=\(authorizationLabel(authorization))")
      return
    }
    guard let identifier = item.assetIdentifier else {
      diagnostic("资产核对跳过 index=\(index) reason=noAssetIdentifier")
      return
    }
    guard let asset = PHAsset.fetchAssets(
      withLocalIdentifiers: [identifier], options: nil
    ).firstObject else {
      diagnostic("资产核对失败 index=\(index) reason=assetUnavailable")
      return
    }
    let resources = PHAssetResource.assetResources(for: asset)
    diagnostic(
      "资产核对 index=\(index) photoLive=\(asset.mediaSubtypes.contains(.photoLive)) " +
        "resourceTypes=[\(resources.map { String(describing: $0.type) }.joined(separator: ","))] " +
        "photo=\(resources.contains { $0.type == .photo }) " +
        "pairedVideo=\(resources.contains { $0.type == .pairedVideo }) " +
        "fullSizePairedVideo=\(resources.contains { $0.type == .fullSizePairedVideo })"
    )
  }
  #endif

  init(result: @escaping FlutterResult, onFinished: @escaping () -> Void) {
    self.result = result
    self.onFinished = onFinished
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)

    diagnostic("选择结束 count=\(results.count)")
    #if DEBUG
    for (index, item) in results.enumerated() {
      diagnoseSelection(item, index: index)
    }
    #endif

    let containsLivePhoto = results.contains(where: isLivePhoto)
    diagnostic("选择结果需读取 Live Photo 资源=\(containsLivePhoto)")
    guard containsLivePhoto else {
      process(results)
      return
    }

    PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
      self.diagnostic("Live Photo 授权结果 status=\(self.authorizationLabel(status))")
      switch status {
      case .authorized, .limited:
        self.process(results)
      default:
        DispatchQueue.main.async {
          self.result(
            FlutterError(
              code: "PHOTO_LIBRARY_PERMISSION_DENIED",
              message: "原样导入 Live Photo 需要读取所选照片的授权",
              details: nil
            )
          )
          self.onFinished()
        }
      }
    }
  }

  private func process(_ results: [PHPickerResult]) {

    print("[LinkNest] 开始读取相册选择项 count=\(results.count)")

    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("linknest-pick", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    var items = Array<[String: String]?>(repeating: nil, count: results.count)
    var livePhotoFailed = false
    let livePhotoDetected = results.filter(isLivePhoto).count
    let group = DispatchGroup()
    let mutationQueue = DispatchQueue(label: "linknest.picker.results")

    for (index, item) in results.enumerated() {
      let provider = item.itemProvider
      let selectedLivePhoto = isLivePhoto(item)
      diagnostic("导入分支 index=\(index) route=\(selectedLivePhoto ? "livePhoto" : "ordinary")")
      if selectedLivePhoto {
        group.enter()
        loadLivePhoto(item, index: index, into: tempDir) { value in
          mutationQueue.sync {
            if let value = value {
              items[index] = value
            } else {
              livePhotoFailed = true
            }
          }
          group.leave()
        }
        continue
      }
      let isVideo = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
        || provider.hasItemConformingToTypeIdentifier(UTType.mpeg4Movie.identifier)
      let suggested = provider.suggestedName ?? (isVideo ? "video.mov" : "photo.jpg")

      group.enter()
      let typeIdentifier = isVideo ? UTType.movie.identifier : UTType.image.identifier
      provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
        defer { group.leave() }
        guard let url = url, error == nil else {
          print("[LinkNest] 读取相册选择项失败 index=\(index) reason=\(type(of: error))")
          return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else {
          print("[LinkNest] 相册选择项不是可读取文件 index=\(index)")
          return
        }
        let finalName: String
        if isVideo {
          let suggestedExtension = (suggested as NSString).pathExtension
          let detectedExtension = url.pathExtension.isEmpty ? "mov" : url.pathExtension
          let ext = suggestedExtension.isEmpty ? detectedExtension : suggestedExtension
          let base = (suggested as NSString).deletingPathExtension
          finalName = (base.isEmpty ? "video" : base) + "." + ext
        } else {
          let ext = AppDelegate.detectImageExtension(url) ?? "jpg"
          let base = (suggested as NSString).deletingPathExtension
          finalName = (base.isEmpty ? "photo" : base) + "." + ext
        }
        let dest = tempDir.appendingPathComponent(UUID().uuidString + "-" + finalName)
        self.diagnostic(
          "普通资源 index=\(index) requestedType=\(typeIdentifier) " +
            "sourceExtension=\(url.pathExtension.lowercased()) " +
            "outputExtension=\((finalName as NSString).pathExtension.lowercased())"
        )
        do {
          try FileManager.default.copyItem(at: url, to: dest)
          mutationQueue.sync {
            items[index] = ["path": dest.path, "name": finalName]
          }
        } catch {
          print("[LinkNest] 拷贝相册选择项失败 index=\(index) reason=\(type(of: error))")
        }
      }
    }

    group.notify(queue: mutationQueue) {
      let completedItems = items.compactMap { $0 }
      let didFailLivePhoto = livePhotoFailed
      let livePhotoImported = completedItems.filter { $0["pairedVideoPath"] != nil }.count
      print(
        "[LinkNest] 相册选择处理结束 requested=\(results.count) " +
          "imported=\(completedItems.count) livePhotoDetected=\(livePhotoDetected) " +
          "livePhotoImported=\(livePhotoImported) livePhotoFailed=\(didFailLivePhoto)"
      )
      DispatchQueue.main.async {
        if didFailLivePhoto {
          for item in completedItems {
            for key in ["path", "pairedVideoPath"] {
              if let path = item[key] {
                try? FileManager.default.removeItem(atPath: path)
              }
            }
          }
          self.result(
            FlutterError(
              code: "LIVE_PHOTO_IMPORT_FAILED",
              message: "无法完整读取 Live Photo 的照片与配对视频，请重试",
              details: nil
            )
          )
          self.onFinished()
          return
        }
        self.result(completedItems)
        self.onFinished()
      }
    }
  }

  private func loadLivePhoto(
    _ item: PHPickerResult,
    index: Int,
    into tempDir: URL,
    completion: @escaping ([String: String]?) -> Void
  ) {
    diagnostic("Live Photo 提取开始 index=\(index) assetIdPresent=\(item.assetIdentifier != nil)")
    guard let identifier = item.assetIdentifier else {
      diagnostic("Live Photo 提取失败 index=\(index) reason=noAssetIdentifier")
      completion(nil)
      return
    }
    guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier],
            options: nil
          ).firstObject else {
      diagnostic("Live Photo 提取失败 index=\(index) reason=assetUnavailable")
      completion(nil)
      return
    }
    let resources = PHAssetResource.assetResources(for: asset)
    diagnostic(
      "Live Photo 提取资源 index=\(index) " +
        "photoLive=\(asset.mediaSubtypes.contains(.photoLive)) " +
        "resourceTypes=[\(resources.map { String(describing: $0.type) }.joined(separator: ","))]"
    )
    guard let photo = resources.first(where: { $0.type == .photo }),
          let pairedVideo = resources.first(where: { $0.type == .pairedVideo }) else {
      diagnostic("Live Photo 提取失败 index=\(index) reason=missingPhotoOrPairedVideo")
      completion(nil)
      return
    }
    let photoName = safeResourceName(photo.originalFilename, fallback: "photo.heic")
    let videoName = safeResourceName(pairedVideo.originalFilename, fallback: "video.mov")
    let photoURL = tempDir.appendingPathComponent(UUID().uuidString + "-" + photoName)
    let videoURL = tempDir.appendingPathComponent(UUID().uuidString + "-" + videoName)
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    let resourceGroup = DispatchGroup()
    let stateQueue = DispatchQueue(label: "linknest.live-photo.resources")
    var succeeded = true
    for (resource, url) in [(photo, photoURL), (pairedVideo, videoURL)] {
      resourceGroup.enter()
      PHAssetResourceManager.default().writeData(
        for: resource,
        toFile: url,
        options: options
      ) { error in
        self.diagnostic(
          "Live Photo 资源写出 index=\(index) type=\(String(describing: resource.type)) success=\(error == nil)"
        )
        if let error = error {
          stateQueue.sync { succeeded = false }
          print("[LinkNest] Live Photo 资源提取失败 type=\(resource.type.rawValue) reason=\(type(of: error))")
        }
        resourceGroup.leave()
      }
    }
    resourceGroup.notify(queue: stateQueue) {
      self.diagnostic(
        "Live Photo 提取检查 index=\(index) " +
          "photoExists=\(FileManager.default.fileExists(atPath: photoURL.path)) " +
          "pairedVideoExists=\(FileManager.default.fileExists(atPath: videoURL.path)) " +
          "writeSucceeded=\(succeeded)"
      )
      guard succeeded,
            FileManager.default.fileExists(atPath: photoURL.path),
            FileManager.default.fileExists(atPath: videoURL.path) else {
        try? FileManager.default.removeItem(at: photoURL)
        try? FileManager.default.removeItem(at: videoURL)
        completion(nil)
        return
      }
      print("[LinkNest] Live Photo 配对资源提取完成 index=\(index)")
      completion([
        "path": photoURL.path,
        "name": photoName,
        "pairedVideoPath": videoURL.path,
        "pairedVideoName": videoName,
      ])
    }
  }

  private func safeResourceName(_ value: String, fallback: String) -> String {
    let name = (value as NSString).lastPathComponent
    return name.isEmpty ? fallback : name
  }
}

private final class LivePhotoViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    LivePhotoPlatformView(
      frame: frame,
      viewId: viewId,
      arguments: args,
      messenger: messenger
    )
  }
}

private final class LivePhotoPlatformView: NSObject, FlutterPlatformView {
  private let livePhotoView: PHLivePhotoView
  private let viewId: Int64
  private let playbackChannel: FlutterMethodChannel
  private var temporaryDirectory: URL?
  private var wantsPlayback = false

  init(frame: CGRect, viewId: Int64, arguments: Any?, messenger: FlutterBinaryMessenger) {
    livePhotoView = PHLivePhotoView(frame: frame)
    self.viewId = viewId
    playbackChannel = FlutterMethodChannel(
      name: "linknest/live-photo/\(viewId)", binaryMessenger: messenger
    )
    super.init()
    livePhotoView.backgroundColor = .black
    livePhotoView.contentMode = .scaleAspectFit
    livePhotoView.clipsToBounds = true
    livePhotoView.isMuted = false
    // Flutter 负责长按和横滑的手势竞争，避免原生手势只在单张图片时生效。
    livePhotoView.playbackGestureRecognizer.isEnabled = false
    playbackChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "startPlayback":
        self.wantsPlayback = true
        print("[LinkNest] 请求播放 Live Photo viewId=\(self.viewId) ready=\(self.livePhotoView.livePhoto != nil)")
        if self.livePhotoView.livePhoto != nil {
          self.livePhotoView.startPlayback(with: .full)
        }
        result(nil)
      case "stopPlayback":
        self.wantsPlayback = false
        self.livePhotoView.stopPlayback()
        print("[LinkNest] 已停止 Live Photo 播放 viewId=\(self.viewId)")
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    guard let values = arguments as? [String: Any],
          let photoPath = values["photoPath"] as? String,
          let photoName = values["photoName"] as? String,
          let pairedVideoPath = values["pairedVideoPath"] as? String,
          let pairedVideoName = values["pairedVideoName"] as? String else {
      print("[LinkNest] PHLivePhotoView 缺少资源")
      return
    }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("linknest-live-view-\(UUID().uuidString)", isDirectory: true)
    let photoURL = root.appendingPathComponent((photoName as NSString).lastPathComponent)
    let videoURL = root.appendingPathComponent((pairedVideoName as NSString).lastPathComponent)
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: URL(fileURLWithPath: photoPath), to: photoURL)
      try FileManager.default.copyItem(at: URL(fileURLWithPath: pairedVideoPath), to: videoURL)
      temporaryDirectory = root
    } catch {
        print("[LinkNest] 准备 PHLivePhotoView 资源失败 reason=\(type(of: error))")
      try? FileManager.default.removeItem(at: root)
      return
    }
    PHLivePhoto.request(
      withResourceFileURLs: [photoURL, videoURL],
      placeholderImage: nil,
      targetSize: .zero,
      contentMode: .aspectFit
    ) { [weak self] livePhoto, info in
      DispatchQueue.main.async {
        guard let self = self else { return }
        if let error = info[PHLivePhotoInfoErrorKey] {
          print("[LinkNest] 重建 Live Photo 失败 viewId=\(self.viewId) reason=\(type(of: error))")
          return
        }
        let degraded = (info[PHLivePhotoInfoIsDegradedKey] as? NSNumber)?.boolValue ?? false
        if degraded {
          print("[LinkNest] Live Photo 等待完整资源 viewId=\(self.viewId)")
          return
        }
        guard let livePhoto = livePhoto else {
          print("[LinkNest] 重建 Live Photo 结果为空 viewId=\(self.viewId)")
          return
        }
        self.livePhotoView.livePhoto = livePhoto
        print("[LinkNest] PHLivePhotoView 已准备 viewId=\(self.viewId)")
        if self.wantsPlayback {
          self.livePhotoView.startPlayback(with: .full)
        }
      }
    }
  }

  func view() -> UIView { livePhotoView }

  deinit {
    playbackChannel.setMethodCallHandler(nil)
    livePhotoView.stopPlayback()
    if let temporaryDirectory = temporaryDirectory {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }
  }
}

// MARK: - 顶层视图控制器（用于呈现 PHPicker）

extension UIApplication {
  var topViewController: UIViewController? {
    for scene in connectedScenes.compactMap({ $0 as? UIWindowScene }) {
      for window in scene.windows where window.isKeyWindow {
        var top = window.rootViewController
        while let presented = top?.presentedViewController {
          top = presented
        }
        if let top = top { return top }
      }
    }
    return nil
  }
}


/// Wi-Fi 配置由系统保存；取消只结束本次等待，不删除可能属于用户的已有配置。
private final class GuestWifiJoiner {
  private final class Request {
    let id: Int64
    var result: FlutterResult?
    var deadline: DispatchWorkItem?
    var poll: DispatchWorkItem?
    init(id: Int64, result: @escaping FlutterResult) {
      self.id = id
      self.result = result
    }
  }
  private var current: Request?
  // 系统确认窗口不能强制关闭，旧 apply 回调到达前不接受新请求。
  private var applying = false

  func join(arguments: Any?, addressReady: @escaping () -> Bool, result: @escaping FlutterResult) {
    guard !applying else { result(["status": "busy"]); return }
    guard let args = arguments as? [String: Any],
          let id = (args["requestId"] as? NSNumber)?.int64Value,
          let ssid = args["ssid"] as? String, (1...32).contains(ssid.utf8.count),
          !ssid.utf8.contains(0),
          let security = args["security"] as? String, ["open", "wpa2"].contains(security) else {
      result(["status": "unsupported"])
      return
    }
    let password = args["password"] as? String ?? ""
    if security == "wpa2" && (!(8...63).contains(password.utf8.count)
        || !password.utf8.allSatisfy({ (32...126).contains($0) })) {
      result(["status": "unsupported"])
      return
    }
    release()
    let request = Request(id: id, result: result)
    current = request
    print("[LinkNest] 开始请求 iOS 访客 Wi-Fi 连接 requestId=\(id)")
    let deadline = DispatchWorkItem { [weak self, weak request] in
      guard let self = self, let request = request, self.current === request else { return }
      self.finish(request, status: "timeout")
    }
    request.deadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 40, execute: deadline)
    let configuration = security == "open"
      ? NEHotspotConfiguration(ssid: ssid)
      : NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
    configuration.joinOnce = false
    configuration.hidden = args["hidden"] as? Bool ?? false
    applying = true
    NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.applying = false
        guard self.current === request else {
          print("[LinkNest] 忽略已取消的 iOS Wi-Fi 配置回调 requestId=\(id)")
          return
        }
        if let error = error as NSError?,
           !(error.domain == NEHotspotConfigurationErrorDomain
             && error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue) {
          print("[LinkNest] iOS Wi-Fi 配置失败 code=\(error.code)")
          let denied = error.domain == NEHotspotConfigurationErrorDomain
            && error.code == NEHotspotConfigurationError.userDenied.rawValue
          self.finish(request, status: denied ? "cancelled" : "failed")
          return
        }
        print("[LinkNest] iOS Wi-Fi 配置已受理，等待局域网地址 requestId=\(id)")
        self.waitForAddress(request, addressReady: addressReady)
      }
    }
  }

  private func waitForAddress(_ request: Request, addressReady: @escaping () -> Bool) {
    guard current === request else { return }
    if addressReady() {
      // 网卡地址只能证明局域网就绪；目标 Host 由空间码握手确认。
      finish(request, status: "verificationPending")
      return
    }
    let poll = DispatchWorkItem { [weak self] in
      self?.waitForAddress(request, addressReady: addressReady)
    }
    request.poll = poll
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
  }

  private func finish(_ request: Request, status: String) {
    guard current === request else { return }
    request.deadline?.cancel()
    request.poll?.cancel()
    request.deadline = nil
    request.poll = nil
    let result = request.result
    request.result = nil
    if status != "verificationPending" { current = nil }
    print("[LinkNest] iOS 访客 Wi-Fi 连接结束 requestId=\(request.id) status=\(status)")
    result?(["status": status])
  }

  func release(id: Int64? = nil) {
    guard let request = current, id == nil || id == request.id else { return }
    current = nil
    request.deadline?.cancel()
    request.poll?.cancel()
    request.deadline = nil
    request.poll = nil
    let result = request.result
    request.result = nil
    result?(["status": "cancelled"])
    print("[LinkNest] iOS 访客 Wi-Fi 等待已释放，保留系统网络配置 requestId=\(request.id)")
  }
}
