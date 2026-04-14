import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = self.registrar(forPlugin: "JoblensNativeCameraPlugin") {
      NativeCameraBridgeCoordinator.shared.configure(
        messenger: registrar.messenger()
      )
    } else {
      NSLog("[JoblensCamera][iOS] Failed to acquire plugin registrar")
    }
    let didLaunch = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    return didLaunch
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // Plugins are already registered on the root engine in didFinishLaunching.
    // Re-registering here can crash with duplicate plugin keys on iOS.
  }
}

private final class NativeCameraBridgeCoordinator: NSObject, FlutterStreamHandler {
  static let shared = NativeCameraBridgeCoordinator()

  private let methodChannelName = "com.intagri.joblens/native_camera"
  private let eventChannelName = "com.intagri.joblens/native_camera/events"

  private var methodChannel: FlutterMethodChannel?
  private var eventChannel: FlutterEventChannel?
  private var eventSink: FlutterEventSink?
  private weak var cameraViewController: NativeCameraViewController?

  func configure(messenger: FlutterBinaryMessenger) {
    NSLog("[JoblensCamera][iOS] Configuring method and event channels")
    methodChannel?.setMethodCallHandler(nil)
    methodChannel = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
    methodChannel?.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }

    eventChannel = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
    eventChannel?.setStreamHandler(self)
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
    let filtered = event.compactMapValues { $0 }
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(filtered)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    NSLog("[JoblensCamera][iOS] Received method call: \(call.method)")
    switch call.method {
    case "openCamera":
      guard let payload = call.arguments as? String, !payload.isEmpty else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "Camera payload was missing.",
            details: nil
          )
        )
        return
      }

      let config: NativeCameraLaunchConfig
      do {
        config = try NativeCameraLaunchConfig.fromPayload(payload)
      } catch {
        result(
          FlutterError(
            code: "invalid_payload",
            message: "Unable to decode camera session payload.",
            details: error.localizedDescription
          )
        )
        return
      }

      DispatchQueue.main.async {
        guard self.cameraViewController == nil else {
          NSLog("[JoblensCamera][iOS] Camera already open")
          result(
            FlutterError(
              code: "camera_already_open",
              message: "A native camera session is already open.",
              details: nil
            )
          )
          return
        }

        guard let presenter = Self.topMostViewController() else {
          NSLog("[JoblensCamera][iOS] Presenter unavailable")
          result(
            FlutterError(
              code: "presenter_unavailable",
              message: "Unable to present the native camera.",
              details: nil
            )
          )
          return
        }

        let viewController = NativeCameraViewController(
          launchConfig: config,
          bridge: self
        )
        viewController.modalPresentationStyle = .fullScreen
        self.cameraViewController = viewController
        NSLog("[JoblensCamera][iOS] Presenting native camera")
        presenter.present(viewController, animated: true) {
          result(nil)
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func didCloseCamera(_ viewController: NativeCameraViewController) {
    if cameraViewController === viewController {
      cameraViewController = nil
    }
  }

  private static func topMostViewController(
    from root: UIViewController? = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)?
      .rootViewController
  ) -> UIViewController? {
    if let navigationController = root as? UINavigationController {
      return topMostViewController(from: navigationController.visibleViewController)
    }
    if let tabBarController = root as? UITabBarController {
      return topMostViewController(from: tabBarController.selectedViewController)
    }
    if let presentedViewController = root?.presentedViewController {
      return topMostViewController(from: presentedViewController)
    }
    return root
  }
}

private final class NativeCameraViewController: UIViewController {
  private static let maxSessionStartAttempts = 4

  private let launchConfig: NativeCameraLaunchConfig
  private weak var bridge: NativeCameraBridgeCoordinator?
  private let sessionQueue = DispatchQueue(label: "com.intagri.joblens.native_camera.session")
  private let captureSession = AVCaptureSession()
  private let previewLayer = AVCaptureVideoPreviewLayer()
  private let photoOutput = AVCapturePhotoOutput()

  private var currentTarget: NativeCameraTargetOption
  private var currentLensPosition: AVCaptureDevice.Position
  private var currentFlashMode: AVCaptureDevice.FlashMode
  private var currentZoomFactor: CGFloat
  private var capturedCount = 0
  private var openedAt = Date()
  private var previewReadySent = false
  private var isCaptureInFlight = false
  private var isSwitchingLens = false
  private var lensSwitchStartedAt: Date?
  private var didEmitSessionClosed = false
  private var isClosing = false
  private var currentInput: AVCaptureDeviceInput?
  private var captureDelegates: [String: NativePhotoCaptureDelegate] = [:]

  private let dimBackgroundView = UIView()
  private let topBar = UIView()
  private let bottomContainer = UIStackView()
  private let zoomStack = UIStackView()
  private let bottomRow = UIView()
  private let closeButton = UIButton(type: .system)
  private let targetButton = UIButton(type: .system)
  private let flashButton = UIButton(type: .system)
  private let lensButton = UIButton(type: .system)
  private let captureCountLabel = PaddingLabel()
  private let shutterButton = UIButton(type: .custom)
  private let shutterInnerCircle = UIView()
  private var zoomButtons: [UIButton] = []
  private var lifecycleObservers: [NSObjectProtocol] = []
  private var pendingSessionStartWorkItem: DispatchWorkItem?

  init(launchConfig: NativeCameraLaunchConfig, bridge: NativeCameraBridgeCoordinator) {
    self.launchConfig = launchConfig
    self.bridge = bridge
    self.currentTarget = launchConfig.resolveCurrentTarget()
    self.currentLensPosition = launchConfig.settings.lensPosition
    self.currentFlashMode = launchConfig.settings.flashMode
    self.currentZoomFactor = CGFloat(launchConfig.settings.zoomStop)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    openedAt = Date()
    configurePreview()
    configureChrome()
    configureLifecycleObservers()
    requestCameraAccessAndStart()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer.frame = view.bounds
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || navigationController?.isBeingDismissed == true {
      emitSessionClosedIfNeeded()
      bridge?.didCloseCamera(self)
    }
  }

  deinit {
    lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    sessionQueue.async { [captureSession] in
      captureSession.stopRunning()
    }
  }

  private func configurePreview() {
    previewLayer.session = captureSession
    previewLayer.videoGravity = .resizeAspectFill
    view.layer.addSublayer(previewLayer)
  }

  private func configureChrome() {
    dimBackgroundView.translatesAutoresizingMaskIntoConstraints = false
    dimBackgroundView.backgroundColor = .clear
    view.addSubview(dimBackgroundView)

    topBar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(topBar)

    bottomContainer.translatesAutoresizingMaskIntoConstraints = false
    bottomContainer.axis = .vertical
    bottomContainer.alignment = .center
    bottomContainer.spacing = 16
    view.addSubview(bottomContainer)

    configureTopBar()
    configureBottomControls()

    NSLayoutConstraint.activate([
      dimBackgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      dimBackgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      dimBackgroundView.topAnchor.constraint(equalTo: view.topAnchor),
      dimBackgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      topBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      topBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      topBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),

      bottomContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      bottomContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      bottomContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
    ])
  }

  private func configureTopBar() {
    let rightButtons = UIStackView(arrangedSubviews: [flashButton, lensButton])
    rightButtons.axis = .horizontal
    rightButtons.alignment = .center
    rightButtons.spacing = 12
    rightButtons.translatesAutoresizingMaskIntoConstraints = false
    topBar.addSubview(rightButtons)

    configureIconButton(
      closeButton,
      symbolName: "xmark",
      accessibilityLabel: "Close camera",
      action: #selector(closeTapped)
    )
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    topBar.addSubview(closeButton)

    configureTargetButton()
    topBar.addSubview(targetButton)

    configureIconButton(
      flashButton,
      symbolName: "bolt.slash",
      accessibilityLabel: "Flash off",
      action: #selector(flashTapped)
    )
    configureIconButton(
      lensButton,
      symbolName: "camera.rotate",
      accessibilityLabel: "Switch camera",
      action: #selector(lensTapped)
    )

    NSLayoutConstraint.activate([
      closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
      closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 48),
      closeButton.heightAnchor.constraint(equalToConstant: 48),

      rightButtons.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
      rightButtons.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

      targetButton.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
      targetButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
      targetButton.widthAnchor.constraint(lessThanOrEqualTo: topBar.widthAnchor, multiplier: 0.6),
      targetButton.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 12),
      targetButton.trailingAnchor.constraint(lessThanOrEqualTo: rightButtons.leadingAnchor, constant: -12),
    ])

    updateTargetButton()
    updateFlashButton()
    updateLensButton()
  }

  private func configureBottomControls() {
    zoomStack.axis = .horizontal
    zoomStack.alignment = .center
    zoomStack.spacing = 4
    zoomStack.translatesAutoresizingMaskIntoConstraints = false
    bottomContainer.addArrangedSubview(zoomStack)

    bottomRow.translatesAutoresizingMaskIntoConstraints = false
    bottomContainer.addArrangedSubview(bottomRow)
    NSLayoutConstraint.activate([
      bottomRow.widthAnchor.constraint(equalTo: bottomContainer.widthAnchor),
      bottomRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 88),
    ])

    captureCountLabel.translatesAutoresizingMaskIntoConstraints = false
    captureCountLabel.textColor = .white
    captureCountLabel.font = .systemFont(ofSize: 14, weight: .bold)
    captureCountLabel.insets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
    captureCountLabel.backgroundColor = UIColor(white: 0, alpha: 0.55)
    captureCountLabel.layer.cornerRadius = 20
    captureCountLabel.clipsToBounds = true
    captureCountLabel.isHidden = true
    bottomRow.addSubview(captureCountLabel)

    shutterButton.translatesAutoresizingMaskIntoConstraints = false
    shutterButton.backgroundColor = UIColor(white: 1, alpha: 0.1)
    shutterButton.layer.cornerRadius = 44
    shutterButton.layer.borderColor = UIColor.white.cgColor
    shutterButton.layer.borderWidth = 3
    shutterButton.addTarget(self, action: #selector(shutterTapped), for: .touchUpInside)
    bottomRow.addSubview(shutterButton)

    shutterInnerCircle.translatesAutoresizingMaskIntoConstraints = false
    shutterInnerCircle.backgroundColor = .white
    shutterInnerCircle.layer.cornerRadius = 32
    shutterInnerCircle.isUserInteractionEnabled = false
    shutterButton.addSubview(shutterInnerCircle)

    NSLayoutConstraint.activate([
      captureCountLabel.leadingAnchor.constraint(equalTo: bottomRow.leadingAnchor),
      captureCountLabel.centerYAnchor.constraint(equalTo: bottomRow.centerYAnchor),

      shutterButton.centerXAnchor.constraint(equalTo: bottomRow.centerXAnchor),
      shutterButton.centerYAnchor.constraint(equalTo: bottomRow.centerYAnchor),
      shutterButton.widthAnchor.constraint(equalToConstant: 88),
      shutterButton.heightAnchor.constraint(equalToConstant: 88),

      shutterInnerCircle.centerXAnchor.constraint(equalTo: shutterButton.centerXAnchor),
      shutterInnerCircle.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),
      shutterInnerCircle.widthAnchor.constraint(equalToConstant: 64),
      shutterInnerCircle.heightAnchor.constraint(equalToConstant: 64),
    ])
  }

  private func configureTargetButton() {
    targetButton.translatesAutoresizingMaskIntoConstraints = false
    targetButton.backgroundColor = UIColor(white: 0, alpha: 0.55)
    targetButton.layer.cornerRadius = 20
    targetButton.clipsToBounds = true
    targetButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    targetButton.setTitleColor(.white, for: .normal)
    targetButton.tintColor = .white
    targetButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
    targetButton.semanticContentAttribute = .forceLeftToRight
    targetButton.addTarget(self, action: #selector(targetTapped), for: .touchUpInside)
  }

  private func configureIconButton(
    _ button: UIButton,
    symbolName: String,
    accessibilityLabel: String,
    action: Selector
  ) {
    button.translatesAutoresizingMaskIntoConstraints = false
    button.backgroundColor = UIColor(white: 0, alpha: 0.55)
    button.layer.cornerRadius = 24
    button.clipsToBounds = true
    button.tintColor = .white
    button.setImage(UIImage(systemName: symbolName), for: .normal)
    button.accessibilityLabel = accessibilityLabel
    button.addTarget(self, action: action, for: .touchUpInside)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 48),
      button.heightAnchor.constraint(equalToConstant: 48),
    ])
  }

  private func configureLifecycleObservers() {
    let notificationCenter = NotificationCenter.default
    lifecycleObservers.append(
      notificationCenter.addObserver(
        forName: UIApplication.willResignActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.sessionQueue.async {
          self?.captureSession.stopRunning()
        }
      }
    )
    lifecycleObservers.append(
      notificationCenter.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        self.startSessionIfNeeded()
      }
    )
  }

  private func requestCameraAccessAndStart() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      startSessionIfNeeded()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          guard let self else { return }
          if granted {
            self.startSessionIfNeeded()
          } else {
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

  private func startSessionIfNeeded() {
    pendingSessionStartWorkItem?.cancel()
    startSession(attempt: 1)
  }

  private func startSession(attempt: Int) {
    sessionQueue.async {
      do {
        try self.configureSession()
        self.captureSession.startRunning()
        NSLog("[JoblensCamera][iOS] Camera session started on attempt \(attempt)")
        self.emitPreviewReadyIfNeeded()
      } catch {
        DispatchQueue.main.async {
          self.handleSessionStartFailure(error, attempt: attempt)
        }
      }
    }
  }

  private func handleSessionStartFailure(_ error: Error, attempt: Int) {
    guard isClosing == false else { return }
    let nsError = error as NSError
    NSLog(
      "[JoblensCamera][iOS] Camera start failed on attempt \(attempt): domain=\(nsError.domain) code=\(nsError.code) message=\(nsError.localizedDescription)"
    )

    if attempt < Self.maxSessionStartAttempts {
      let delay = 0.2 * Double(attempt)
      let workItem = DispatchWorkItem { [weak self] in
        self?.startSession(attempt: attempt + 1)
      }
      pendingSessionStartWorkItem?.cancel()
      pendingSessionStartWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
      return
    }

    emitFailure("Unable to bind camera: \(nsError.localizedDescription)")
    closeSession()
  }

  private func configureSession() throws {
    let position = currentLensPosition
    guard let device = Self.bestDevice(for: position) else {
      throw NativeCameraError.noCompatibleCamera
    }

    try Self.ensureDeviceReady(device)

    let input = try AVCaptureDeviceInput(device: device)

    captureSession.beginConfiguration()
    captureSession.sessionPreset = .photo

    if let currentInput {
      captureSession.removeInput(currentInput)
    }
    if captureSession.inputs.contains(where: { $0 === input }) == false,
       captureSession.canAddInput(input) {
      captureSession.addInput(input)
    }

    if captureSession.outputs.contains(photoOutput) == false,
       captureSession.canAddOutput(photoOutput) {
      captureSession.addOutput(photoOutput)
      photoOutput.isHighResolutionCaptureEnabled = true
    }
    captureSession.commitConfiguration()

    currentInput = input
    currentLensPosition = device.position

    try device.lockForConfiguration()
    let zoomRange: ClosedRange<CGFloat>
    if #available(iOS 13.0, *) {
      zoomRange = device.minAvailableVideoZoomFactor...device.maxAvailableVideoZoomFactor
    } else {
      zoomRange = 1...max(device.activeFormat.videoMaxZoomFactor, 1)
    }
    let clampedZoom = max(zoomRange.lowerBound, min(currentZoomFactor, zoomRange.upperBound))
    device.videoZoomFactor = clampedZoom
    currentZoomFactor = clampedZoom
    device.unlockForConfiguration()

    DispatchQueue.main.async {
      self.rebuildZoomButtons(for: device)
      self.updateFlashButton()
      self.updateLensButton()
    }
  }

  private func emitPreviewReadyIfNeeded() {
    guard previewReadySent == false else { return }
    previewReadySent = true
    NSLog(
      "[JoblensCamera][iOS] Preview ready session=\(launchConfig.sessionId) openMs=\(Int(Date().timeIntervalSince(openedAt) * 1000))"
    )
    bridge?.emit(
      sessionEvent(
        type: "previewReady",
        openDurationMs: Int(Date().timeIntervalSince(openedAt) * 1000)
      )
    )
  }

  private func rebuildZoomButtons(for device: AVCaptureDevice) {
    let minZoom: CGFloat
    let maxZoom: CGFloat
    if #available(iOS 13.0, *) {
      minZoom = device.minAvailableVideoZoomFactor
      maxZoom = device.maxAvailableVideoZoomFactor
    } else {
      minZoom = 1
      maxZoom = max(device.activeFormat.videoMaxZoomFactor, 1)
    }

    let preferredStops: [CGFloat] = [0.5, 1, 2, 3, 5]
    var stops: [CGFloat] = []
    for raw in preferredStops {
      let clamped = max(minZoom, min(raw, maxZoom))
      if stops.contains(where: { abs($0 - clamped) < 0.05 }) == false {
        stops.append(clamped)
      }
    }
    if stops.isEmpty {
      stops = [currentZoomFactor]
    }

    zoomButtons.forEach { $0.removeFromSuperview() }
    zoomButtons.removeAll()
    zoomStack.isHidden = stops.count <= 1

    for stop in stops {
      let button = UIButton(type: .system)
      button.setTitle("\(formatZoom(stop))x", for: .normal)
      button.setTitleColor(.white, for: .normal)
      button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
      button.backgroundColor = UIColor(white: 0, alpha: 0.55)
      button.layer.cornerRadius = 16
      button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
      button.tag = Int(stop * 100)
      button.addTarget(self, action: #selector(zoomTapped(_:)), for: .touchUpInside)
      updateZoomButtonStyle(button, selected: abs(stop - currentZoomFactor) < 0.05)
      zoomStack.addArrangedSubview(button)
      zoomButtons.append(button)
    }
  }

  private func updateZoomButtonStyle(_ button: UIButton, selected: Bool) {
    button.backgroundColor = selected ? .white : UIColor(white: 0, alpha: 0.55)
    button.setTitleColor(selected ? .black : .white, for: .normal)
  }

  private func updateTargetButton() {
    let folderImage = UIImage(systemName: "folder")
    let chevronImage = UIImage(systemName: "chevron.down")
    targetButton.setTitle(currentTarget.resolvedProjectName, for: .normal)
    targetButton.setImage(folderImage, for: .normal)
    targetButton.semanticContentAttribute = .forceLeftToRight
    targetButton.imageView?.contentMode = .scaleAspectFit
    targetButton.setNeedsLayout()
    targetButton.layoutIfNeeded()
    targetButton.subviews.compactMap { $0 as? UIImageView }.forEach { imageView in
      imageView.tintColor = .white
    }

    let trailingChevron = UIImageView(image: chevronImage)
    trailingChevron.translatesAutoresizingMaskIntoConstraints = false
    trailingChevron.tintColor = .white
    trailingChevron.isUserInteractionEnabled = false
    targetButton.subviews.filter { $0.tag == 9001 }.forEach { $0.removeFromSuperview() }
    trailingChevron.tag = 9001
    targetButton.addSubview(trailingChevron)
    NSLayoutConstraint.activate([
      trailingChevron.centerYAnchor.constraint(equalTo: targetButton.centerYAnchor),
      trailingChevron.trailingAnchor.constraint(equalTo: targetButton.trailingAnchor, constant: -12),
      trailingChevron.widthAnchor.constraint(equalToConstant: 12),
      trailingChevron.heightAnchor.constraint(equalToConstant: 12),
    ])
    targetButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 30)
    targetButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
  }

  private func updateFlashButton() {
    guard let device = currentInput?.device else {
      flashButton.isHidden = true
      return
    }
    let supportsFlash = photoOutput.supportedFlashModes.contains(currentFlashMode) &&
      device.hasFlash
    flashButton.isHidden = supportsFlash == false
    guard supportsFlash else { return }

    let symbolName: String
    let label: String
    let selected: Bool
    switch currentFlashMode {
    case .auto:
      symbolName = "bolt.badge.a"
      label = "Flash auto"
      selected = true
    case .on:
      symbolName = "bolt.fill"
      label = "Flash on"
      selected = true
    default:
      symbolName = "bolt.slash"
      label = "Flash off"
      selected = false
    }
    flashButton.setImage(UIImage(systemName: symbolName), for: .normal)
    flashButton.accessibilityLabel = label
    flashButton.tintColor = selected ? .black : .white
    flashButton.backgroundColor = selected ? .white : UIColor(white: 0, alpha: 0.55)
  }

  private func updateLensButton() {
    let hasFront = Self.bestDevice(for: .front) != nil
    let hasBack = Self.bestDevice(for: .back) != nil
    let canSwitch = hasFront && hasBack
    lensButton.isHidden = canSwitch == false
    lensButton.isEnabled = canSwitch && isSwitchingLens == false
    let selected = currentLensPosition == .front
    lensButton.tintColor = selected ? .black : .white
    lensButton.backgroundColor = selected ? .white : UIColor(white: 0, alpha: 0.55)
    lensButton.accessibilityLabel = selected ? "Front camera" : "Rear camera"
  }

  private func updateCaptureCount() {
    captureCountLabel.isHidden = capturedCount == 0
    captureCountLabel.text = "\(capturedCount) saved"
  }

  private func animateShutterPress() {
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
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    let overlay = UIView(frame: view.bounds)
    overlay.backgroundColor = UIColor.white.withAlphaComponent(0.18)
    overlay.alpha = 0
    view.addSubview(overlay)
    UIView.animate(withDuration: 0.045, animations: {
      overlay.alpha = 1
    }) { _ in
      UIView.animate(withDuration: 0.11, animations: {
        overlay.alpha = 0
      }) { _ in
        overlay.removeFromSuperview()
      }
    }

    captureCountLabel.transform = .identity
    UIView.animate(withDuration: 0.09, animations: {
      self.captureCountLabel.transform = CGAffineTransform(scaleX: 1.06, y: 1.06)
      self.captureCountLabel.alpha = 0.95
    }) { _ in
      UIView.animate(withDuration: 0.14) {
        self.captureCountLabel.transform = .identity
        self.captureCountLabel.alpha = 1
      }
    }
  }

  @objc private func closeTapped() {
    closeSession()
  }

  @objc private func flashTapped() {
    guard photoOutput.supportedFlashModes.isEmpty == false else { return }
    let nextMode: AVCaptureDevice.FlashMode
    switch currentFlashMode {
    case .off:
      nextMode = .auto
    case .auto:
      nextMode = .on
    default:
      nextMode = .off
    }
    currentFlashMode = nextMode
    updateFlashButton()
  }

  @objc private func lensTapped() {
    guard isSwitchingLens == false else { return }
    let target: AVCaptureDevice.Position = currentLensPosition == .back ? .front : .back
    guard Self.bestDevice(for: target) != nil else { return }
    isSwitchingLens = true
    lensSwitchStartedAt = Date()
    lensButton.isEnabled = false
    currentLensPosition = target
    NSLog("[JoblensCamera][iOS] Lens switch started lens=\(target.flutterLensName)")
    sessionQueue.async {
      do {
        try self.configureSession()
        self.captureSession.startRunning()
        DispatchQueue.main.async {
          self.isSwitchingLens = false
          let durationMs = self.lensSwitchStartedAt.map {
            Int(Date().timeIntervalSince($0) * 1000)
          }
          self.lensSwitchStartedAt = nil
          self.updateLensButton()
          NSLog("[JoblensCamera][iOS] Lens switch completed durationMs=\(durationMs ?? -1)")
          self.bridge?.emit(
            self.sessionEvent(
              type: "lensSwitchCompleted",
              durationMs: durationMs
            )
          )
        }
      } catch {
        DispatchQueue.main.async {
          let durationMs = self.lensSwitchStartedAt.map {
            Int(Date().timeIntervalSince($0) * 1000)
          }
          self.lensSwitchStartedAt = nil
          self.isSwitchingLens = false
          NSLog(
            "[JoblensCamera][iOS] Lens switch failed durationMs=\(durationMs ?? -1) message=\(error.localizedDescription)"
          )
          self.bridge?.emit(
            self.sessionEvent(
              type: "lensSwitchFailed",
              message: "Unable to bind camera: \(error.localizedDescription)",
              durationMs: durationMs
            )
          )
          if durationMs == nil {
            self.emitFailure("Unable to bind camera: \(error.localizedDescription)")
          }
          self.closeSession()
        }
      }
    }
  }

  @objc private func shutterTapped() {
    guard isClosing == false else { return }
    guard isCaptureInFlight == false else { return }
    guard let target = currentTarget as NativeCameraTargetOption? else { return }
    isCaptureInFlight = true
    shutterButton.isEnabled = false
    animateShutterPress()

    let photoId = UUID().uuidString.lowercased()
    let captureStart = Date()
    NSLog("[JoblensCamera][iOS] Capture started photoId=\(photoId)")
    bridge?.emit(
      sessionEvent(
        type: "captureStarted",
        photoId: photoId,
        targetMode: target.mode.wireValue,
        targetProjectId: target.resolvedProjectId,
        targetProjectName: target.resolvedProjectName,
        fixedProjectId: target.fixedProjectId
      )
    )

    let settings = AVCapturePhotoSettings()
    if photoOutput.supportedFlashModes.contains(currentFlashMode) {
      settings.flashMode = currentFlashMode
    }
    if photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
      settings.availablePreviewPhotoPixelFormatTypes.first.map { _ in
        settings.previewPhotoFormat = [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
      }
    }

    let outputUrl: URL
    do {
      outputUrl = try createOutputFile(photoId: photoId)
    } catch {
      isCaptureInFlight = false
      shutterButton.isEnabled = true
      emitFailure("Capture failed: \(error.localizedDescription)")
      return
    }

    let delegate = NativePhotoCaptureDelegate(
      photoId: photoId,
      outputUrl: outputUrl,
      captureStartedAt: captureStart,
      target: target
    ) { [weak self] result in
      guard let self else { return }
      DispatchQueue.main.async {
        self.handleCaptureResult(result)
      }
    }
    captureDelegates[photoId] = delegate
    photoOutput.capturePhoto(with: settings, delegate: delegate)
  }

  @objc private func targetTapped() {
    let pickerOpenedAt = Date()
    guard presentedViewController == nil else {
      NSLog("[JoblensCamera][iOS] Target picker failed: presenter already busy")
      bridge?.emit(
        sessionEvent(
          type: "targetPickerFailed",
          message: "Unable to open capture target picker."
        )
      )
      return
    }
    let picker = NativeCameraTargetPickerViewController(
      options: launchConfig.targets,
      selectedTarget: currentTarget
    ) { [weak self] option in
      guard let self else { return }
      self.currentTarget = option
      self.updateTargetButton()
      self.bridge?.emit(
        self.sessionEvent(
          type: "targetChanged",
          targetMode: option.mode.wireValue,
          targetProjectId: option.resolvedProjectId,
          targetProjectName: option.resolvedProjectName,
          fixedProjectId: option.fixedProjectId
        )
      )
    }
    picker.modalPresentationStyle = .pageSheet
    if #available(iOS 15.0, *), let sheet = picker.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
    }
    present(picker, animated: true) {
      let durationMs = Int(Date().timeIntervalSince(pickerOpenedAt) * 1000)
      NSLog("[JoblensCamera][iOS] Target picker opened durationMs=\(durationMs)")
      self.bridge?.emit(
        self.sessionEvent(
          type: "targetPickerOpened",
          durationMs: durationMs
        )
      )
    }
  }

  @objc private func zoomTapped(_ sender: UIButton) {
    guard let device = currentInput?.device else { return }
    let zoomValue = CGFloat(sender.tag) / 100
    sessionQueue.async {
      do {
        try device.lockForConfiguration()
        let maxZoom: CGFloat
        let minZoom: CGFloat
        if #available(iOS 13.0, *) {
          minZoom = device.minAvailableVideoZoomFactor
          maxZoom = device.maxAvailableVideoZoomFactor
        } else {
          minZoom = 1
          maxZoom = max(device.activeFormat.videoMaxZoomFactor, 1)
        }
        let clamped = max(minZoom, min(zoomValue, maxZoom))
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
        DispatchQueue.main.async {
          self.currentZoomFactor = clamped
          self.zoomButtons.forEach { button in
            let stop = CGFloat(button.tag) / 100
            self.updateZoomButtonStyle(button, selected: abs(stop - clamped) < 0.05)
          }
        }
      } catch {
        // Ignore unsupported zoom operations.
      }
    }
  }

  private func handleCaptureResult(_ result: NativeCaptureResult) {
    captureDelegates[result.photoId] = nil
    guard isClosing == false else { return }
    isCaptureInFlight = false
    shutterButton.isEnabled = true

    switch result {
    case .success(let photoId, let localPath, let target, let capturedAt, let captureDurationMs):
      capturedCount += 1
      updateCaptureCount()
      playCaptureSuccessFeedback()
      NSLog("[JoblensCamera][iOS] Capture saved photoId=\(photoId) durationMs=\(captureDurationMs)")
      bridge?.emit(
        sessionEvent(
          type: "captureSaved",
          photoId: photoId,
          localPath: localPath,
          targetMode: target.mode.wireValue,
          targetProjectId: target.resolvedProjectId,
          targetProjectName: target.resolvedProjectName,
          fixedProjectId: target.fixedProjectId,
          capturedAt: capturedAt,
          captureDurationMs: captureDurationMs
        )
      )
    case .failure(_, let message):
      emitFailure(message)
    }
  }

  private func emitFailure(_ message: String) {
    guard isClosing == false else { return }
    NSLog("[JoblensCamera][iOS] \(message)")
    bridge?.emit(sessionEvent(type: "captureFailed", message: message))
  }

  private func closeSession() {
    guard isClosing == false else { return }
    isClosing = true
    pendingSessionStartWorkItem?.cancel()
    shutterButton.isEnabled = false
    sessionQueue.async { [captureSession] in
      if captureSession.isRunning {
        captureSession.stopRunning()
      }
    }
    emitSessionClosedIfNeeded()
    bridge?.didCloseCamera(self)
    dismiss(animated: true) {
      self.captureDelegates.removeAll()
    }
  }

  private func emitSessionClosedIfNeeded() {
    guard didEmitSessionClosed == false else { return }
    didEmitSessionClosed = true
    bridge?.emit(
      sessionEvent(
        type: "sessionClosed",
        capturedCount: capturedCount,
        settings: [
          "flashMode": currentFlashMode.flutterName,
          "lensDirection": currentLensPosition.flutterLensName,
          "zoomStop": Double(currentZoomFactor)
        ]
      )
    )
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
    durationMs: Int? = nil,
    capturedCount: Int? = nil,
    settings: [String: Any]? = nil
  ) -> [String: Any?] {
    [
      "type": type,
      "sessionId": launchConfig.sessionId,
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
      "durationMs": durationMs,
      "capturedCount": capturedCount,
      "settings": settings
    ]
  }

  private func createOutputFile(photoId: String) throws -> URL {
    let baseDirectory = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let sessionDirectory = baseDirectory
      .appendingPathComponent("captures", isDirectory: true)
      .appendingPathComponent(launchConfig.sessionId, isDirectory: true)
    try FileManager.default.createDirectory(
      at: sessionDirectory,
      withIntermediateDirectories: true
    )
    return sessionDirectory.appendingPathComponent("\(photoId).jpg")
  }

  private func formatZoom(_ zoom: CGFloat) -> String {
    let rounded = round(zoom)
    if abs(zoom - rounded) < 0.05 {
      return String(Int(rounded))
    }
    return String(format: "%.1f", zoom)
  }

  private static func bestDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
    let preferredTypes: [AVCaptureDevice.DeviceType]
    switch position {
    case .front:
      preferredTypes = [.builtInTrueDepthCamera, .builtInWideAngleCamera]
    default:
      // Prefer the standard rear wide camera. Falling back to ultra-wide by
      // default produces the distorted perspective the app should avoid.
      preferredTypes = [
        .builtInWideAngleCamera,
        .builtInDualCamera,
        .builtInDualWideCamera,
        .builtInTripleCamera,
        .builtInUltraWideCamera,
      ]
    }

    let discoverySession = AVCaptureDevice.DiscoverySession(
      deviceTypes: preferredTypes,
      mediaType: .video,
      position: position
    )
    for type in preferredTypes {
      if let device = discoverySession.devices.first(where: { $0.deviceType == type }) {
        return device
      }
    }
    return discoverySession.devices.first
  }

  private static func ensureDeviceReady(_ device: AVCaptureDevice) throws {
    try device.lockForConfiguration()
    device.unlockForConfiguration()
  }
}

private final class NativeCameraTargetPickerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
  private let options: [NativeCameraTargetOption]
  private let selectedTarget: NativeCameraTargetOption
  private let onSelect: (NativeCameraTargetOption) -> Void

  private let searchBar = UISearchBar()
  private let tableView = UITableView(frame: .zero, style: .plain)
  private var filteredOptions: [NativeCameraTargetOption]

  init(
    options: [NativeCameraTargetOption],
    selectedTarget: NativeCameraTargetOption,
    onSelect: @escaping (NativeCameraTargetOption) -> Void
  ) {
    self.options = options.sorted { $0.resolvedProjectName.localizedCaseInsensitiveCompare($1.resolvedProjectName) == .orderedAscending }
    self.selectedTarget = selectedTarget
    self.filteredOptions = self.options
    self.onSelect = onSelect
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = "Capture target"

    let navBar = UINavigationBar()
    navBar.translatesAutoresizingMaskIntoConstraints = false
    let navItem = UINavigationItem(title: "Capture target")
    navItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .close,
      target: self,
      action: #selector(closeTapped)
    )
    navBar.items = [navItem]
    view.addSubview(navBar)

    searchBar.translatesAutoresizingMaskIntoConstraints = false
    searchBar.placeholder = "Search projects"
    searchBar.delegate = self
    searchBar.searchBarStyle = .minimal
    view.addSubview(searchBar)

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    tableView.tableFooterView = UIView()
    view.addSubview(tableView)

    NSLayoutConstraint.activate([
      navBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      navBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      navBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

      searchBar.topAnchor.constraint(equalTo: navBar.bottomAnchor, constant: 8),
      searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

      tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 8),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  @objc private func closeTapped() {
    dismiss(animated: true)
  }

  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty {
      filteredOptions = options
    } else {
      filteredOptions = options.filter { option in
        option.resolvedProjectName.localizedCaseInsensitiveContains(query) ||
          (option.mode == .inbox && "Inbox".localizedCaseInsensitiveContains(query))
      }
    }
    tableView.reloadData()
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    filteredOptions.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let option = filteredOptions[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
    cell.textLabel?.text = option.resolvedProjectName
    cell.textLabel?.textColor = .label
    cell.imageView?.image = UIImage(systemName: option.mode == .inbox ? "tray" : "folder")
    cell.imageView?.tintColor = .label
    cell.accessoryType = option == selectedTarget ? .checkmark : .none
    cell.backgroundColor = .clear
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    let option = filteredOptions[indexPath.row]
    onSelect(option)
    dismiss(animated: true)
  }
}

private final class NativePhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
  private let photoId: String
  private let outputUrl: URL
  private let captureStartedAt: Date
  private let target: NativeCameraTargetOption
  private let completion: (NativeCaptureResult) -> Void

  init(
    photoId: String,
    outputUrl: URL,
    captureStartedAt: Date,
    target: NativeCameraTargetOption,
    completion: @escaping (NativeCaptureResult) -> Void
  ) {
    self.photoId = photoId
    self.outputUrl = outputUrl
    self.captureStartedAt = captureStartedAt
    self.target = target
    self.completion = completion
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput,
    didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    if let error {
      completion(.failure(photoId: photoId, message: "Capture failed: \(error.localizedDescription)"))
      return
    }

    guard let data = photo.fileDataRepresentation() else {
      completion(.failure(photoId: photoId, message: "Capture failed: Missing image data."))
      return
    }

    do {
      try data.write(to: outputUrl, options: .atomic)
      let capturedAt = ISO8601DateFormatter().string(from: Date())
      let durationMs = Int(Date().timeIntervalSince(captureStartedAt) * 1000)
      completion(
        .success(
          photoId: photoId,
          localPath: outputUrl.path,
          target: target,
          capturedAt: capturedAt,
          captureDurationMs: durationMs
        )
      )
    } catch {
      completion(.failure(photoId: photoId, message: "Capture failed: \(error.localizedDescription)"))
    }
  }
}

private enum NativeCaptureResult {
  case success(
    photoId: String,
    localPath: String,
    target: NativeCameraTargetOption,
    capturedAt: String,
    captureDurationMs: Int
  )
  case failure(photoId: String, message: String)

  var photoId: String {
    switch self {
    case .success(let photoId, _, _, _, _):
      return photoId
    case .failure(let photoId, _):
      return photoId
    }
  }
}

private struct NativeCameraLaunchConfig {
  let sessionId: String
  let currentMode: NativeCaptureTargetMode
  let currentProjectId: Int
  let currentProjectName: String
  let targets: [NativeCameraTargetOption]
  let settings: NativeCameraSettingsConfig

  func resolveCurrentTarget() -> NativeCameraTargetOption {
    targets.first { option in
      switch currentMode {
      case .fixedProject, .lastUsed:
        return option.mode == .fixedProject && option.fixedProjectId == currentProjectId
      case .inbox:
        return option.mode == .inbox
      }
    } ?? targets.first!
  }

  static func fromPayload(_ payload: String) throws -> NativeCameraLaunchConfig {
    let data = Data(payload.utf8)
    let decoded = try JSONDecoder().decode(DecodedPayload.self, from: data)
    return NativeCameraLaunchConfig(
      sessionId: decoded.sessionId,
      currentMode: NativeCaptureTargetMode(rawValue: decoded.currentMode) ?? .inbox,
      currentProjectId: decoded.currentProjectId,
      currentProjectName: decoded.currentProjectName,
      targets: decoded.targets.map(NativeCameraTargetOption.init),
      settings: NativeCameraSettingsConfig(decoded: decoded.settings)
    )
  }

  private struct DecodedPayload: Decodable {
    let sessionId: String
    let currentMode: String
    let currentProjectId: Int
    let currentProjectName: String
    let targets: [DecodedTarget]
    let settings: DecodedSettings
  }
}

private struct NativeCameraTargetOption: Equatable {
  let mode: NativeCaptureTargetMode
  let label: String
  let resolvedProjectId: Int
  let resolvedProjectName: String
  let fixedProjectId: Int?

  init(decoded: DecodedTarget) {
    mode = NativeCaptureTargetMode(rawValue: decoded.mode) ?? .inbox
    label = decoded.label
    resolvedProjectId = decoded.resolvedProjectId
    resolvedProjectName = decoded.resolvedProjectName
    fixedProjectId = decoded.fixedProjectId
  }
}

private struct NativeCameraSettingsConfig {
  let flashMode: AVCaptureDevice.FlashMode
  let lensPosition: AVCaptureDevice.Position
  let zoomStop: Double

  init(decoded: DecodedSettings) {
    switch decoded.flashMode {
    case "auto":
      flashMode = .auto
    case "always":
      flashMode = .on
    default:
      flashMode = .off
    }
    lensPosition = decoded.lensDirection == "front" ? .front : .back
    zoomStop = decoded.zoomStop ?? 1.0
  }
}

private enum NativeCaptureTargetMode: String {
  case inbox = "inbox"
  case lastUsed = "last_used"
  case fixedProject = "fixed_project"

  var wireValue: String { rawValue }
}

private struct DecodedTarget: Decodable {
  let mode: String
  let label: String
  let resolvedProjectId: Int
  let resolvedProjectName: String
  let fixedProjectId: Int?
}

private struct DecodedSettings: Decodable {
  let flashMode: String?
  let lensDirection: String?
  let zoomStop: Double?
}

private enum NativeCameraError: LocalizedError {
  case noCompatibleCamera

  var errorDescription: String? {
    switch self {
    case .noCompatibleCamera:
      return "No compatible camera was found on this device."
    }
  }
}

private final class PaddingLabel: UILabel {
  var insets = UIEdgeInsets.zero

  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.inset(by: insets))
  }

  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(
      width: size.width + insets.left + insets.right,
      height: size.height + insets.top + insets.bottom
    )
  }
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
}

private extension AVCaptureDevice.Position {
  var flutterLensName: String {
    self == .front ? "front" : "back"
  }
}
