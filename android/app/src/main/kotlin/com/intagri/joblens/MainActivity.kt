package com.intagri.joblens

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NativeCameraBridge.METHOD_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openCamera" -> {
                    val payload = call.arguments as? String
                    if (payload.isNullOrBlank()) {
                        result.error(
                            "invalid_arguments",
                            "Camera payload was missing.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    startActivity(
                        Intent(this, NativeCameraActivity::class.java).putExtra(
                            NativeCameraActivity.EXTRA_CONFIG,
                            payload,
                        ),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NativeCameraBridge.EVENT_CHANNEL,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    NativeCameraBridge.eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    NativeCameraBridge.eventSink = null
                }
            },
        )
    }
}

object NativeCameraBridge {
    const val METHOD_CHANNEL = "com.intagri.joblens/native_camera"
    const val EVENT_CHANNEL = "com.intagri.joblens/native_camera/events"

    @Volatile
    var eventSink: EventChannel.EventSink? = null

    fun emit(event: Map<String, Any?>) {
        eventSink?.success(event)
    }
}
