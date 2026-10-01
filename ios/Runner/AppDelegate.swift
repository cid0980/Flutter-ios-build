import AVFoundation
import CoreTelephony
import Flutter
import LocalAuthentication
import MediaPlayer
import Network
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, FlutterStreamHandler {

  private static let googleMapsApiKey = "AIzaSyBuNeSp9nFFImMvMPiV7UQMh_ykbiwsZN0"

  private var channelsRegistered = false

  // Channels
  private var volumeChannel: FlutterMethodChannel?
  private var powerChannel: FlutterMethodChannel?
  private var audioRouteChannel: FlutterMethodChannel?
  private var batteryChannel: FlutterMethodChannel?
  private var thermalChannel: FlutterMethodChannel?
  private var proximityScreenChannel: FlutterMethodChannel?
  private var internetChannel: FlutterMethodChannel?
  private var simDataChannel: FlutterMethodChannel?
  private var fingerprintMethodChannel: FlutterMethodChannel?
  private var fingerprintEventChannel: FlutterEventChannel?

  // Volume key observation state
  private var listeningForVolumeKeys = false
  private var volumeObservation: NSKeyValueObservation?
  private var volumeView: MPVolumeView?
  private var lastVolume: Float = 0.5
  private var adjustingVolumeProgrammatically = false

  // Power / screen lock observation state
  private var watchingPowerButton = false
  private var powerObservers: [NSObjectProtocol] = []

  // Biometric diagnostic state (from Reverse-engineering-data-s)
  private var eventSink: FlutterEventSink?
  private var authContext: LAContext?
  private var isAuthenticating = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    provideGoogleMapsKeyIfPresent()
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    if !channelsRegistered, let controller = window?.rootViewController as? FlutterViewController {
      setupChannels(messenger: controller.binaryMessenger)
    }
    return result
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    provideGoogleMapsKeyIfPresent()
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if !channelsRegistered,
       let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FrenchMobilesNativeChannels") {
      setupChannels(messenger: registrar.messenger())
    }
  }

  /// Dynamically provides the Google Maps API key to GMSServices if linked,
  /// preventing NSInternalInconsistencyException when LocationPickerPage opens.
  private func provideGoogleMapsKeyIfPresent() {
    if let gmsServices = NSClassFromString("GMSServices") as? NSObject.Type {
      let selector = NSSelectorFromString("provideAPIKey:")
      if gmsServices.responds(to: selector) {
        _ = gmsServices.perform(selector, with: Self.googleMapsApiKey)
      }
    }
  }

  private func setupChannels(messenger: FlutterBinaryMessenger) {
    guard !channelsRegistered else { return }
    channelsRegistered = true

    // 1. Volume keys channel (`french_mobiles/volume_keys`)
    let volChannel = FlutterMethodChannel(
      name: "french_mobiles/volume_keys",
      binaryMessenger: messenger
    )
    volChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "setVolumeListening" {
        let args = call.arguments as? [String: Any]
        let enabled = (args?["enabled"] as? Bool) ?? false
        self.setVolumeListening(enabled: enabled)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    self.volumeChannel = volChannel

    // 2. Audio route channel (`french_mobiles/audio_route`)
    let routeChannel = FlutterMethodChannel(
      name: "french_mobiles/audio_route",
      binaryMessenger: messenger
    )
    routeChannel.setMethodCallHandler { call, result in
      if call.method == "hasEarpiece" {
        // Every iPhone has a built-in receiver earpiece; iPads do not.
        result(UIDevice.current.userInterfaceIdiom == .phone)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    self.audioRouteChannel = routeChannel

    // 3. Battery channel (`french_mobiles/battery`)
    let batChannel = FlutterMethodChannel(
      name: "french_mobiles/battery",
      binaryMessenger: messenger
    )
    batChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "read" {
        result(self.readBattery())
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    self.batteryChannel = batChannel

    // 4. Thermal channel (`french_mobiles/thermal`)
    let thermChannel = FlutterMethodChannel(
      name: "french_mobiles/thermal",
      binaryMessenger: messenger
    )
    thermChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "read" {
        result(self.readThermal())
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    self.thermalChannel = thermChannel

    // 5. Proximity screen channel (`french_mobiles/proximity_screen`)
    let proxChannel = FlutterMethodChannel(
      name: "french_mobiles/proximity_screen",
      binaryMessenger: messenger
    )
    proxChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "isSupported":
        result(self.isProximitySupported())
      case "enable":
        result(self.enableProximityScreen())
      case "disable":
        self.disableProximityScreen()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.proximityScreenChannel = proxChannel

    // 6. Power / Side button channel (`french_mobiles/power_button`)
    let powChannel = FlutterMethodChannel(
      name: "french_mobiles/power_button",
      binaryMessenger: messenger
    )
    powChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "startWatching":
        self.startWatchingPower()
        result(true)
      case "stopWatching":
        self.stopWatchingPower()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.powerChannel = powChannel

    // 7. Internet cellular & Wi-Fi probe channel (`french_mobiles/internet`)
    let netChannel = FlutterMethodChannel(
      name: "french_mobiles/internet",
      binaryMessenger: messenger
    )
    netChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "probeCellular":
        self.probeInterface(.cellular, result: result)
      case "probeWifi":
        self.probeInterface(.wifi, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.internetChannel = netChannel

    // 8. SIM data channel (`com.vincentkammerer.sim_data/channel_name`)
    let simChannel = FlutterMethodChannel(
      name: "com.vincentkammerer.sim_data/channel_name",
      binaryMessenger: messenger
    )
    simChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "getSimData" {
        self.readSimData(result: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    self.simDataChannel = simChannel

    // 9. Biometric Diagnostic channels (`fingerprint_test/methods` & `fingerprint_test/events`)
    let fpMethods = FlutterMethodChannel(
      name: "fingerprint_test/methods",
      binaryMessenger: messenger
    )
    fpMethods.setMethodCallHandler { [weak self] call, result in
      self?.handleBiometricMethodCall(call, result: result)
    }
    self.fingerprintMethodChannel = fpMethods

    let fpEvents = FlutterEventChannel(
      name: "fingerprint_test/events",
      binaryMessenger: messenger
    )
    fpEvents.setStreamHandler(self)
    self.fingerprintEventChannel = fpEvents
  }

  // MARK: - 1. Volume Keys (`french_mobiles/volume_keys`)

  private func setVolumeListening(enabled: Bool) {
    listeningForVolumeKeys = enabled
    if !enabled {
      volumeObservation?.invalidate()
      volumeObservation = nil
      volumeView?.removeFromSuperview()
      volumeView = nil
      return
    }

    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.ambient, options: [.mixWithOthers])
    try? session.setActive(true)

    // Attach an offscreen MPVolumeView so iOS suppresses the system HUD while
    // testing the side buttons and allows recentering volume away from 0.0/1.0.
    if volumeView == nil, let keyWindow = activeWindow() {
      let vv = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
      vv.alpha = 0.01
      keyWindow.addSubview(vv)
      volumeView = vv
    }

    var current = session.outputVolume
    if current <= 0.05 || current >= 0.95 {
      setSystemVolume(0.5)
      current = 0.5
    }
    lastVolume = current

    volumeObservation?.invalidate()
    volumeObservation = session.observe(\.outputVolume, options: [.new, .old]) { [weak self] _, change in
      guard let self = self, self.listeningForVolumeKeys else { return }
      if self.adjustingVolumeProgrammatically {
        self.adjustingVolumeProgrammatically = false
        return
      }
      guard let newVol = change.newValue else { return }
      let oldVol = change.oldValue ?? self.lastVolume
      let delta = newVol - oldVol
      guard abs(delta) > 0.001 else { return }

      let key = delta > 0 ? "volume_up" : "volume_down"
      self.lastVolume = newVol

      DispatchQueue.main.async {
        self.volumeChannel?.invokeMethod("volumeKey", arguments: ["key": key])
      }

      // Keep volume away from the 0.0 and 1.0 rails so consecutive presses in
      // the same direction still produce a KVO change.
      if newVol <= 0.06 || newVol >= 0.94 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
          self.setSystemVolume(0.5)
          self.lastVolume = 0.5
        }
      }
    }
  }

  private func setSystemVolume(_ value: Float) {
    guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
    adjustingVolumeProgrammatically = true
    slider.value = value
  }

  private func activeWindow() -> UIWindow? {
    for scene in UIApplication.shared.connectedScenes {
      if let windowScene = scene as? UIWindowScene {
        for w in windowScene.windows where w.isKeyWindow {
          return w
        }
        if let first = windowScene.windows.first {
          return first
        }
      }
    }
    return window
  }

  // MARK: - 2. Power / Side Button (`french_mobiles/power_button`)

  private func startWatchingPower() {
    guard !watchingPowerButton else { return }
    watchingPowerButton = true

    let center = NotificationCenter.default
    let resignObs = center.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.emitScreenEvent("screen_off")
    }
    let lockObs = center.addObserver(
      forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.emitScreenEvent("screen_off")
    }
    let wakeObs = center.addObserver(
      forName: UIApplication.protectedDataDidBecomeAvailableNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.emitScreenEvent("screen_on")
    }
    let activeObs = center.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.emitScreenEvent("user_present")
    }

    powerObservers = [resignObs, lockObs, wakeObs, activeObs]
  }

  private func stopWatchingPower() {
    watchingPowerButton = false
    let center = NotificationCenter.default
    for obs in powerObservers {
      center.removeObserver(obs)
    }
    powerObservers.removeAll()
  }

  private func emitScreenEvent(_ event: String) {
    guard watchingPowerButton else { return }
    powerChannel?.invokeMethod("screenEvent", arguments: ["event": event])
  }

  // MARK: - 3. Proximity Screen (`french_mobiles/proximity_screen`)

  private func isProximitySupported() -> Bool {
    let device = UIDevice.current
    let wasEnabled = device.isProximityMonitoringEnabled
    device.isProximityMonitoringEnabled = true
    let supported = device.isProximityMonitoringEnabled
    if !wasEnabled {
      device.isProximityMonitoringEnabled = false
    }
    return supported
  }

  private func enableProximityScreen() -> Bool {
    let device = UIDevice.current
    device.isProximityMonitoringEnabled = true
    return device.isProximityMonitoringEnabled
  }

  private func disableProximityScreen() {
    UIDevice.current.isProximityMonitoringEnabled = false
  }

  // MARK: - 4. Battery (`french_mobiles/battery`)

  private func readBattery() -> [String: Any?] {
    let device = UIDevice.current
    device.isBatteryMonitoringEnabled = true
    let state = device.batteryState
    let rawLevel = device.batteryLevel
    let level: Int? = rawLevel >= 0 ? Int((rawLevel * 100).rounded()) : nil
    let charging = state == .charging || state == .full
    let present = state != .unknown

    return [
      "present": present,
      "level": level,
      "charging": charging,
      "powerSource": charging ? "mains" : (present ? "battery" : "none"),
      "healthFlag": present ? "good" : "unknown",
      "technology": "Li-ion",
      "sdkInt": Int(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
      "temperatureCelsius": nil,
      "voltage": nil,
      "currentMicroAmps": nil,
      "cycleCount": nil,
      "capacityHealth": nil,
      "capacityFullMah": nil,
      "capacityDesignMah": nil,
      "capacitySource": nil,
      "capacityLevel": nil,
    ]
  }

  // MARK: - 5. Thermal (`french_mobiles/thermal`)

  private func readThermal() -> [String: Any?] {
    let state = ProcessInfo.processInfo.thermalState
    let status: String
    let headroom: Double
    switch state {
    case .nominal:
      status = "none"
      headroom = 0.20
    case .fair:
      status = "light"
      headroom = 0.65
    case .serious:
      status = "severe"
      headroom = 1.05
    case .critical:
      status = "critical"
      headroom = 1.25
    @unknown default:
      status = "unknown"
      headroom = 0.50
    }

    return [
      "status": status,
      "headroom": headroom,
      "sensors": [[String: Any]](),
    ]
  }

  // MARK: - 6. Internet Cellular & Wi-Fi Probe (`french_mobiles/internet`)

  private func probeInterface(_ interfaceType: NWInterface.InterfaceType, result: @escaping FlutterResult) {
    let noRouteStatus = interfaceType == .cellular ? "no_cellular" : "no_wifi"
    let monitor = NWPathMonitor(requiredInterfaceType: interfaceType)
    let queue = DispatchQueue(label: "french_mobiles.netprobe.\(interfaceType)")
    var settled = false
    let lock = NSLock()

    func finish(_ payload: [String: Any?]) {
      lock.lock()
      if settled {
        lock.unlock()
        return
      }
      settled = true
      lock.unlock()
      monitor.cancel()
      DispatchQueue.main.async {
        result(payload)
      }
    }

    monitor.pathUpdateHandler = { path in
      guard path.status == .satisfied else {
        finish(["status": noRouteStatus])
        return
      }
      monitor.cancel()
      self.performHttp204OverInterface(interfaceType, finish: finish)
    }
    monitor.start(queue: queue)

    queue.asyncAfter(deadline: .now() + 8.0) {
      finish(["status": noRouteStatus])
    }
  }

  private func performHttp204OverInterface(
    _ interfaceType: NWInterface.InterfaceType,
    finish: @escaping ([String: Any?]) -> Void
  ) {
    let params = NWParameters.tls
    params.requiredInterfaceType = interfaceType

    let host = NWEndpoint.Host("connectivitycheck.gstatic.com")
    let port = NWEndpoint.Port(rawValue: 443)!
    let connection = NWConnection(host: host, port: port, using: params)
    let queue = DispatchQueue(label: "french_mobiles.http204.\(interfaceType)")
    let startedAt = DispatchTime.now()

    var done = false
    let connLock = NSLock()
    func complete(_ dict: [String: Any?]) {
      connLock.lock()
      if done {
        connLock.unlock()
        return
      }
      done = true
      connLock.unlock()
      connection.cancel()
      finish(dict)
    }

    connection.stateUpdateHandler = { state in
      switch state {
      case .ready:
        let request =
          "GET /generate_204 HTTP/1.1\r\n" +
          "Host: connectivitycheck.gstatic.com\r\n" +
          "User-Agent: FrenchMobilesCheckup/1.0\r\n" +
          "Connection: close\r\n\r\n"
        connection.send(content: request.data(using: .utf8), completion: .contentProcessed { sendError in
          if let sendError = sendError {
            complete(["status": "unreachable", "message": sendError.localizedDescription])
            return
          }
          connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, recvError in
            let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000)
            if let recvError = recvError, data == nil {
              complete(["status": "unreachable", "message": recvError.localizedDescription])
              return
            }
            guard let data = data,
                  let header = String(data: data, encoding: .utf8),
                  let firstLine = header.components(separatedBy: "\r\n").first else {
              complete(["status": "unreachable", "message": "Empty response"])
              return
            }
            // Parse "HTTP/1.1 204 No Content"
            let parts = firstLine.split(separator: " ")
            if parts.count >= 2, let code = Int(parts[1]) {
              if code == 204 {
                complete(["status": "ok", "code": 204, "ms": elapsedMs])
              } else {
                complete(["status": "captive", "code": code, "ms": elapsedMs])
              }
            } else {
              complete(["status": "unreachable", "message": firstLine])
            }
          }
        })
      case .failed(let error):
        complete(["status": "unreachable", "message": error.localizedDescription])
      default:
        break
      }
    }

    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + 7.0) {
      complete(["status": "unreachable", "message": "Timed out"])
    }
  }

  // MARK: - 7. SIM Data (`com.vincentkammerer.sim_data/channel_name`)

  private func readSimData(result: @escaping FlutterResult) {
    let telephony = CTTelephonyNetworkInfo()
    let radioDict = telephony.serviceCurrentRadioAccessTechnology ?? [:]
    let providers = telephony.serviceSubscriberCellularProviders ?? [:]

    var cards: [[String: Any]] = []
    var slotIndex = 0

    for (serviceId, carrier) in providers {
      let radio = radioDict[serviceId]
      let rawCarrierName = carrier.carrierName ?? ""
      let cleanCarrier = (rawCarrierName == "--" || rawCarrierName.isEmpty) ? "" : rawCarrierName
      let iso = carrier.isoCountryCode ?? ""
      let mcc = Int(carrier.mobileCountryCode ?? "") ?? 0
      let mnc = Int(carrier.mobileNetworkCode ?? "") ?? 0

      // On iOS 16+, CTCarrier properties may return "--", so an active radio
      // technology on the service slot also proves a SIM is active.
      if !cleanCarrier.isEmpty || radio != nil || mcc > 0 {
        let display = cleanCarrier.isEmpty ? (radio != nil ? "Cellular SIM" : "SIM") : cleanCarrier
        cards.append([
          "carrierName": display,
          "countryCode": iso,
          "displayName": display,
          "isDataRoaming": false,
          "isNetworkRoaming": false,
          "mcc": mcc,
          "mnc": mnc,
          "phoneNumber": "",
          "serialNumber": serviceId,
          "slotIndex": slotIndex,
          "subscriptionId": slotIndex,
        ])
        slotIndex += 1
      }
    }

    if cards.isEmpty, !radioDict.isEmpty {
      for (serviceId, radio) in radioDict {
        cards.append([
          "carrierName": "Cellular (\(radio.replacingOccurrences(of: "CTRadioAccessTechnology", with: "")))",
          "countryCode": "",
          "displayName": "Cellular SIM",
          "isDataRoaming": false,
          "isNetworkRoaming": false,
          "mcc": 0,
          "mnc": 0,
          "phoneNumber": "",
          "serialNumber": serviceId,
          "slotIndex": slotIndex,
          "subscriptionId": slotIndex,
        ])
        slotIndex += 1
      }
    }

    if !cards.isEmpty {
      respondWithSimCards(cards, result: result)
      return
    }

    // Fallback: check NWPathMonitor(.cellular) in case iOS redacted CoreTelephony
    // carrier fields on an active eSIM.
    let monitor = NWPathMonitor(requiredInterfaceType: .cellular)
    let queue = DispatchQueue(label: "french_mobiles.simcheck")
    var finished = false
    let lock = NSLock()

    func done(_ finalCards: [[String: Any]]) {
      lock.lock()
      if finished {
        lock.unlock()
        return
      }
      finished = true
      lock.unlock()
      monitor.cancel()
      DispatchQueue.main.async {
        self.respondWithSimCards(finalCards, result: result)
      }
    }

    monitor.pathUpdateHandler = { path in
      if path.status == .satisfied {
        done([[
          "carrierName": "Cellular SIM",
          "countryCode": "",
          "displayName": "Cellular SIM",
          "isDataRoaming": false,
          "isNetworkRoaming": false,
          "mcc": 0,
          "mnc": 0,
          "phoneNumber": "",
          "serialNumber": "esim-0",
          "slotIndex": 0,
          "subscriptionId": 0,
        ]])
      } else {
        done([])
      }
    }
    monitor.start(queue: queue)
    queue.asyncAfter(deadline: .now() + 1.5) {
      done([])
    }
  }

  private func respondWithSimCards(_ cards: [[String: Any]], result: @escaping FlutterResult) {
    let payload: [String: Any] = ["cards": cards]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
       let jsonString = String(data: data, encoding: .utf8) {
      result(jsonString)
    } else {
      result("{\"cards\":[]}")
    }
  }

  // MARK: - 8. Biometric Hardware Diagnostic (`fingerprint_test/methods` & `fingerprint_test/events`)

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  private func handleBiometricMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getStatus":
      result(getBiometricStatus())
    case "startAuth":
      startBiometricAuth(result: result)
    case "cancelAuth":
      cancelBiometricAuth(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func getBiometricStatus() -> [String: Any] {
    let context = LAContext()
    var authError: NSError?
    let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError)

    var hasHardware = true
    var hasEnrolled = canEvaluate

    if let error = authError {
      switch error.code {
      case LAError.biometryNotAvailable.rawValue:
        hasHardware = false
        hasEnrolled = false
      case LAError.biometryNotEnrolled.rawValue:
        hasHardware = true
        hasEnrolled = false
      case LAError.biometryLockout.rawValue:
        hasHardware = true
        hasEnrolled = true
      default:
        break
      }
    }

    if context.biometryType == .none && !canEvaluate {
      if let error = authError, error.code == LAError.biometryNotAvailable.rawValue {
        hasHardware = false
      }
    }

    let biometryName = biometryLabel(for: context.biometryType)

    return [
      "sdkInt": Int(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
      "supported": true,
      "permissionGranted": true,
      "hasHardware": hasHardware,
      "hasEnrolled": hasEnrolled,
      "ready": canEvaluate,
      "listening": isAuthenticating,
      "biometryType": biometryName,
    ]
  }

  private func startBiometricAuth(result: @escaping FlutterResult) {
    let status = getBiometricStatus()
    let ready = (status["ready"] as? Bool) ?? false

    let context = LAContext()
    var policyError: NSError?
    guard ready || context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &policyError) else {
      emitBiometricEvent(
        type: "precheck_failed",
        message: policyError?.localizedDescription ?? "Biometrics not ready. Check Face ID / Touch ID & Passcode in Settings.",
        extra: status
      )
      result(status)
      return
    }

    authContext?.invalidate()
    authContext = context
    isAuthenticating = true

    let biometryName = biometryLabel(for: context.biometryType)
    emitBiometricEvent(
      type: "listening_started",
      message: "Listening for \(biometryName)... Authenticate now."
    )

    context.evaluatePolicy(
      .deviceOwnerAuthenticationWithBiometrics,
      localizedReason: "Verify \(biometryName) sensor hardware for device evaluation"
    ) { [weak self] success, evaluateError in
      guard let self = self else { return }
      self.isAuthenticating = false

      if success {
        self.emitBiometricEvent(
          type: "auth_succeeded",
          message: "\(biometryName) verified!"
        )
      } else if let error = evaluateError as NSError? {
        switch error.code {
        case LAError.userCancel.rawValue,
             LAError.systemCancel.rawValue,
             LAError.appCancel.rawValue:
          self.emitBiometricEvent(
            type: "listening_stopped",
            message: "\(biometryName) authentication cancelled."
          )
        case LAError.authenticationFailed.rawValue:
          self.emitBiometricEvent(
            type: "auth_failed",
            message: "\(biometryName) not recognized. Try again."
          )
        default:
          self.emitBiometricEvent(
            type: "auth_error",
            code: error.code,
            message: error.localizedDescription
          )
        }
      }
    }

    result(getBiometricStatus())
  }

  private func cancelBiometricAuth(result: @escaping FlutterResult) {
    authContext?.invalidate()
    authContext = nil
    if isAuthenticating {
      isAuthenticating = false
      emitBiometricEvent(type: "listening_stopped", message: "Stopped listening.")
    }
    result(getBiometricStatus())
  }

  private func biometryLabel(for type: LABiometryType) -> String {
    switch type {
    case .faceID:
      return "Face ID"
    case .touchID:
      return "Touch ID"
    default:
      return "Biometrics"
    }
  }

  private func emitBiometricEvent(
    type: String,
    code: Int? = nil,
    message: String? = nil,
    extra: [String: Any]? = nil
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let sink = self?.eventSink else { return }
      var payload: [String: Any] = [
        "type": type,
        "timestamp": Int(Date().timeIntervalSince1970 * 1000),
      ]
      if let code = code { payload["code"] = code }
      if let message = message { payload["message"] = message }
      if let extra = extra { payload["extra"] = extra }
      sink(payload)
    }
  }
}
