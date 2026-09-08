package com.buzing.buzing_crowd_detection

import android.annotation.SuppressLint
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.buzing.camera/ultra_wide"
    }

    @SuppressLint("MissingPermission")
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "getFocalLengths") {
                    try {
                        val cameraManager = getSystemService(CAMERA_SERVICE) as CameraManager
                        val focalMap = mutableMapOf<String, List<Double>>()

                        for (id in cameraManager.cameraIdList) {
                            val chars = cameraManager.getCameraCharacteristics(id)
                            val facing = chars.get(CameraCharacteristics.LENS_FACING)
                            // LENS_FACING_BACK == 0
                            if (facing == CameraCharacteristics.LENS_FACING_BACK) {
                                val focalLengths =
                                    chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                                if (focalLengths != null) {
                                    focalMap[id] = focalLengths.map { it.toDouble() }
                                }
                            }
                        }
                        result.success(focalMap)
                    } catch (e: Exception) {
                        result.error("NATIVE_ERROR", e.message, null)
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}
