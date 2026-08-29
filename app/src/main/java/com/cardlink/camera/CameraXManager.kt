package com.cardlink.camera

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.hardware.camera2.CaptureRequest
import android.util.Log
import android.util.Size
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class CameraXManager(private val context: Context) {

    private var cameraProvider: ProcessCameraProvider? = null
    private var preview: Preview? = null
    private var imageAnalysis: ImageAnalysis? = null
    private var camera: Camera? = null

    private var lensFacing = CameraSelector.LENS_FACING_BACK
    private var isTorchOn = false
    private var currentLifecycleOwner: LifecycleOwner? = null
    private var currentPreviewView: PreviewView? = null
    private var onFrameAnalyzed: ((Bitmap) -> Unit)? = null

    private val cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    fun initialize(lifecycleOwner: LifecycleOwner, onFrame: (Bitmap) -> Unit) {
        this.currentLifecycleOwner = lifecycleOwner
        this.onFrameAnalyzed = onFrame

        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)
        cameraProviderFuture.addListener({
            try {
                cameraProvider = cameraProviderFuture.get()
                bindCameraUseCases()
            } catch (e: Exception) {
                Log.e("CameraXManager", "Failed to initialize CameraProvider", e)
            }
        }, ContextCompat.getMainExecutor(context))
    }

    /**
     * Attach UI PreviewView when Activity is open
     */
    fun attachPreviewView(previewView: PreviewView) {
        this.currentPreviewView = previewView
        preview?.setSurfaceProvider(previewView.surfaceProvider)
    }

    /**
     * Detach UI PreviewView when Activity stops/screen turns off
     */
    fun detachPreviewView() {
        this.currentPreviewView = null
        preview?.setSurfaceProvider(null)
    }

    /**
     * Toggle torch light manually
     */
    fun toggleTorch(): Boolean {
        isTorchOn = !isTorchOn
        camera?.cameraControl?.enableTorch(isTorchOn)
        return isTorchOn
    }

    fun isTorchActive(): Boolean = isTorchOn

    /**
     * Switch camera between Front and Back during live streaming
     */
    fun switchCamera() {
        lensFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK) {
            CameraSelector.LENS_FACING_FRONT
        } else {
            CameraSelector.LENS_FACING_BACK
        }
        bindCameraUseCases()
    }

    val isFrontCamera: Boolean
        get() = lensFacing == CameraSelector.LENS_FACING_FRONT

    @OptIn(ExperimentalCamera2Interop::class)
    private fun bindCameraUseCases() {
        val provider = cameraProvider ?: return
        val lifecycleOwner = currentLifecycleOwner ?: return

        try {
            provider.unbindAll()

            val cameraSelector = CameraSelector.Builder()
                .requireLensFacing(lensFacing)
                .build()

            // Discover camera characteristics, 4K Ultra HD capability & highest available FPS range (60 / 120 / 240 FPS)
            val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as? android.hardware.camera2.CameraManager
            val cameraIdList = cameraManager?.cameraIdList ?: emptyArray()
            var maxFpsRange: android.util.Range<Int>? = null
            var isOisSupported = false
            var isEisSupported = false
            var maxSupportedResolution = Size(1920, 1080) // Default 1080p Full HD

            for (cId in cameraIdList) {
                val characteristics = cameraManager?.getCameraCharacteristics(cId) ?: continue
                val facing = characteristics.get(android.hardware.camera2.CameraCharacteristics.LENS_FACING)
                val targetFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK) {
                    android.hardware.camera2.CameraCharacteristics.LENS_FACING_BACK
                } else {
                    android.hardware.camera2.CameraCharacteristics.LENS_FACING_FRONT
                }

                if (facing == targetFacing) {
                    // 1. Query Standard & High-Speed FPS Ranges (60 FPS, 120 FPS, 240 FPS)
                    val fpsRanges = characteristics.get(android.hardware.camera2.CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                    fpsRanges?.forEach { range ->
                        Log.d("CameraXManager", "🔍 Found camera FPS range: [${range.lower}, ${range.upper}]")
                        if (maxFpsRange == null || range.upper > maxFpsRange!!.upper || (range.upper == maxFpsRange!!.upper && range.lower > maxFpsRange!!.lower)) {
                            maxFpsRange = range
                        }
                    }

                    // Query High-Speed Video FPS Ranges (120 FPS / 240 FPS)
                    val streamMap = characteristics.get(android.hardware.camera2.CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                    try {
                        val highSpeedRanges = streamMap?.highSpeedVideoFpsRanges
                        highSpeedRanges?.forEach { hsRange ->
                            Log.d("CameraXManager", "⚡ Found High-Speed Video FPS range: [${hsRange.lower}, ${hsRange.upper}]")
                            if (maxFpsRange == null || hsRange.upper > maxFpsRange!!.upper || (hsRange.upper == maxFpsRange!!.upper && hsRange.lower > maxFpsRange!!.lower)) {
                                maxFpsRange = hsRange
                            }
                        }
                    } catch (e: Exception) {
                        Log.w("CameraXManager", "High-Speed FPS query fallback: ${e.message}")
                    }

                    // 2. Query 4K Ultra HD (3840x2160) Output Resolution
                    try {
                        val outputSizes = streamMap?.getOutputSizes(android.graphics.ImageFormat.JPEG)
                        outputSizes?.forEach { size ->
                            if (size.width >= 3840 && size.height >= 2160) {
                                maxSupportedResolution = Size(3840, 2160) // 4K Ultra HD
                            } else if (size.width >= 2560 && maxSupportedResolution.width < 2560) {
                                maxSupportedResolution = Size(2560, 1440) // 2.7K Quad HD
                            }
                        }
                    } catch (e: Exception) {
                        Log.w("CameraXManager", "4K Output Size query fallback: ${e.message}")
                    }

                    // 3. Query Optical / Video Stabilization
                    val videoStabModes = characteristics.get(android.hardware.camera2.CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES)
                    isEisSupported = videoStabModes?.contains(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON) == true

                    val opticalStabModes = characteristics.get(android.hardware.camera2.CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION)
                    isOisSupported = opticalStabModes?.contains(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON) == true

                    break
                }
            }

            Log.i("CameraXManager", "🚀 AUTO ULTRA HARDWARE ACCELERATION SETUP:")
            Log.i("CameraXManager", "   - Max Resolution: ${maxSupportedResolution.width}x${maxSupportedResolution.height} (${if (maxSupportedResolution.width >= 3840) "4K Ultra HD" else "Full HD"})")
            Log.i("CameraXManager", "   - Target FPS Range: ${maxFpsRange?.toString() ?: "Default"} (Supports 60/120/240 FPS)")
            Log.i("CameraXManager", "   - Optical Stabilization (OIS): $isOisSupported | EIS: $isEisSupported")

            // 1. Preview Use Case (Target 4K UHD or 1080p / High FPS)
            val previewBuilder = Preview.Builder()
                .setTargetResolution(maxSupportedResolution)

            val previewCamera2Extender = Camera2Interop.Extender(previewBuilder)
            maxFpsRange?.let {
                previewCamera2Extender.setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it)
            }
            if (isOisSupported) {
                previewCamera2Extender.setCaptureRequestOption(CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE, CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON)
            } else if (isEisSupported) {
                previewCamera2Extender.setCaptureRequestOption(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON)
            }

            preview = previewBuilder.build()
            currentPreviewView?.let {
                preview?.setSurfaceProvider(it.surfaceProvider)
            }

            // 2. ImageAnalysis Use Case for Background AI Vision (High Speed / High Sharpness)
            val analysisBuilder = ImageAnalysis.Builder()
                .setTargetResolution(Size(1920, 1080))
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)

            val analysisCamera2Extender = Camera2Interop.Extender(analysisBuilder)
            analysisCamera2Extender.setCaptureRequestOption(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
            analysisCamera2Extender.setCaptureRequestOption(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            analysisCamera2Extender.setCaptureRequestOption(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            analysisCamera2Extender.setCaptureRequestOption(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_AUTO)

            // Enable High Quality Edge Enhancement & Noise Reduction for crisp card reading
            analysisCamera2Extender.setCaptureRequestOption(CaptureRequest.EDGE_MODE, CaptureRequest.EDGE_MODE_HIGH_QUALITY)
            analysisCamera2Extender.setCaptureRequestOption(CaptureRequest.NOISE_REDUCTION_MODE, CaptureRequest.NOISE_REDUCTION_MODE_HIGH_QUALITY)

            maxFpsRange?.let {
                analysisCamera2Extender.setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it)
            }

            imageAnalysis = analysisBuilder.build()

            imageAnalysis?.setAnalyzer(cameraExecutor) { imageProxy ->
                try {
                    val bitmap = imageProxyToBitmap(imageProxy)
                    if (bitmap != null) {
                        onFrameAnalyzed?.invoke(bitmap)
                    }
                } catch (e: Exception) {
                    Log.e("CameraXManager", "Error analyzing image frame", e)
                } finally {
                    imageProxy.close()
                }
            }

            // Bind to the Service LifecycleOwner (LiveForegroundService) so it NEVER stops when screen locks
            camera = provider.bindToLifecycle(
                lifecycleOwner,
                cameraSelector,
                preview,
                imageAnalysis
            )

            // Boost Exposure Compensation (+2 stops if supported) to ensure bright indoor lighting
            try {
                camera?.cameraInfo?.exposureState?.let { expState ->
                    if (expState.isExposureCompensationSupported) {
                        val upper = expState.exposureCompensationRange.upper
                        val boostIndex = (upper / 2).coerceIn(1, upper)
                        camera?.cameraControl?.setExposureCompensationIndex(boostIndex)
                        Log.d("CameraXManager", "☀️ Boosted exposure compensation to index: $boostIndex for clear indoor lighting")
                    }
                }
            } catch (e: Exception) {
                Log.w("CameraXManager", "Exposure boost not applied: ${e.message}")
            }

            // Restore previous torch state
            camera?.cameraControl?.enableTorch(isTorchOn)

            Log.d("CameraXManager", "✅ CameraX successfully bound with highest FPS (${maxFpsRange}), Auto-Exposure boost, and Edge Enhancement")
        } catch (e: Exception) {
            Log.e("CameraXManager", "Use case binding failed", e)
        }
    }

    /**
     * Converts ImageProxy to a correctly oriented upright Bitmap
     */
    private fun imageProxyToBitmap(image: ImageProxy): Bitmap? {
        val rawBitmap = image.toBitmap() ?: return null
        val rotation = image.imageInfo.rotationDegrees

        return if (rotation != 0) {
            val matrix = Matrix().apply { postRotate(rotation.toFloat()) }
            Bitmap.createBitmap(rawBitmap, 0, 0, rawBitmap.width, rawBitmap.height, matrix, true)
        } else {
            rawBitmap
        }
    }

    fun shutdown() {
        camera?.cameraControl?.enableTorch(false)
        cameraProvider?.unbindAll()
        cameraExecutor.shutdown()
    }
}
