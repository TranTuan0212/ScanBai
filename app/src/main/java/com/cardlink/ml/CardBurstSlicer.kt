package com.cardlink.ml

import android.graphics.Bitmap
import android.util.Base64
import android.util.Log
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentLinkedDeque

/**
 * Card Video Deal Burst Slicer
 * Records high-frame-rate burst windows during card deals, evaluates sharpness of all frames,
 * and extracts the absolute sharpest, crystal-clear frame slice for each dealt card.
 */
class CardBurstSlicer(
    private val bufferSize: Int = 12,
    private val minSharpnessThreshold: Double = 30.0
) {

    private data class FrameCandidate(
        val bitmap: Bitmap,
        val sharpness: Double,
        val detection: Detection?,
        val timestamp: Long
    )

    private val frameRingBuffer = ConcurrentLinkedDeque<FrameCandidate>()
    private var isBurstActive = false
    private var burstCandidates = mutableListOf<FrameCandidate>()
    private var lastSliceEmitTime = 0L

    /**
     * Push incoming camera stream frame into the continuous buffer
     */
    @Synchronized
    fun addFrame(bitmap: Bitmap, detection: Detection?): Pair<Detection, String>? {
        val now = System.currentTimeMillis()
        val sharpness = FrameSharpnessEvaluator.calculateSharpness(bitmap)

        // IMPORTANT: copy the bitmap. The caller's bitmap (e.g. from a CameraX
        // ImageAnalysis.Analyzer) may be recycled/overwritten as soon as this
        // function returns, so holding the original reference in a buffer that
        // is read back later (after several more frames) can silently return
        // stale/incorrect pixel data.
        val safeCopy = bitmap.copy(bitmap.config ?: Bitmap.Config.ARGB_8888, false)

        val candidate = FrameCandidate(
            bitmap = safeCopy,
            sharpness = sharpness,
            detection = detection,
            timestamp = now
        )

        // Maintain rolling ring buffer
        frameRingBuffer.addLast(candidate)
        while (frameRingBuffer.size > bufferSize) {
            val evicted = frameRingBuffer.pollFirst()
            // Only recycle if it isn't also referenced by an active burst
            if (evicted != null && !burstCandidates.contains(evicted)) {
                evicted.bitmap.recycle()
            }
        }

        // Check if a card is currently visible in this frame
        val hasCard = detection != null && detection.confidence >= 0.65f

        if (hasCard) {
            if (!isBurstActive) {
                // Card just entered FOV: Start a new burst collection window
                isBurstActive = true
                burstCandidates.clear()
                // Include recent frames before detection for context
                frameRingBuffer.forEach { burstCandidates.add(it) }
            } else {
                burstCandidates.add(candidate)
            }
        } else {
            // Card left FOV or deal motion completed: Settle burst and extract the sharpest frame slice!
            if (isBurstActive && burstCandidates.isNotEmpty()) {
                isBurstActive = false

                if (now - lastSliceEmitTime >= 220L) {
                    val best = findSharpestCardSlice(burstCandidates)
                    recycleDiscarded(burstCandidates, best)
                    burstCandidates.clear()

                    if (best != null && best.detection != null) {
                        lastSliceEmitTime = now
                        val imageBase64 = createCardSliceBase64(best.bitmap)
                        best.bitmap.recycle()
                        Log.d("CardBurstSlicer", "🎬 [BURST SLICE EXTRACTED] Card: ${best.detection.label} (Sharpness: ${best.sharpness})")
                        return Pair(best.detection, imageBase64 ?: "")
                    }
                } else {
                    recycleDiscarded(burstCandidates, null)
                    burstCandidates.clear()
                }
            }
        }

        // If burst has grown long (>10 frames of continuous card), extract intermediate best slice
        if (isBurstActive && burstCandidates.size >= 8 && (now - lastSliceEmitTime >= 350L)) {
            val best = findSharpestCardSlice(burstCandidates)
            recycleDiscarded(burstCandidates, best)
            burstCandidates.clear()

            if (best != null && best.detection != null) {
                lastSliceEmitTime = now
                val imageBase64 = createCardSliceBase64(best.bitmap)
                best.bitmap.recycle()
                Log.d("CardBurstSlicer", "🎬 [INTERMEDIATE SLICE EXTRACTED] Card: ${best.detection.label} (Sharpness: ${best.sharpness})")
                return Pair(best.detection, imageBase64 ?: "")
            }
        }

        return null
    }

    /**
     * Finds the candidate with the highest Laplacian variance for THIS card.
     *
     * Pre-roll frames added at burst start (from frameRingBuffer) can belong to
     * a different, previously-dealt card if it left the frame only a moment
     * earlier. If we picked purely by sharpness across all candidates, a sharp
     * leftover frame of the *previous* card could get returned with the
     * *current* card's label attached to it (or vice versa). So: first lock in
     * which label this burst is actually about (the most frequent non-null
     * label with a detection), then only consider frames carrying that label.
     */
    private fun findSharpestCardSlice(candidates: List<FrameCandidate>): FrameCandidate? {
        val withDetection = candidates.filter { it.detection != null }
        if (withDetection.isEmpty()) return null

        val dominantLabel = withDetection
            .groupingBy { it.detection!!.label }
            .eachCount()
            .maxByOrNull { it.value }
            ?.key ?: return null

        val sameCard = withDetection.filter { it.detection!!.label == dominantLabel }

        val validCards = sameCard.filter { it.sharpness >= minSharpnessThreshold }
        return if (validCards.isNotEmpty()) {
            validCards.maxByOrNull { it.sharpness }
        } else {
            sameCard.maxByOrNull { it.sharpness }
        }
    }

    /**
     * Recycles the bitmap copies held by [discarded] burst candidates, since we
     * now own a private copy of every frame (see addFrame). Skips anything
     * still referenced by [keep] (the frame we're about to encode/emit) or
     * still sitting in frameRingBuffer (still needed as future pre-roll).
     */
    private fun recycleDiscarded(discarded: List<FrameCandidate>, keep: FrameCandidate?) {
        for (candidate in discarded) {
            if (candidate === keep) continue
            if (frameRingBuffer.contains(candidate)) continue
            candidate.bitmap.recycle()
        }
    }

    /**
     * Creates a high-clarity JPEG Base64 data URI of the sliced card frame
     */
    private fun createCardSliceBase64(bitmap: Bitmap): String? {
        return try {
            val scaled = Bitmap.createScaledBitmap(bitmap, 320, 240, true)
            val outputStream = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 75, outputStream)
            val bytes = outputStream.toByteArray()
            "data:image/jpeg;base64," + Base64.encodeToString(bytes, Base64.NO_WRAP)
        } catch (e: Exception) {
            Log.e("CardBurstSlicer", "Failed to compress card slice", e)
            null
        }
    }

    @Synchronized
    fun reset() {
        val all = (frameRingBuffer.toList() + burstCandidates).distinct()
        all.forEach { it.bitmap.recycle() }
        frameRingBuffer.clear()
        burstCandidates.clear()
        isBurstActive = false
        lastSliceEmitTime = 0L
    }
}
