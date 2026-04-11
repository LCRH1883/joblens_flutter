import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NativeCameraPlugin") {
      NativeCameraPlugin.shared.register(with: registrar)
    }
  }
}

final class NativeCameraPlugin: NSObject, FlutterStreamHandler {
  static let shared = NativeCameraPlugin()

  private let methodChannelName = "com.intagri.joblens/native_camera"
  private let eventChannelName = "com.intagri.joblens/native_camera/events"
  private var eventSink: FlutterEventSink?

  func register(with registrar: FlutterPluginRegistrar) {
    let methodChannel = FlutterMethodChannel(
      name: methodChannelName,
      binaryMessenger: registrar.messenger()
    )
    let eventChannel = FlutterEventChannel(
      name: eventChannelName,
      binaryMessenger: registrar.messenger()
    )
    eventChannel.setStreamHandler(self)

    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "unavailable", message: "Native camera plugin unavailable.", details: nil))
        return
      }
      switch call.method {
      case "openCamera":
        guard let payload = call.arguments as? String else {
          result(
            FlutterError(
              code: "invalid_arguments",
              message: "Camera payload was missing.",
              details: nil
            )
          )
          return
        }
        do {
          let config = try NativeCameraLaunchConfig(payload: payload)
          presentCamera(with: config)
          result(nil)
        } catch {
          result(
            FlutterError(
              code: "invalid_payload",
              message: "Unable to parse camera payload.",
              details: error.localizedDescription
            )
          )
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func emit(_ event: [String: Any?]) {
    eventSink?(event.compactMapValues { $0 })
  }

  private func presentCamera(with config: NativeCameraLaunchConfig) {
    guard let presenter = topViewController() else { return }
    let controller = NativeCameraViewController(config: config, eventEmitter: emit(_:))
    controller.modalPresentationStyle = .fullScreen
    presenter.present(controller, animated: true)
  }

  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap(\.windows)
    let root = windows.first(where: \.isKeyWindow)?.rootViewController
    var top = root
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}

private final class NativeCameraViewController: UIViewController, AVCapturePhotoCaptureDelegate {
  private let config: NativeCameraLaunchConfig
  private let emitEvent: ([String: Any?]) -> Void
  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "com.intagri.joblens.nativecamera.session")
  private let photoOutput = AVCapturePhotoOutput()
  private let previewLayer = AVCaptureVideoPreviewLayer()
  private let captureFeedbackGenerator = UIImpactFeedbackGenerator(style: .light)
  private let previewContainerView = UIView()
  private let feedbackOverlayView = UIView()
  private let controlsOverlayView = UIView()

  private var currentInput: AVCaptureDeviceInput?
  private var currentTarget: NativeCameraTargetOption
  private var currentPosition: AVCaptureDevice.Position
  private var currentFlashMode: AVCaptureDevice.FlashMode
  private var currentZoomFactor: CGFloat
  private var captureInFlight = false
  private var capturedCount = 0
  private var openedAt = CACurrentMediaTime()
  private var previewReadySent = false
  private var pendingCaptureStart: CFTimeInterval?
  private var pendingPhotoId: String?
  private var targetButton = UIButton(type: .system)
  private var flashButton = UIButton(type: .system)
  private var lensButton = UIButton(type: .system)
  private var shutterButton = UIButton(type: .system)
  private var flashOverlayView = UIView()
  private var countLabel = InsetLabel()
  private var zoomButtons: [UIButton] = []
  private var zoomStack = UIStackView()

  init(config: NativeCameraLaunchConfig, eventEmitter: @escaping ([String: Any?]) -> Void) {
    self.config = config
    self.emitEvent = eventEmitter
    self.currentTarget = config.resolveCurrentTarget()
    self.currentPosition = config.settings.lensPosition
    self.currentFlashMode = config.settings.flashMode
    self.currentZoomFactor = max(config.settings.zoomStop, 1)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    definesPresentationContext = true
    configureUI()
    updateTargetButton()
    updateFlashButton()
    updateLensButton()
    updateCountLabel()
    captureFeedbackGenerator.prepare()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    authorizeAndStart()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer.frame = previewContainerView.bounds
    view.bringSubviewToFront(feedbackOverlayView)
    view.bringSubviewToFront(controlsOverlayView)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || navigationController?.isBeingDismissed == true {
      sessionQueue.async { [weak self] in
        self?.session.stopRunning()
      }
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func configureUI() {
    previewLayer.videoGravity = .resizeAspectFill
    previewContainerView.translatesAutoresizingMaskIntoConstraints = false
    previewContainerView.backgroundColor = .black
    previewContainerView.layer.addSublayer(previewLayer)
    previewContainerView.isUserInteractionEnabled = false
    previewContainerView.layer.zPosition = 0

    feedbackOverlayView.translatesAutoresizingMaskIntoConstraints = false
    feedbackOverlayView.backgroundColor = .clear
    feedbackOverlayView.isUserInteractionEnabled = false
    feedbackOverlayView.layer.zPosition = 1

    controlsOverlayView.translatesAutoresizingMaskIntoConstraints = false
    controlsOverlayView.backgroundColor = .clear
    controlsOverlayView.isUserInteractionEnabled = true
    controlsOverlayView.layer.zPosition = 2

    flashOverlayView.translatesAutoresizingMaskIntoConstraints = false
    flashOverlayView.backgroundColor = .white
    flashOverlayView.alpha = 0
    flashOverlayView.isUserInteractionEnabled = false

    let backButton = makeCircleIconButton(symbolName: "xmark", action: #selector(closeSession))
    targetButton = makeTargetButton(title: "Inbox", action: #selector(showTargetPicker))
    flashButton = makeCircleIconButton(symbolName: "bolt.slash", action: #selector(cycleFlashMode))
    lensButton = makeCircleIconButton(symbolName: "camera.rotate", action: #selector(switchLens))

    let rightStack = UIStackView(arrangedSubviews: [flashButton, lensButton])
    rightStack.axis = .horizontal
    rightStack.alignment = .center
    rightStack.spacing = 12
    rightStack.translatesAutoresizingMaskIntoConstraints = false

    zoomStack = UIStackView()
    zoomStack.axis = .horizontal
    zoomStack.alignment = .center
    zoomStack.distribution = .fill
    zoomStack.spacing = 6
    zoomStack.translatesAutoresizingMaskIntoConstraints = false

    countLabel.translatesAutoresizingMaskIntoConstraints = false
    countLabel.textColor = .white
    countLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    countLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
    countLabel.layer.cornerRadius = 20
    countLabel.layer.masksToBounds = true
    countLabel.textAlignment = .center
    countLabel.isHidden = true
    countLabel.textInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

    shutterButton = UIButton(type: .custom)
    shutterButton.translatesAutoresizingMaskIntoConstraints = false
    shutterButton.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    shutterButton.layer.cornerRadius = 44
    shutterButton.layer.borderWidth = 3
    shutterButton.layer.borderColor = UIColor.white.cgColor
    shutterButton.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)
    let shutterInner = UIView()
    shutterInner.translatesAutoresizingMaskIntoConstraints = false
    shutterInner.backgroundColor = .white
    shutterInner.layer.cornerRadius = 32
    shutterButton.addSubview(shutterInner)

    view.addSubview(previewContainerView)
    view.addSubview(feedbackOverlayView)
    view.addSubview(controlsOverlayView)
    feedbackOverlayView.addSubview(flashOverlayView)
    controlsOverlayView.addSubview(backButton)
    controlsOverlayView.addSubview(targetButton)
    controlsOverlayView.addSubview(rightStack)
    controlsOverlayView.addSubview(zoomStack)
    controlsOverlayView.addSubview(countLabel)
    controlsOverlayView.addSubview(shutterButton)

    let guide = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      previewContainerView.topAnchor.constraint(equalTo: view.topAnchor),
      previewContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      previewContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      previewContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      feedbackOverlayView.topAnchor.constraint(equalTo: view.topAnchor),
      feedbackOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      feedbackOverlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      feedbackOverlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      controlsOverlayView.topAnchor.constraint(equalTo: view.topAnchor),
      controlsOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      controlsOverlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      controlsOverlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      flashOverlayView.topAnchor.constraint(equalTo: feedbackOverlayView.topAnchor),
      flashOverlayView.leadingAnchor.constraint(equalTo: feedbackOverlayView.leadingAnchor),
      flashOverlayView.trailingAnchor.constraint(equalTo: feedbackOverlayView.trailingAnchor),
      flashOverlayView.bottomAnchor.constraint(equalTo: feedbackOverlayView.bottomAnchor),
      backButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
      backButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
      backButton.widthAnchor.constraint(equalToConstant: 48),
      backButton.heightAnchor.constraint(equalToConstant: 48),
      targetButton.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
      targetButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
      targetButton.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 16),
      targetButton.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -16),
      targetButton.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
      rightStack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
      rightStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
      flashButton.widthAnchor.constraint(equalToConstant: 48),
      flashButton.heightAnchor.constraint(equalToConstant: 48),
      lensButton.widthAnchor.constraint(equalToConstant: 48),
      lensButton.heightAnchor.constraint(equalToConstant: 48),
      zoomStack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
      zoomStack.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 24),
      zoomStack.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -24),
      zoomStack.bottomAnchor.constraint(equalTo: shutterButton.topAnchor, constant: -20),
      countLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
      countLabel.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
      countLabel.trailingAnchor.constraint(lessThanOrEqualTo: shutterButton.leadingAnchor, constant: -16),
      shutterButton.widthAnchor.constraint(equalToConstant: 88),
      shutterButton.heightAnchor.constraint(equalToConstant: 88),
      shutterInner.widthAnchor.constraint(equalToConstant: 64),
      shutterInner.heightAnchor.constraint(equalToConstant: 64),
      shutterInner.centerXAnchor.constraint(equalTo: shutterButton.centerXAnchor),
      shutterInner.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
      shutterButton.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
      shutterButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16)
    ])
  }

  private func authorizeAndStart() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      configureSession()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        guard let self else { return }
        if granted {
          self.configureSession()
        } else {
          DispatchQueue.main.async {
            self.emitFailure("Camera permission is required to capture photos.")
            self.closeSession()
          }
        }
      }
    default:
      emitFailure("Camera permission is required to capture photos.")
      closeSession()
    }
  }

  private func configureSession() {
    log("configure_session_start", data: [
      "position": currentPosition.flutterName,
      "zoom": currentZoomFactor,
      "flash": currentFlashMode.flutterName,
    ])
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.session.beginConfiguration()
      self.session.sessionPreset = .photo
      self.session.inputs.forEach { self.session.removeInput($0) }
      self.session.outputs.forEach { self.session.removeOutput($0) }

      guard let device = self.bestDevice(for: self.currentPosition) else {
        DispatchQueue.main.async {
          self.log("configure_session_no_device", data: [
            "position": self.currentPosition.flutterName,
          ])
          self.emitFailure("No compatible camera was found on this device.")
          self.closeSession()
        }
        self.session.commitConfiguration()
        return
      }

      do {
        let input = try AVCaptureDeviceInput(device: device)
        if self.session.canAddInput(input) {
          self.session.addInput(input)
          self.currentInput = input
        }
        if self.session.canAddOutput(self.photoOutput) {
          self.session.addOutput(self.photoOutput)
        }
        if #available(iOS 13.0, *) {
          self.photoOutput.maxPhotoQualityPrioritization = .speed
        }
        self.photoOutput.isHighResolutionCaptureEnabled = false
        self.photoOutput.isLivePhotoCaptureEnabled = false
        self.applyZoomLocked(device: device, zoom: self.currentZoomFactor)
        self.session.commitConfiguration()
        self.previewLayer.session = self.session
        self.session.startRunning()
        DispatchQueue.main.async {
          self.log("configure_session_ready", data: [
            "device": device.localizedName,
            "position": self.currentPosition.flutterName,
            "zoom": self.currentZoomFactor,
          ])
          self.lensButton.isEnabled = true
          self.refreshZoomButtons(for: device)
          self.updateFlashButton()
          self.updateLensButton()
          if !self.previewReadySent {
            self.previewReadySent = true
            self.emitEvent(
              self.sessionEvent(
                type: "previewReady",
                openDurationMs: Int((CACurrentMediaTime() - self.openedAt) * 1000)
              )
            )
          }
        }
      } catch {
        self.session.commitConfiguration()
        DispatchQueue.main.async {
          self.log("configure_session_error", data: [
            "message": error.localizedDescription,
          ])
          self.emitFailure("Unable to configure camera: \(error.localizedDescription)")
          self.closeSession()
        }
      }
    }
  }

  private func bestDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
    let deviceTypes: [AVCaptureDevice.DeviceType]
    if position == .back {
      deviceTypes = [
        .builtInTripleCamera,
        .builtInDualWideCamera,
        .builtInDualCamera,
        .builtInUltraWideCamera,
        .builtInTelephotoCamera,
        .builtInWideAngleCamera,
      ]
    } else {
      deviceTypes = [
        .builtInTrueDepthCamera,
        .builtInWideAngleCamera,
      ]
    }
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: deviceTypes,
      mediaType: .video,
      position: position
    )
    for type in deviceTypes {
      if let device = discovery.devices.first(where: { $0.deviceType == type }) {
        return device
      }
    }
    return discovery.devices.first
  }

  private func refreshZoomButtons(for device: AVCaptureDevice) {
    zoomButtons.forEach { $0.removeFromSuperview() }
    zoomButtons.removeAll()
    let stops = meaningfulZoomStops(for: device)
    zoomStack.isHidden = stops.count <= 1
    for stop in stops {
      let button = makeZoomPillButton(title: "\(formatZoom(stop))x", action: #selector(handleZoomButton(_:)))
      button.accessibilityIdentifier = "\(stop)"
      setSelectedStyle(for: button, selected: abs(stop - currentZoomFactor) < 0.05)
      zoomButtons.append(button)
      zoomStack.addArrangedSubview(button)
    }
    log("zoom_buttons_refreshed", data: [
      "position": currentPosition.flutterName,
      "stops": stops.map { formatZoom($0) }.joined(separator: ","),
    ])
  }

  private func meaningfulZoomStops(for device: AVCaptureDevice) -> [CGFloat] {
    let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 6)
    var stops: [CGFloat] = [1]
    if currentPosition == .back {
      if #available(iOS 13.0, *) {
        for factor in device.virtualDeviceSwitchOverVideoZoomFactors {
          let stop = max(1, min(CGFloat(truncating: factor), maxZoom))
          if stop > 1.05, !stops.contains(where: { abs($0 - stop) < 0.05 }) {
            stops.append(stop)
          }
        }
      }
    }
    let sorted = stops.sorted()
    return sorted.isEmpty ? [1] : sorted
  }

  private func applyZoomLocked(device: AVCaptureDevice, zoom: CGFloat) {
    let clamped = max(1, min(zoom, device.activeFormat.videoMaxZoomFactor))
    do {
      try device.lockForConfiguration()
      device.videoZoomFactor = clamped
      device.unlockForConfiguration()
      currentZoomFactor = clamped
    } catch {
      log("zoom_apply_failed", data: [
        "requestedZoom": zoom,
        "message": error.localizedDescription,
      ])
      currentZoomFactor = 1
    }
  }

  private func applyZoom(_ zoom: CGFloat) {
    guard let device = currentInput?.device else { return }
    sessionQueue.async { [weak self] in
      self?.applyZoomLocked(device: device, zoom: zoom)
      DispatchQueue.main.async {
        self?.log("zoom_applied", data: ["zoom": self?.currentZoomFactor ?? 1])
        self?.zoomButtons.forEach { button in
          let value = CGFloat(Double(button.accessibilityIdentifier ?? "1") ?? 1)
          self?.setSelectedStyle(for: button, selected: abs(value - (self?.currentZoomFactor ?? 1)) < 0.05)
        }
      }
    }
  }

  @objc private func handleZoomButton(_ sender: UIButton) {
    let value = CGFloat(Double(sender.accessibilityIdentifier ?? "1") ?? 1)
    log("zoom_tapped", data: ["requestedZoom": value])
    applyZoom(value)
  }

  @objc private func cycleFlashMode() {
    guard let device = currentInput?.device, device.hasFlash else {
      flashButton.isEnabled = false
      log("flash_unavailable")
      return
    }
    currentFlashMode = switch currentFlashMode {
    case .off: .auto
    case .auto: .on
    default: .off
    }
    log("flash_changed", data: ["flash": currentFlashMode.flutterName])
    updateFlashButton()
  }

  @objc private func switchLens() {
    guard lensButton.isEnabled else { return }
    log("lens_switch_tapped", data: ["from": currentPosition.flutterName])
    lensButton.isEnabled = false
    currentPosition = currentPosition == .back ? .front : .back
    configureSession()
  }

  @objc private func showTargetPicker() {
    log("target_picker_opened", data: [
      "targetProjectId": currentTarget.resolvedProjectId,
      "targetProjectName": currentTarget.resolvedProjectName,
    ])
    let selector = TargetSelectionViewController(
      targets: config.targets,
      currentTarget: currentTarget
    ) { [weak self] option in
      guard let self else { return }
      self.currentTarget = option
      self.log("target_changed", data: [
        "targetProjectId": option.resolvedProjectId,
        "targetProjectName": option.resolvedProjectName,
      ])
      self.updateTargetButton()
      self.emitEvent(
        self.sessionEvent(
          type: "targetChanged",
          targetMode: option.mode.storageValue,
          targetProjectId: option.resolvedProjectId,
          targetProjectName: option.resolvedProjectName,
          fixedProjectId: option.fixedProjectId
        )
      )
    }
    selector.modalPresentationStyle = .overCurrentContext
    selector.modalTransitionStyle = .crossDissolve
    present(selector, animated: true)
  }

  @objc private func capturePhoto() {
    guard !captureInFlight else { return }
    guard currentInput != nil else {
      emitFailure("Camera is not ready yet.")
      return
    }
    let target = currentTarget
    captureInFlight = true
    shutterButton.isEnabled = false
    log("capture_tapped", data: [
      "targetProjectId": target.resolvedProjectId,
      "targetProjectName": target.resolvedProjectName,
      "flash": currentFlashMode.flutterName,
      "position": currentPosition.flutterName,
    ])
    animateShutterPress()
    let photoId = UUID().uuidString
    pendingPhotoId = photoId
    pendingCaptureStart = CACurrentMediaTime()
    let settings: AVCapturePhotoSettings
    if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
      settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
    } else {
      settings = AVCapturePhotoSettings()
    }
    if photoOutput.supportedFlashModes.contains(currentFlashMode) {
      settings.flashMode = currentFlashMode
    }
    if #available(iOS 13.0, *) {
      settings.photoQualityPrioritization = .speed
    }
    settings.isHighResolutionPhotoEnabled = false
    settings.isAutoStillImageStabilizationEnabled = true
    if let connection = photoOutput.connection(with: .video),
      connection.isVideoOrientationSupported
    {
      connection.videoOrientation = .portrait
    }
    emitEvent(
      sessionEvent(
        type: "captureStarted",
        photoId: photoId,
        targetMode: target.mode.storageValue,
        targetProjectId: target.resolvedProjectId,
        targetProjectName: target.resolvedProjectName,
        fixedProjectId: target.fixedProjectId
      )
    )
    photoOutput.capturePhoto(with: settings, delegate: self)
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    defer {
      captureInFlight = false
      DispatchQueue.main.async {
        self.shutterButton.isEnabled = true
      }
    }

    if let error {
      DispatchQueue.main.async {
        self.emitFailure("Capture failed: \(error.localizedDescription)")
      }
      return
    }

    guard
      let data = photo.fileDataRepresentation(),
      let photoId = pendingPhotoId
    else {
      DispatchQueue.main.async {
        self.emitFailure("Capture failed before photo data was available.")
      }
      return
    }
    let target = currentTarget

    do {
      let fileURL = try createOutputURL(photoId: photoId)
      try data.write(to: fileURL, options: .atomic)
      let durationMs = pendingCaptureStart.map { Int((CACurrentMediaTime() - $0) * 1000) }
      DispatchQueue.main.async {
        self.capturedCount += 1
        self.updateCountLabel()
        self.playCaptureSuccessFeedback()
        self.log("capture_saved", data: [
          "photoId": photoId,
          "captureDurationMs": durationMs ?? -1,
          "capturedCount": self.capturedCount,
        ])
        self.emitEvent(
          self.sessionEvent(
            type: "captureSaved",
            photoId: photoId,
            localPath: fileURL.path,
            targetMode: target.mode.storageValue,
            targetProjectId: target.resolvedProjectId,
            targetProjectName: target.resolvedProjectName,
            fixedProjectId: target.fixedProjectId,
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            captureDurationMs: durationMs
          )
        )
      }
    } catch {
      DispatchQueue.main.async {
        self.emitFailure("Unable to save photo locally: \(error.localizedDescription)")
      }
    }
  }

  @objc private func closeSession() {
    log("session_closed", data: ["capturedCount": capturedCount])
    emitEvent(
      sessionEvent(
        type: "sessionClosed",
        capturedCount: capturedCount,
        settings: [
          "flashMode": currentFlashMode.flutterName,
          "lensDirection": currentPosition.flutterName,
          "zoomStop": currentZoomFactor
        ]
      )
    )
    dismiss(animated: true)
  }

  @objc private func handleWillResignActive() {
    log("app_will_resign_active")
    sessionQueue.async { [weak self] in
      self?.session.stopRunning()
    }
  }

  @objc private func handleDidBecomeActive() {
    log("app_did_become_active")
    sessionQueue.async { [weak self] in
      guard let self, !self.session.isRunning else { return }
      self.session.startRunning()
    }
  }

  private func updateTargetButton() {
    targetButton.setImage(UIImage(systemName: "folder"), for: .normal)
    targetButton.setTitle(" \(currentTarget.resolvedProjectName) ▾", for: .normal)
  }

  private func updateFlashButton() {
    let hasFlash = currentInput?.device.hasFlash == true
    flashButton.isHidden = !hasFlash
    guard hasFlash else { return }
    let symbolName = switch currentFlashMode {
    case .auto: "bolt.badge.a"
    case .on: "bolt.fill"
    default: "bolt.slash"
    }
    flashButton.setImage(UIImage(systemName: symbolName), for: .normal)
    flashButton.accessibilityLabel = currentFlashMode.label
    setSelectedStyle(for: flashButton, selected: currentFlashMode != .off)
  }

  private func updateLensButton() {
    let canSwitch = bestDevice(for: currentPosition == .front ? .back : .front) != nil
    lensButton.isHidden = !canSwitch
    lensButton.isEnabled = canSwitch
    lensButton.setImage(UIImage(systemName: "camera.rotate"), for: .normal)
    lensButton.accessibilityLabel = currentPosition == .front ? "Front camera" : "Rear camera"
    setSelectedStyle(for: lensButton, selected: currentPosition == .front)
  }

  private func updateCountLabel() {
    countLabel.isHidden = capturedCount == 0
    countLabel.text = "\(capturedCount) saved"
  }

  private func animateShutterPress() {
    shutterButton.layer.removeAllAnimations()
    UIView.animate(withDuration: 0.06, animations: {
      self.shutterButton.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
      self.shutterButton.alpha = 0.88
    }) { _ in
      UIView.animate(withDuration: 0.09) {
        self.shutterButton.transform = .identity
        self.shutterButton.alpha = 1
      }
    }
  }

  private func playCaptureSuccessFeedback() {
    captureFeedbackGenerator.impactOccurred()
    captureFeedbackGenerator.prepare()

    flashOverlayView.layer.removeAllAnimations()
    flashOverlayView.alpha = 0
    UIView.animate(withDuration: 0.045, animations: {
      self.flashOverlayView.alpha = 0.18
    }) { _ in
      UIView.animate(withDuration: 0.11) {
        self.flashOverlayView.alpha = 0
      }
    }

    countLabel.layer.removeAllAnimations()
    countLabel.transform = .identity
    countLabel.alpha = 1
    UIView.animate(withDuration: 0.09, animations: {
      self.countLabel.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
      self.countLabel.alpha = 0.95
    }) { _ in
      UIView.animate(withDuration: 0.14) {
        self.countLabel.transform = .identity
        self.countLabel.alpha = 1
      }
    }
  }

  private func makeTextPillButton(title: String, action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle(title, for: .normal)
    button.setTitleColor(.white, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
    button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
    button.layer.cornerRadius = 18
    button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
    button.addTarget(self, action: action, for: .touchUpInside)
    return button
  }

  private func makeZoomPillButton(title: String, action: Selector) -> UIButton {
    let button = makeTextPillButton(title: title, action: action)
    button.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
    button.contentEdgeInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
    button.layer.cornerRadius = 10
    button.titleLabel?.adjustsFontSizeToFitWidth = false
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    return button
  }

  private func makeTargetButton(title: String, action: Selector) -> UIButton {
    let button = makeTextPillButton(title: title, action: action)
    button.semanticContentAttribute = .forceLeftToRight
    button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
    button.titleLabel?.lineBreakMode = .byTruncatingTail
    return button
  }

  private func makeCircleIconButton(symbolName: String, action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setImage(UIImage(systemName: symbolName), for: .normal)
    button.tintColor = .white
    button.backgroundColor = UIColor.black.withAlphaComponent(0.55)
    button.layer.cornerRadius = 24
    button.layer.borderWidth = 1
    button.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
    button.addTarget(self, action: action, for: .touchUpInside)
    return button
  }

  private func setSelectedStyle(for button: UIButton, selected: Bool) {
    button.backgroundColor = selected
      ? UIColor.white.withAlphaComponent(0.95)
      : UIColor.black.withAlphaComponent(0.55)
    button.setTitleColor(selected ? .black : .white, for: .normal)
    button.tintColor = selected ? .black : .white
    button.layer.borderWidth = 1
    button.layer.borderColor = (selected ? UIColor.white : UIColor.white.withAlphaComponent(0.35)).cgColor
  }

  private func emitFailure(_ message: String) {
    log("capture_failure", data: ["message": message])
    emitEvent(sessionEvent(type: "captureFailed", message: message))
  }

  private func log(_ event: String, data: [String: Any?] = [:]) {
    let normalizedData = data
      .compactMapValues { value -> String? in
        guard let value else { return nil }
        return String(describing: value)
      }
      .map { "\($0.key)=\($0.value)" }
      .sorted()
      .joined(separator: " ")
    if normalizedData.isEmpty {
      NSLog("[JoblensNativeCamera][iOS] %@", event)
    } else {
      NSLog("[JoblensNativeCamera][iOS] %@ %@", event, normalizedData)
    }
  }

  private func createOutputURL(photoId: String) throws -> URL {
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let sessionDirectory = applicationSupport
      .appendingPathComponent("captures", isDirectory: true)
      .appendingPathComponent(config.sessionId, isDirectory: true)
    try FileManager.default.createDirectory(
      at: sessionDirectory,
      withIntermediateDirectories: true
    )
    return sessionDirectory.appendingPathComponent("\(photoId).jpg")
  }

  private func sessionEvent(
    type: String,
    message: String? = nil,
    photoId: String? = nil,
    localPath: String? = nil,
    targetMode: String? = nil,
    targetProjectId: Int? = nil,
    targetProjectName: String? = nil,
    fixedProjectId: Int? = nil,
    capturedAt: String? = nil,
    openDurationMs: Int? = nil,
    captureDurationMs: Int? = nil,
    capturedCount: Int? = nil,
    settings: [String: Any]? = nil
  ) -> [String: Any?] {
    [
      "type": type,
      "sessionId": config.sessionId,
      "message": message,
      "photoId": photoId,
      "localPath": localPath,
      "targetMode": targetMode,
      "targetProjectId": targetProjectId,
      "targetProjectName": targetProjectName,
      "fixedProjectId": fixedProjectId,
      "capturedAt": capturedAt,
      "openDurationMs": openDurationMs,
      "captureDurationMs": captureDurationMs,
      "capturedCount": capturedCount,
      "settings": settings
    ]
  }

  private func formatZoom(_ zoom: CGFloat) -> String {
    let rounded = round(zoom)
    if abs(rounded - zoom) < 0.05 {
      return "\(Int(rounded))"
    }
    return String(format: "%.1f", zoom)
  }
}

private final class TargetSelectionViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
  private let targets: [NativeCameraTargetOption]
  private var currentTarget: NativeCameraTargetOption
  private let onSelect: (NativeCameraTargetOption) -> Void
  private var query = ""
  private let backdropButton = UIButton(type: .custom)
  private let containerView = UIView()
  private let searchField = UITextField()
  private let tableView = UITableView(frame: .zero, style: .plain)

  init(
    targets: [NativeCameraTargetOption],
    currentTarget: NativeCameraTargetOption,
    onSelect: @escaping (NativeCameraTargetOption) -> Void
  ) {
    self.targets = targets
    self.currentTarget = currentTarget
    self.onSelect = onSelect
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    backdropButton.translatesAutoresizingMaskIntoConstraints = false
    backdropButton.backgroundColor = UIColor.black.withAlphaComponent(0.2)
    backdropButton.addTarget(self, action: #selector(closeSheet), for: .touchUpInside)

    containerView.translatesAutoresizingMaskIntoConstraints = false
    containerView.backgroundColor = UIColor(white: 0.1, alpha: 0.95)
    containerView.layer.cornerRadius = 22
    containerView.layer.borderWidth = 1
    containerView.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
    containerView.clipsToBounds = true

    searchField.translatesAutoresizingMaskIntoConstraints = false
    searchField.attributedPlaceholder = NSAttributedString(
      string: "Search projects",
      attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.55)]
    )
    searchField.textColor = .white
    searchField.tintColor = .white
    searchField.clearButtonMode = .whileEditing
    searchField.returnKeyType = .done
    searchField.autocorrectionType = .no
    searchField.autocapitalizationType = .none
    searchField.delegate = self
    searchField.backgroundColor = UIColor.black.withAlphaComponent(0.32)
    searchField.layer.cornerRadius = 16
    searchField.layer.borderWidth = 1
    searchField.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
    searchField.leftView = UIImageView(
      image: UIImage(systemName: "magnifyingglass")?.withTintColor(
        UIColor.white.withAlphaComponent(0.75),
        renderingMode: .alwaysOriginal
      )
    ).wrappedWithPadding(horizontal: 12)
    searchField.leftViewMode = .always
    searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.backgroundColor = .clear
    tableView.separatorStyle = .none
    tableView.showsVerticalScrollIndicator = false
    tableView.keyboardDismissMode = .onDrag
    tableView.rowHeight = 52
    tableView.dataSource = self
    tableView.delegate = self

    view.addSubview(backdropButton)
    view.addSubview(containerView)
    containerView.addSubview(searchField)
    containerView.addSubview(tableView)

    let guide = view.safeAreaLayoutGuide
    let preferredWidth = containerView.widthAnchor.constraint(equalToConstant: 340)
    preferredWidth.priority = UILayoutPriority.defaultHigh
    NSLayoutConstraint.activate([
      backdropButton.topAnchor.constraint(equalTo: view.topAnchor),
      backdropButton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      backdropButton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      backdropButton.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      containerView.topAnchor.constraint(equalTo: guide.topAnchor, constant: 56),
      containerView.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
      containerView.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 16),
      containerView.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -16),
      preferredWidth,
      containerView.heightAnchor.constraint(lessThanOrEqualToConstant: 360),

      searchField.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
      searchField.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
      searchField.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
      searchField.heightAnchor.constraint(equalToConstant: 42),

      tableView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
      tableView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
      tableView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
      tableView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -8)
    ])
  }

  @objc private func closeSheet() {
    dismiss(animated: true)
  }

  @objc private func searchChanged() {
    query = searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    tableView.reloadData()
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    textField.resignFirstResponder()
    return true
  }

  private func selectProject(_ option: NativeCameraTargetOption) {
    currentTarget = option
    onSelect(option)
    dismiss(animated: true)
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    filteredTargets.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
    let option = filteredTargets[indexPath.row]
    let isSelected: Bool
    switch option.mode {
    case .inbox:
      isSelected = currentTarget.mode == .inbox
    case .fixedProject:
      isSelected = currentTarget.mode == .fixedProject &&
        currentTarget.fixedProjectId == option.fixedProjectId
    case .lastUsed:
      isSelected = false
    }

    cell.textLabel?.text = option.resolvedProjectName
    cell.textLabel?.textColor = isSelected ? .black : .white
    cell.textLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    cell.imageView?.image = UIImage(
      systemName: option.mode == .inbox ? "tray" : "folder"
    )?.withTintColor(
      isSelected ? .black : .white,
      renderingMode: .alwaysOriginal
    )
    cell.backgroundColor = .clear
    cell.contentView.backgroundColor = isSelected
      ? UIColor.white.withAlphaComponent(0.96)
      : UIColor.white.withAlphaComponent(0.04)
    cell.contentView.layer.cornerRadius = 14
    cell.contentView.layer.masksToBounds = true
    cell.tintColor = isSelected ? .black : .white
    cell.accessoryType = isSelected ? .checkmark : .none
    cell.selectionStyle = .none
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    selectProject(filteredTargets[indexPath.row])
  }

  private var inboxTarget: NativeCameraTargetOption? {
    targets.first(where: { $0.mode == .inbox })
  }

  private var projectTargets: [NativeCameraTargetOption] {
    targets
      .filter { $0.mode == .fixedProject }
      .sorted {
        $0.resolvedProjectName.localizedCaseInsensitiveCompare($1.resolvedProjectName) == .orderedAscending
      }
  }

  private var filteredTargets: [NativeCameraTargetOption] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var results: [NativeCameraTargetOption] = []
    if
      let inboxTarget,
      normalizedQuery.isEmpty ||
        "Inbox".localizedCaseInsensitiveContains(normalizedQuery) ||
        inboxTarget.resolvedProjectName.localizedCaseInsensitiveContains(normalizedQuery)
    {
      results.append(inboxTarget)
    }
    results.append(
      contentsOf: projectTargets.filter { option in
        normalizedQuery.isEmpty ||
          option.resolvedProjectName.localizedCaseInsensitiveContains(normalizedQuery)
      }
    )
    return results
  }
}

private final class InsetLabel: UILabel {
  var textInsets = UIEdgeInsets.zero

  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.inset(by: textInsets))
  }

  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(
      width: size.width + textInsets.left + textInsets.right,
      height: size.height + textInsets.top + textInsets.bottom
    )
  }
}

private extension UIView {
  func wrappedWithPadding(horizontal: CGFloat) -> UIView {
    let contentSize = intrinsicContentSize
    let width = max(contentSize.width, bounds.width) + horizontal * 2
    let height = max(contentSize.height, bounds.height, 20)
    let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: height))
    frame = CGRect(
      x: horizontal,
      y: (height - max(contentSize.height, bounds.height)) / 2,
      width: max(contentSize.width, bounds.width),
      height: max(contentSize.height, bounds.height)
    )
    container.addSubview(self)
    return container
  }
}

private struct NativeCameraLaunchConfig {
  let sessionId: String
  let currentMode: CaptureTargetMode
  let currentProjectId: Int
  let currentProjectName: String
  let targets: [NativeCameraTargetOption]
  let settings: NativeCameraSettings

  init(payload: String) throws {
    let data = Data(payload.utf8)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let json else {
      throw NSError(domain: "NativeCamera", code: 1)
    }
    sessionId = json["sessionId"] as? String ?? UUID().uuidString
    currentMode = CaptureTargetMode(storageValue: json["currentMode"] as? String)
    currentProjectId = json["currentProjectId"] as? Int ?? 0
    currentProjectName = json["currentProjectName"] as? String ?? "Inbox"
    let targetPayloads = json["targets"] as? [[String: Any]] ?? []
    targets = targetPayloads.map(NativeCameraTargetOption.init(json:))
    settings = NativeCameraSettings(json: json["settings"] as? [String: Any] ?? [:])
  }

  func resolveCurrentTarget() -> NativeCameraTargetOption {
    if let exact = targets.first(where: { option in
      switch currentMode {
      case .fixedProject, .lastUsed:
        return option.mode == .fixedProject && option.fixedProjectId == currentProjectId
      case .inbox:
        return option.mode == .inbox
      }
    }) {
      return exact
    }
    return targets.first ?? NativeCameraTargetOption(
      mode: .inbox,
      label: "Inbox",
      resolvedProjectId: currentProjectId,
      resolvedProjectName: currentProjectName,
      fixedProjectId: nil
    )
  }
}

private struct NativeCameraSettings {
  let flashMode: AVCaptureDevice.FlashMode
  let lensPosition: AVCaptureDevice.Position
  let zoomStop: CGFloat

  init(json: [String: Any]) {
    switch json["flashMode"] as? String {
    case "auto":
      flashMode = .auto
    case "always":
      flashMode = .on
    default:
      flashMode = .off
    }
    lensPosition = (json["lensDirection"] as? String) == "front" ? .front : .back
    zoomStop = CGFloat((json["zoomStop"] as? Double) ?? 1.0)
  }
}

private struct NativeCameraTargetOption {
  let mode: CaptureTargetMode
  let label: String
  let resolvedProjectId: Int
  let resolvedProjectName: String
  let fixedProjectId: Int?

  init(
    mode: CaptureTargetMode,
    label: String,
    resolvedProjectId: Int,
    resolvedProjectName: String,
    fixedProjectId: Int?
  ) {
    self.mode = mode
    self.label = label
    self.resolvedProjectId = resolvedProjectId
    self.resolvedProjectName = resolvedProjectName
    self.fixedProjectId = fixedProjectId
  }

  init(json: [String: Any]) {
    mode = CaptureTargetMode(storageValue: json["mode"] as? String)
    label = json["label"] as? String ?? ""
    resolvedProjectId = json["resolvedProjectId"] as? Int ?? 0
    resolvedProjectName = json["resolvedProjectName"] as? String ?? "Inbox"
    fixedProjectId = json["fixedProjectId"] as? Int
  }
}

private enum CaptureTargetMode: String {
  case inbox = "inbox"
  case lastUsed = "last_used"
  case fixedProject = "fixed_project"

  init(storageValue: String?) {
    self = CaptureTargetMode(rawValue: storageValue ?? "") ?? .inbox
  }

  var storageValue: String { rawValue }
}

private extension AVCaptureDevice.FlashMode {
  var flutterName: String {
    switch self {
    case .auto:
      return "auto"
    case .on:
      return "always"
    default:
      return "off"
    }
  }

  var label: String {
    switch self {
    case .auto:
      return "Flash Auto"
    case .on:
      return "Flash On"
    default:
      return "Flash Off"
    }
  }
}

private extension AVCaptureDevice.Position {
  var flutterName: String {
    self == .front ? "front" : "back"
  }
}
