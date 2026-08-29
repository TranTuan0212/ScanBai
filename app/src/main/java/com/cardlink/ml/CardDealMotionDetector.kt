package com.cardlink.ml

import android.graphics.Bitmap
import android.graphics.Color
import android.util.Base64
import android.util.Log
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentLinkedDeque

/**
 * Continuous Rolling High-Speed Card Photo Slicer
 * 1. Continuously captures and evaluates every frame at full camera FPS
 * 2. Continuously filters and extracts the sharpest photo candidate (Peak Laplacian Variance)
 * 3. Immediately emits the crystal-clear real photo into sequential slots (#1, #2, #3...)
 */
class CardDealMotionDetector(
    private val onCardDealCaptured: (slotNumber: Int, imageBase64: String) -> Unit
) {

    private data class CandidateFrame(
        val bitmap: Bitmap,
        val sharpness: Double,
        val timestamp: Long
    )

    private val rollingWindow = ConcurrentLinkedDeque<CandidateFrame>()
    private var lastFrameSample: IntArray? = null
    private var isPeelActive = false
    private var currentDealSlot = 0
    private var lastEmitTime = 0L

    private val sampleWidth = 32
    private val sampleHeight = 24

    /**
     * Process each incoming camera frame continuously (30-60 FPS)
     */
    @Synchronized
    fun processFrame(bitmap: Bitmap) {
        val now = System.currentTimeMillis()
        val sharpness = FrameSharpnessEvaluator.calculateSharpness(bitmap)

        // Add frame to continuous rolling buffer
        val candidate = CandidateFrame(bitmap, sharpness, now)
        rollingWindow.addLast(candidate)
        while (rollingWindow.size > 15) {
            rollingWindow.pollFirst()
        }

        // Measure optical frame difference
        val motionMagnitude = computeMotionMagnitude(bitmap)
        val hasMotion = motionMagnitude > 14.0

        if (hasMotion) {
            isPeelActive = true
        } else {
            // Motion settled: Extract the sharpest frame from the burst window
            if (isPeelActive && rollingWindow.isNotEmpty()) {
                isPeelActive = false
                if (now - lastEmitTime >= 300L) {
                    emitPeakFrame(now)
                }
            }
        }

        // Safety periodic trigger: If continuous dealing motion lasts >400ms, extract peak frame
        if (isPeelActive && (now - lastEmitTime >= 400L) && rollingWindow.size >= 8) {
            emitPeakFrame(now)
        }
    }

    /**
     * Extracts the frame with the maximum Laplacian sharpness in the rolling buffer
     */
    private fun emitPeakFrame(now: Long) {
        val candidates = rollingWindow.toList()
        if (candidates.isEmpty()) return

        val peakCandidate = candidates.maxByOrNull { it.sharpness } ?: candidates.last()
        val imageBase64 = encodeFrameToBase64(peakCandidate.bitmap)

        if (imageBase64 != null) {
            currentDealSlot++
            lastEmitTime = now
            Log.d("CardDealMotionDetector", "📸 [PEAK PHOTO EMITTED] Slot #$currentDealSlot (Sharpness: ${peakCandidate.sharpness})")
            onCardDealCaptured(currentDealSlot, imageBase64)
        }
    }

    /**
     * Manual 1-Tap Snapshot Trigger
     */
    @Synchronized
    fun manualCapture(bitmap: Bitmap) {
        val now = System.currentTimeMillis()
        val imageBase64 = encodeFrameToBase64(bitmap)
        if (imageBase64 != null) {
            currentDealSlot++
            lastEmitTime = now
            Log.d("CardDealMotionDetector", "📸 [MANUAL SNAP EMITTED] Slot #$currentDealSlot")
            onCardDealCaptured(currentDealSlot, imageBase64)
        }
    }

    private fun encodeFrameToBase64(bitmap: Bitmap): String? {
        return try {
            val scaled = Bitmap.createScaledBitmap(bitmap, 360, 270, true)
            val outputStream = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 78, outputStream)
            val bytes = outputStream.toByteArray()
            "data:image/jpeg;base64," + Base64.encodeToString(bytes, Base64.NO_WRAP)
        } catch (e: Exception) {
            Log.e("CardDealMotionDetector", "Failed to encode frame", e)
            null
        }
    }

    private fun computeMotionMagnitude(bitmap: Bitmap): Double {
        return try {
            val small = Bitmap.createScaledBitmap(bitmap, sampleWidth, sampleHeight, false)
            val currentPixels = IntArray(sampleWidth * sampleHeight)
            small.getPixels(currentPixels, 0, sampleWidth, 0, 0, sampleWidth, sampleHeight)

            val previous = lastFrameSample
            lastFrameSample = currentPixels

            if (previous == null || previous.size != currentPixels.size) {
                return 0.0
            }

            var totalDiff = 0.0
            for (i in currentPixels.indices) {
                val p1 = currentPixels[i]
                val p2 = previous[i]
                val diff = Math.abs(Color.red(p1) - Color.red(p2)) +
                        Math.abs(Color.green(p1) - Color.green(p2)) +
                        Math.abs(Color.blue(p1) - Color.blue(p2))
                totalDiff += diff / 3.0
            }

            totalDiff / currentPixels.size
        } catch (_: Exception) {
            0.0
        }
    }

    @Synchronized
    fun reset() {
        rollingWindow.clear()
        isPeelActive = false
        currentDealSlot = 0
        lastEmitTime = 0L
        lastFrameSample = null
    }
}
