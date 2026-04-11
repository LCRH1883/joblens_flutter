package com.intagri.joblens

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.SystemClock
import android.text.Editable
import android.text.InputType
import android.text.TextUtils
import android.text.TextWatcher
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.View
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.content.res.AppCompatResources
import androidx.appcompat.widget.AppCompatButton
import androidx.appcompat.widget.AppCompatEditText
import androidx.appcompat.widget.AppCompatImageButton
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.DrawableCompat
import androidx.activity.addCallback
import androidx.lifecycle.Observer
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.abs

class NativeCameraActivity : AppCompatActivity() {
    companion object {
        const val EXTRA_CONFIG = "native_camera_config"
    }

    private val cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var launchConfig: CameraLaunchConfig? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var imageCapture: ImageCapture? = null
    private lateinit var previewView: PreviewView
    private lateinit var targetButton: AppCompatButton
    private lateinit var flashButton: AppCompatImageButton
    private lateinit var lensButton: AppCompatImageButton
    private lateinit var shutterButton: FrameLayout
    private lateinit var flashOverlayView: View
    private lateinit var captureCountView: TextView
    private lateinit var zoomButtonsContainer: LinearLayout
    private lateinit var zoomScroller: HorizontalScrollView
    private var zoomButtons: List<AppCompatButton> = emptyList()
    private var currentFlashMode = ImageCapture.FLASH_MODE_OFF
    private var currentLensFacing = CameraSelector.LENS_FACING_BACK
    private var currentZoomRatio = 1f
    private var currentTarget: CaptureTargetOption? = null
    private var capturedCount = 0
    private var openedAtMs = 0L
    private var previewReadySent = false
    private var captureInFlight = false
    private var lensSwitchInFlight = false
    private var zoomObserver: Observer<androidx.camera.core.ZoomState>? = null

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) {
                startCamera()
            } else {
                emitFailure("Camera permission is required to capture photos.")
                closeSession()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val payload = intent.getStringExtra(EXTRA_CONFIG)
        if (payload.isNullOrBlank()) {
            emitFailure("Camera session payload was missing.")
            finish()
            return
        }

        launchConfig = CameraLaunchConfig.fromPayload(payload)
        openedAtMs = SystemClock.elapsedRealtime()
        currentTarget = launchConfig?.resolveCurrentTarget()
        currentLensFacing = launchConfig?.settings?.lensFacing ?: CameraSelector.LENS_FACING_BACK
        currentFlashMode = launchConfig?.settings?.flashMode ?: ImageCapture.FLASH_MODE_OFF
        currentZoomRatio = launchConfig?.settings?.zoomStop ?: 1f

        setContentView(buildContentView())
        onBackPressedDispatcher.addCallback(this) {
            closeSession()
        }
        updateTargetButton()
        updateFlashButton()
        updateLensButton()
        updateCaptureCount()

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            startCamera()
        } else {
            permissionLauncher.launch(Manifest.permission.CAMERA)
        }
    }

    override fun onDestroy() {
        cameraProvider?.unbindAll()
        zoomObserver?.let { observer ->
            camera?.cameraInfo?.zoomState?.removeObserver(observer)
        }
        cameraExecutor.shutdown()
        super.onDestroy()
    }

    private fun buildContentView(): View {
        previewView = PreviewView(this).apply {
            implementationMode = PreviewView.ImplementationMode.PERFORMANCE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }

        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(
                previewView,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT,
                ),
            )
        }
        flashOverlayView = View(this).apply {
            setBackgroundColor(Color.WHITE)
            alpha = 0f
            isClickable = false
            isFocusable = false
        }
        root.addView(
            flashOverlayView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        val topBar = FrameLayout(this).apply {
            setPadding(dp(16), dp(12), dp(16), dp(8))
        }

        val backButton = createIconButton(
            iconRes = R.drawable.ic_joblens_arrow_back_24,
            contentDescription = "Close camera",
        ).apply {
            setOnClickListener { closeSession() }
        }
        targetButton = createTargetButton("Inbox").apply {
            setOnClickListener { showTargetPicker() }
        }
        flashButton = createIconButton(
            iconRes = R.drawable.ic_joblens_flash_off_24,
            contentDescription = "Flash off",
        ).apply {
            setOnClickListener { cycleFlashMode() }
        }
        lensButton = createIconButton(
            iconRes = R.drawable.ic_joblens_switch_camera_24,
            contentDescription = "Switch camera",
        ).apply {
            setOnClickListener { switchLens() }
        }
        val rightControls = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(flashButton, LinearLayout.LayoutParams(dp(48), dp(48)))
            addView(
                lensButton,
                LinearLayout.LayoutParams(dp(48), dp(48)).apply {
                    marginStart = dp(12)
                },
            )
        }

        topBar.addView(
            backButton,
            FrameLayout.LayoutParams(dp(48), dp(48), Gravity.START or Gravity.CENTER_VERTICAL),
        )
        topBar.addView(
            targetButton,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER,
            ),
        )
        topBar.addView(
            rightControls,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.END or Gravity.CENTER_VERTICAL,
            ),
        )

        val topParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.TOP,
        )
        root.addView(topBar, topParams)

        zoomButtonsContainer = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }

        zoomScroller = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            visibility = View.GONE
            addView(
                zoomButtonsContainer,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                ),
            )
        }

        captureCountView = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            background = pillBackground(selected = false)
            setPadding(dp(14), dp(10), dp(14), dp(10))
            visibility = View.GONE
        }

        shutterButton = createShutterButton().apply {
            setOnClickListener { capturePhoto() }
        }

        val bottomRow = FrameLayout(this).apply {
            minimumHeight = dp(88)
            addView(
                captureCountView,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                    Gravity.START or Gravity.CENTER_VERTICAL,
                ),
            )
            addView(
                shutterButton,
                FrameLayout.LayoutParams(dp(88), dp(88), Gravity.CENTER),
            )
        }

        val bottomContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(12), dp(16), dp(16))
            gravity = Gravity.CENTER_HORIZONTAL
            addView(
                zoomScroller,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ).apply {
                    bottomMargin = dp(16)
                    gravity = Gravity.CENTER_HORIZONTAL
                },
            )
            addView(
                bottomRow,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ),
            )
        }

        val bottomParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM,
        )
        root.addView(bottomContainer, bottomParams)
        return root
    }

    private fun startCamera() {
        val providerFuture = ProcessCameraProvider.getInstance(this)
        providerFuture.addListener(
            {
                val provider = providerFuture.get()
                cameraProvider = provider
                bindCameraUseCases(provider)
            },
            ContextCompat.getMainExecutor(this),
        )
    }

    private fun bindCameraUseCases(provider: ProcessCameraProvider) {
        val selector = CameraSelector.Builder()
            .requireLensFacing(currentLensFacing)
            .build()
        if (!provider.safeHasCamera(selector)) {
            if (currentLensFacing == CameraSelector.LENS_FACING_FRONT) {
                currentLensFacing = CameraSelector.LENS_FACING_BACK
                updateLensButton()
                bindCameraUseCases(provider)
                return
            }
            emitFailure("No compatible camera was found on this device.")
            closeSession()
            return
        }

        provider.unbindAll()

        val preview = Preview.Builder().build().apply {
            surfaceProvider = previewView.surfaceProvider
        }
        val capture = ImageCapture.Builder()
            .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
            .build()
        capture.flashMode = currentFlashMode

        try {
            camera = provider.bindToLifecycle(this, selector, preview, capture)
            imageCapture = capture
            lensSwitchInFlight = false
            observeZoomState()
            applyZoomRatio(currentZoomRatio, emitPreviewReady = !previewReadySent)
            updateLensButton()
            updateFlashButton()
        } catch (error: Exception) {
            lensSwitchInFlight = false
            emitFailure("Unable to bind camera: ${error.message ?: error}")
            closeSession()
        }
    }

    private fun observeZoomState() {
        zoomObserver?.let { observer ->
            camera?.cameraInfo?.zoomState?.removeObserver(observer)
        }
        val observer = Observer<androidx.camera.core.ZoomState> { zoomState ->
            currentZoomRatio = zoomState.zoomRatio
            rebuildZoomButtons(zoomState.minZoomRatio, zoomState.maxZoomRatio)
            if (!previewReadySent) {
                previewReadySent = true
                NativeCameraBridge.emit(
                    sessionEvent(
                        type = "previewReady",
                        openDurationMs = (SystemClock.elapsedRealtime() - openedAtMs).toInt(),
                    ),
                )
            }
        }
        zoomObserver = observer
        camera?.cameraInfo?.zoomState?.observe(this, observer)
    }

    private fun rebuildZoomButtons(minZoom: Float, maxZoom: Float) {
        val stops = mutableListOf<Float>()
        for (candidate in listOf(0.5f, 1f, 2f, 3f, 5f)) {
            val clamped = candidate.coerceIn(minZoom, maxZoom)
            if (stops.none { abs(it - clamped) < 0.05f }) {
                stops.add(clamped)
            }
        }
        if (stops.isEmpty()) {
            stops.add(currentZoomRatio.coerceIn(minZoom, maxZoom))
        }

        zoomButtonsContainer.removeAllViews()
        zoomScroller.visibility = if (stops.size <= 1) View.GONE else View.VISIBLE
        zoomButtons = stops.map { zoom ->
            createZoomPillButton("${formatZoom(zoom)}x").apply {
                tag = zoom
                setOnClickListener { applyZoomRatio(zoom, emitPreviewReady = false) }
                setSelectedStyle(abs(currentZoomRatio - zoom) < 0.05f)
            }
        }
        zoomButtons.forEachIndexed { index, button ->
            if (index > 0) {
                zoomButtonsContainer.addView(space(dp(4)))
            }
            zoomButtonsContainer.addView(button)
        }
    }

    private fun capturePhoto() {
        val capture = imageCapture ?: return
        val target = currentTarget ?: return
        if (captureInFlight) {
            return
        }
        captureInFlight = true
        shutterButton.isEnabled = false
        animateShutterPress()
        val photoId = UUID.randomUUID().toString()
        val captureStart = SystemClock.elapsedRealtime()
        val outputFile = createOutputFile(photoId)
        val outputOptions = ImageCapture.OutputFileOptions.Builder(outputFile).build()

        NativeCameraBridge.emit(
            sessionEvent(
                type = "captureStarted",
                photoId = photoId,
                targetMode = target.mode.wireValue,
                targetProjectId = target.resolvedProjectId,
                targetProjectName = target.resolvedProjectName,
                fixedProjectId = target.fixedProjectId,
            ),
        )

        capture.takePicture(
            outputOptions,
            cameraExecutor,
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                    runOnUiThread {
                        captureInFlight = false
                        shutterButton.isEnabled = true
                        capturedCount += 1
                        updateCaptureCount()
                        playCaptureSuccessFeedback()
                        NativeCameraBridge.emit(
                            sessionEvent(
                                type = "captureSaved",
                                photoId = photoId,
                                localPath = outputFile.absolutePath,
                                targetMode = target.mode.wireValue,
                                targetProjectId = target.resolvedProjectId,
                                targetProjectName = target.resolvedProjectName,
                                fixedProjectId = target.fixedProjectId,
                                capturedAt = isoNow(),
                                captureDurationMs = (SystemClock.elapsedRealtime() - captureStart).toInt(),
                            ),
                        )
                    }
                }

                override fun onError(exception: ImageCaptureException) {
                    runOnUiThread {
                        captureInFlight = false
                        shutterButton.isEnabled = true
                        emitFailure("Capture failed: ${exception.message ?: exception.imageCaptureError}")
                    }
                }
            },
        )
    }

    private fun cycleFlashMode() {
        val capture = imageCapture ?: return
        if (camera?.cameraInfo?.hasFlashUnit() != true) {
            flashButton.isEnabled = false
            return
        }

        currentFlashMode = when (currentFlashMode) {
            ImageCapture.FLASH_MODE_OFF -> ImageCapture.FLASH_MODE_AUTO
            ImageCapture.FLASH_MODE_AUTO -> ImageCapture.FLASH_MODE_ON
            else -> ImageCapture.FLASH_MODE_OFF
        }
        capture.flashMode = currentFlashMode
        updateFlashButton()
    }

    private fun switchLens() {
        val provider = cameraProvider ?: return
        if (lensSwitchInFlight) {
            return
        }
        lensSwitchInFlight = true
        lensButton.isEnabled = false
        currentLensFacing = if (currentLensFacing == CameraSelector.LENS_FACING_BACK) {
            CameraSelector.LENS_FACING_FRONT
        } else {
            CameraSelector.LENS_FACING_BACK
        }
        bindCameraUseCases(provider)
    }

    private fun showTargetPicker() {
        val config = launchConfig ?: return
        val inboxTarget = config.targets.firstOrNull { it.mode == CaptureTargetMode.INBOX } ?: return
        val fixedTargets = config.targets
            .filter { it.mode == CaptureTargetMode.FIXED_PROJECT }
            .sortedBy { it.resolvedProjectName.lowercase(Locale.US) }
        val searchField = AppCompatEditText(this).apply {
            hint = "Search projects"
            inputType = InputType.TYPE_CLASS_TEXT
            setTextColor(Color.WHITE)
            setHintTextColor(0xAAFFFFFF.toInt())
            background = dropdownSearchBackground()
            setPadding(dp(14), dp(12), dp(14), dp(12))
        }
        val dropdownList = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        val listScroller = ScrollView(this).apply {
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            addView(
                dropdownList,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                ),
            )
        }
        val popupWidth = minOf(resources.displayMetrics.widthPixels - dp(32), dp(360))
        val popupContent = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = dropdownPanelBackground()
            setPadding(dp(12), dp(12), dp(12), dp(12))
            elevation = dp(18).toFloat()
            addView(
                searchField,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ),
            )
            addView(verticalSpace(dp(8)))
            addView(
                listScroller,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ),
            )
        }
        val popup = PopupWindow(
            popupContent,
            popupWidth,
            LinearLayout.LayoutParams.WRAP_CONTENT,
            true,
        ).apply {
            isOutsideTouchable = true
            isFocusable = true
            inputMethodMode = PopupWindow.INPUT_METHOD_NEEDED
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            elevation = dp(18).toFloat()
        }

        fun renderTargets(query: String) {
            val normalizedQuery = query.trim()
            val matchingTargets = buildList {
                if (
                    normalizedQuery.isBlank() ||
                    "Inbox".contains(normalizedQuery, ignoreCase = true) ||
                    inboxTarget.resolvedProjectName.contains(normalizedQuery, ignoreCase = true)
                ) {
                    add(inboxTarget)
                }
                addAll(
                    fixedTargets.filter { option ->
                        normalizedQuery.isBlank() ||
                            option.resolvedProjectName.contains(
                                normalizedQuery,
                                ignoreCase = true,
                            )
                    },
                )
            }
            dropdownList.removeAllViews()
            if (matchingTargets.isEmpty()) {
                dropdownList.addView(
                    TextView(this).apply {
                        setTextColor(0xAAFFFFFF.toInt())
                        setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                        text = "No matching projects"
                        setPadding(dp(12), dp(8), dp(12), dp(8))
                    },
                )
            } else {
                matchingTargets.forEachIndexed { index, option ->
                    dropdownList.addView(
                        createCompactTargetRow(
                            iconRes = if (option.mode == CaptureTargetMode.INBOX) {
                                R.drawable.ic_joblens_inbox_24
                            } else {
                                R.drawable.ic_joblens_folder_24
                            },
                            title = option.resolvedProjectName,
                            selected = when (option.mode) {
                                CaptureTargetMode.INBOX ->
                                    currentTarget?.mode == CaptureTargetMode.INBOX
                                CaptureTargetMode.FIXED_PROJECT ->
                                    currentTarget?.mode == CaptureTargetMode.FIXED_PROJECT &&
                                        currentTarget?.fixedProjectId == option.fixedProjectId
                                CaptureTargetMode.LAST_USED -> false
                            },
                        ) { selectTarget(popup, option) },
                    )
                    if (index < matchingTargets.lastIndex) {
                        dropdownList.addView(verticalSpace(dp(6)))
                    }
                }
            }

            listScroller.layoutParams = (listScroller.layoutParams as LinearLayout.LayoutParams).apply {
                height = minOf(
                    dp(320),
                    maxOf(
                        dp(56),
                        matchingTargets.size.coerceAtMost(6) * dp(52),
                    ),
                )
            }
            popupContent.measure(
                View.MeasureSpec.makeMeasureSpec(popupWidth, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.UNSPECIFIED,
            )
            popup.height = popupContent.measuredHeight
        }

        searchField.addTextChangedListener(
            object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
                override fun afterTextChanged(s: Editable?) {
                    renderTargets(s?.toString().orEmpty())
                }
            },
        )
        renderTargets("")
        targetButton.post {
            if (!targetButton.isAttachedToWindow) {
                return@post
            }
            val horizontalOffset = (targetButton.width - popupWidth) / 2
            popup.showAsDropDown(targetButton, horizontalOffset, dp(10))
        }
    }

    private fun closeSession() {
        NativeCameraBridge.emit(
            sessionEvent(
                type = "sessionClosed",
                capturedCount = capturedCount,
                settings = mapOf(
                    "flashMode" to currentFlashMode.toFlutterName(),
                    "lensDirection" to currentLensFacing.toFlutterLensName(),
                    "zoomStop" to currentZoomRatio,
                ),
            ),
        )
        finish()
    }

    private fun updateTargetButton() {
        targetButton.text = currentTarget?.resolvedProjectName ?: "Inbox"
        targetButton.setCompoundDrawablesRelativeWithIntrinsicBounds(
            tintedDrawable(R.drawable.ic_joblens_folder_24),
            null,
            tintedDrawable(R.drawable.ic_joblens_expand_more_24),
            null,
        )
    }

    private fun updateFlashButton() {
        val hasFlash = camera?.cameraInfo?.hasFlashUnit() == true
        flashButton.visibility = if (hasFlash) View.VISIBLE else View.GONE
        if (!hasFlash) {
            return
        }
        val (iconRes, description, active) = when (currentFlashMode) {
            ImageCapture.FLASH_MODE_AUTO -> Triple(
                R.drawable.ic_joblens_flash_auto_24,
                "Flash auto",
                true,
            )
            ImageCapture.FLASH_MODE_ON -> Triple(
                R.drawable.ic_joblens_flash_on_24,
                "Flash on",
                true,
            )
            else -> Triple(
                R.drawable.ic_joblens_flash_off_24,
                "Flash off",
                false,
            )
        }
        flashButton.setImageDrawable(tintedDrawable(iconRes, if (active) Color.BLACK else Color.WHITE))
        flashButton.contentDescription = description
        flashButton.setSelectedStyle(active)
    }

    private fun updateLensButton() {
        val provider = cameraProvider
        val hasFront = provider?.safeHasCamera(
            CameraSelector.Builder().requireLensFacing(CameraSelector.LENS_FACING_FRONT).build(),
        ) ?: true
        val hasBack = provider?.safeHasCamera(
            CameraSelector.Builder().requireLensFacing(CameraSelector.LENS_FACING_BACK).build(),
        ) ?: true
        val canSwitch = hasFront && hasBack
        lensButton.visibility = if (canSwitch) View.VISIBLE else View.GONE
        lensButton.isEnabled = canSwitch && !lensSwitchInFlight
        lensButton.setImageDrawable(
            tintedDrawable(
                R.drawable.ic_joblens_switch_camera_24,
                if (currentLensFacing == CameraSelector.LENS_FACING_FRONT) Color.BLACK else Color.WHITE,
            ),
        )
        lensButton.contentDescription = if (currentLensFacing == CameraSelector.LENS_FACING_FRONT) {
            "Front camera"
        } else {
            "Rear camera"
        }
        lensButton.setSelectedStyle(currentLensFacing == CameraSelector.LENS_FACING_FRONT)
    }

    private fun updateCaptureCount() {
        captureCountView.visibility = if (capturedCount == 0) View.GONE else View.VISIBLE
        captureCountView.text = "$capturedCount saved"
    }

    private fun animateShutterPress() {
        shutterButton.animate().cancel()
        shutterButton.animate()
            .scaleX(0.96f)
            .scaleY(0.96f)
            .alpha(0.88f)
            .setDuration(60)
            .withEndAction {
                shutterButton.animate()
                    .scaleX(1f)
                    .scaleY(1f)
                    .alpha(1f)
                    .setDuration(90)
                    .start()
            }
            .start()
    }

    private fun playCaptureSuccessFeedback() {
        shutterButton.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)

        flashOverlayView.animate().cancel()
        flashOverlayView.alpha = 0f
        flashOverlayView.animate()
            .alpha(0.18f)
            .setDuration(45)
            .withEndAction {
                flashOverlayView.animate()
                    .alpha(0f)
                    .setDuration(110)
                    .start()
            }
            .start()

        captureCountView.animate().cancel()
        captureCountView.scaleX = 1f
        captureCountView.scaleY = 1f
        captureCountView.alpha = 1f
        captureCountView.animate()
            .scaleX(1.06f)
            .scaleY(1.06f)
            .alpha(0.95f)
            .setDuration(90)
            .withEndAction {
                captureCountView.animate()
                    .scaleX(1f)
                    .scaleY(1f)
                    .alpha(1f)
                    .setDuration(140)
                    .start()
            }
            .start()
    }

    private fun applyZoomRatio(targetZoom: Float, emitPreviewReady: Boolean) {
        val boundCamera = camera ?: return
        boundCamera.cameraControl.setZoomRatio(targetZoom)
        currentZoomRatio = targetZoom
        zoomButtons.forEach { button ->
            val stop = button.tag as? Float
            button.setSelectedStyle(stop != null && abs(stop - targetZoom) < 0.05f)
        }
        if (emitPreviewReady && !previewReadySent) {
            previewReadySent = true
            NativeCameraBridge.emit(
                sessionEvent(
                    type = "previewReady",
                    openDurationMs = (SystemClock.elapsedRealtime() - openedAtMs).toInt(),
                ),
            )
        }
    }

    private fun emitFailure(message: String) {
        NativeCameraBridge.emit(sessionEvent(type = "captureFailed", message = message))
    }

    private fun selectTarget(popup: PopupWindow, option: CaptureTargetOption) {
        currentTarget = option
        updateTargetButton()
        NativeCameraBridge.emit(
            sessionEvent(
                type = "targetChanged",
                targetMode = option.mode.wireValue,
                targetProjectId = option.resolvedProjectId,
                targetProjectName = option.resolvedProjectName,
                fixedProjectId = option.fixedProjectId,
            ),
        )
        popup.dismiss()
    }

    private fun createOutputFile(photoId: String): File {
        val sessionId = launchConfig?.sessionId ?: "default"
        val outputDir = File(filesDir, "captures/$sessionId").apply { mkdirs() }
        return File(outputDir, "$photoId.jpg")
    }

    private fun sessionEvent(
        type: String,
        message: String? = null,
        photoId: String? = null,
        localPath: String? = null,
        targetMode: String? = null,
        targetProjectId: Int? = null,
        targetProjectName: String? = null,
        fixedProjectId: Int? = null,
        capturedAt: String? = null,
        openDurationMs: Int? = null,
        captureDurationMs: Int? = null,
        capturedCount: Int? = null,
        settings: Map<String, Any?>? = null,
    ): Map<String, Any?> {
        return mutableMapOf<String, Any?>(
            "type" to type,
            "sessionId" to launchConfig?.sessionId,
            "message" to message,
            "photoId" to photoId,
            "localPath" to localPath,
            "targetMode" to targetMode,
            "targetProjectId" to targetProjectId,
            "targetProjectName" to targetProjectName,
            "fixedProjectId" to fixedProjectId,
            "capturedAt" to capturedAt,
            "openDurationMs" to openDurationMs,
            "captureDurationMs" to captureDurationMs,
            "capturedCount" to capturedCount,
            "settings" to settings,
        ).filterValues { it != null }
    }

    private fun createTextPillButton(label: String): AppCompatButton {
        return AppCompatButton(this).apply {
            text = label
            isAllCaps = false
            setTextColor(Color.WHITE)
            ellipsize = TextUtils.TruncateAt.END
            maxLines = 1
            background = pillBackground(selected = false)
            setPadding(dp(14), dp(10), dp(14), dp(10))
        }
    }

    private fun createZoomPillButton(label: String): AppCompatButton {
        return createTextPillButton(label).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            minWidth = 0
            minimumWidth = 0
            minHeight = 0
            minimumHeight = 0
            setPadding(dp(8), dp(4), dp(8), dp(4))
        }
    }

    private fun createTargetButton(label: String): AppCompatButton {
        return createTextPillButton(label).apply {
            maxWidth = dp(240)
            compoundDrawablePadding = dp(8)
            minWidth = dp(96)
        }
    }

    private fun createIconButton(iconRes: Int, contentDescription: String): AppCompatImageButton {
        return AppCompatImageButton(this).apply {
            setImageDrawable(tintedDrawable(iconRes))
            this.contentDescription = contentDescription
            background = circleBackground(selected = false)
            scaleType = ImageView.ScaleType.CENTER
            setPadding(dp(12), dp(12), dp(12), dp(12))
        }
    }

    private fun createShutterButton(): FrameLayout {
        return FrameLayout(this).apply {
            isClickable = true
            isFocusable = true
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(0x1AFFFFFF)
                setStroke(dp(3), Color.WHITE)
            }
            addView(
                View(this@NativeCameraActivity).apply {
                    background = GradientDrawable().apply {
                        shape = GradientDrawable.OVAL
                        setColor(Color.WHITE)
                    }
                },
                FrameLayout.LayoutParams(dp(64), dp(64), Gravity.CENTER),
            )
        }
    }

    private fun createCompactTargetRow(
        iconRes: Int,
        title: String,
        selected: Boolean = false,
        onClick: () -> Unit,
    ): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = pillBackground(selected)
            setPadding(dp(12), dp(10), dp(12), dp(10))
            isClickable = true
            isFocusable = true
            setOnClickListener { onClick() }
            addView(
                ImageView(this@NativeCameraActivity).apply {
                    setImageDrawable(
                        tintedDrawable(iconRes, if (selected) Color.BLACK else Color.WHITE),
                    )
                },
                LinearLayout.LayoutParams(dp(20), dp(20)),
            )
            addView(space(dp(10)))
            addView(
                TextView(this@NativeCameraActivity).apply {
                    text = title
                    maxLines = 1
                    ellipsize = TextUtils.TruncateAt.END
                    setTextColor(if (selected) Color.BLACK else Color.WHITE)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                    setTypeface(typeface, android.graphics.Typeface.BOLD)
                },
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
            )
            if (selected) {
                addView(
                    ImageView(this@NativeCameraActivity).apply {
                        setImageDrawable(tintedDrawable(R.drawable.ic_joblens_check_24, Color.BLACK))
                    },
                    LinearLayout.LayoutParams(dp(18), dp(18)),
                )
            }
        }
    }

    private fun tintedDrawable(resId: Int, tint: Int = Color.WHITE) =
        AppCompatResources.getDrawable(this, resId)?.mutate()?.also { drawable ->
            DrawableCompat.setTint(drawable, tint)
        }

    private fun AppCompatButton.setSelectedStyle(selected: Boolean) {
        background = pillBackground(selected)
        setTextColor(if (selected) Color.BLACK else Color.WHITE)
    }

    private fun AppCompatImageButton.setSelectedStyle(selected: Boolean) {
        background = circleBackground(selected)
    }

    private fun pillBackground(selected: Boolean): GradientDrawable {
        return GradientDrawable().apply {
            cornerRadius = dp(20).toFloat()
            setColor(if (selected) Color.WHITE else 0x99000000.toInt())
            setStroke(dp(1), if (selected) Color.WHITE else 0x55FFFFFF.toInt())
        }
    }

    private fun circleBackground(selected: Boolean): GradientDrawable {
        return GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(if (selected) Color.WHITE else 0x99000000.toInt())
            setStroke(dp(1), if (selected) Color.WHITE else 0x55FFFFFF.toInt())
        }
    }

    private fun dropdownSearchBackground(): GradientDrawable {
        return GradientDrawable().apply {
            cornerRadius = dp(16).toFloat()
            setColor(0x33000000)
            setStroke(dp(1), 0x33FFFFFF)
        }
    }

    private fun dropdownPanelBackground(): GradientDrawable {
        return GradientDrawable().apply {
            cornerRadius = dp(22).toFloat()
            setColor(0xF21A1A1A.toInt())
            setStroke(dp(1), 0x33FFFFFF)
        }
    }

    private fun space(widthPx: Int): View {
        return View(this).apply {
            layoutParams = LinearLayout.LayoutParams(widthPx, 1)
        }
    }

    private fun verticalSpace(heightPx: Int): View {
        return View(this).apply {
            layoutParams = LinearLayout.LayoutParams(1, heightPx)
        }
    }

    private fun dp(value: Int): Int {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            resources.displayMetrics,
        ).toInt()
    }

    private fun formatZoom(zoom: Float): String {
        val rounded = zoom.toInt().toFloat()
        return if (abs(zoom - rounded) < 0.05f) {
            rounded.toInt().toString()
        } else {
            String.format(Locale.US, "%.1f", zoom)
        }
    }

    private fun isoNow(): String {
        return SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US).format(Date())
    }
}

private data class CameraLaunchConfig(
    val sessionId: String,
    val currentMode: CaptureTargetMode,
    val currentProjectId: Int,
    val currentProjectName: String,
    val targets: List<CaptureTargetOption>,
    val settings: CameraSettingsConfig,
) {
    fun resolveCurrentTarget(): CaptureTargetOption {
        return targets.firstOrNull { option ->
            when (currentMode) {
                CaptureTargetMode.FIXED_PROJECT,
                CaptureTargetMode.LAST_USED,
                -> option.mode == CaptureTargetMode.FIXED_PROJECT &&
                    option.fixedProjectId == currentProjectId
                CaptureTargetMode.INBOX -> option.mode == CaptureTargetMode.INBOX
            }
        } ?: targets.first()
    }

    companion object {
        fun fromPayload(payload: String): CameraLaunchConfig {
            val json = JSONObject(payload)
            val targetsJson = json.getJSONArray("targets")
            val targets = buildList {
                for (index in 0 until targetsJson.length()) {
                    add(CaptureTargetOption.fromJson(targetsJson.getJSONObject(index)))
                }
            }
            return CameraLaunchConfig(
                sessionId = json.getString("sessionId"),
                currentMode = CaptureTargetMode.fromWire(json.optString("currentMode")),
                currentProjectId = json.getInt("currentProjectId"),
                currentProjectName = json.getString("currentProjectName"),
                targets = targets,
                settings = CameraSettingsConfig.fromJson(json.getJSONObject("settings")),
            )
        }
    }
}

private data class CaptureTargetOption(
    val mode: CaptureTargetMode,
    val label: String,
    val resolvedProjectId: Int,
    val resolvedProjectName: String,
    val fixedProjectId: Int?,
) {
    companion object {
        fun fromJson(json: JSONObject): CaptureTargetOption {
            return CaptureTargetOption(
                mode = CaptureTargetMode.fromWire(json.optString("mode")),
                label = json.optString("label"),
                resolvedProjectId = json.getInt("resolvedProjectId"),
                resolvedProjectName = json.getString("resolvedProjectName"),
                fixedProjectId = json.optInt("fixedProjectId").takeIf { it != 0 || json.has("fixedProjectId") },
            )
        }
    }
}

private data class CameraSettingsConfig(
    val flashMode: Int,
    val lensFacing: Int,
    val zoomStop: Float,
) {
    companion object {
        fun fromJson(json: JSONObject): CameraSettingsConfig {
            return CameraSettingsConfig(
                flashMode = when (json.optString("flashMode")) {
                    "auto" -> ImageCapture.FLASH_MODE_AUTO
                    "always" -> ImageCapture.FLASH_MODE_ON
                    else -> ImageCapture.FLASH_MODE_OFF
                },
                lensFacing = when (json.optString("lensDirection")) {
                    "front" -> CameraSelector.LENS_FACING_FRONT
                    else -> CameraSelector.LENS_FACING_BACK
                },
                zoomStop = json.optDouble("zoomStop", 1.0).toFloat(),
            )
        }
    }
}

private enum class CaptureTargetMode(val wireValue: String) {
    INBOX("inbox"),
    LAST_USED("last_used"),
    FIXED_PROJECT("fixed_project");

    companion object {
        fun fromWire(value: String?): CaptureTargetMode {
            return values().firstOrNull { it.wireValue == value } ?: INBOX
        }
    }
}

private fun Int.toFlutterName(): String {
    return when (this) {
        ImageCapture.FLASH_MODE_AUTO -> "auto"
        ImageCapture.FLASH_MODE_ON -> "always"
        else -> "off"
    }
}

private fun Int.toFlutterLensName(): String {
    return if (this == CameraSelector.LENS_FACING_FRONT) "front" else "back"
}

private fun ProcessCameraProvider.safeHasCamera(selector: CameraSelector): Boolean {
    return try {
        hasCamera(selector)
    } catch (_: Exception) {
        false
    }
}
