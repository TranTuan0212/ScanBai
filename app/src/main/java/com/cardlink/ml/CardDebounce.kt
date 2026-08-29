package com.cardlink.ml

import android.graphics.Bitmap
import android.util.Base64
import android.util.Log
import java.io.ByteArrayOutputStream

/**
 * Card Detection Debounce Engine
 *
 * Implements the state machine required by spec:
 *   NoCard ↔ CardActive(label)
 *
 * Rules:
 *  1. Flicker Rejection  : A new label must appear for ≥ 3 consecutive frames
 *                          AND ≥ 100ms before it is accepted.
 *  2. Confidence Gate    : confidence must be ≥ 0.75 (aligned with TFLiteDetector).
 *  3. Deck Uniqueness    : Each card label emitted only once per round.
 *  4. NoCard Reset       : 1.5 s with no valid detection → state returns to NoCard.
 *  5. Min emit interval  : 150 ms between two consecutive card emissions.
 */
class CardDebounce(
    private val confidenceThreshold: Float = 0.75f,
    private val onNewCard: (String, String?) -> Unit // label, imageBase64
) {

    // ── State Machine ──────────────────────────────────────────────────────────

    private sealed class State {
        object NoCard : State()
        data class Candidate(val label: String, val frameCount: Int, val firstSeenMs: Long) : State()
        data class CardActive(val label: String) : State()
    }

    private var state: State = State.NoCard

    // ── Deck tracking ──────────────────────────────────────────────────────────

    private val dealtCardsInDeck = mutableSetOf<String>()
    private var lastEmittedTime = 0L
    private var lastValidDetectionTime = 0L

    companion object {
        private const val REQUIRED_FRAMES = 3
        private const val REQUIRED_MS    = 100L
        private const val NO_CARD_TIMEOUT_MS = 1_500L
        private const val MIN_EMIT_INTERVAL_MS = 150L
        private const val TAG = "CardDebounce"
    }

    /**
     * Called for every camera frame with the raw TFLite detection result.
     * detection == null means no card (or below confidence threshold) in this frame.
     */
    @Synchronized
    fun processDetection(detection: Detection?, sourceBitmap: Bitmap?) {
        val now = System.currentTimeMillis()
        val valid = detection?.takeIf { it.confidence >= confidenceThreshold }

        // ── NoCard timeout: reset candidate/active if no valid detection for 1.5 s ──
        if (valid == null) {
            val timeSinceLastValid = now - lastValidDetectionTime
            if (timeSinceLastValid >= NO_CARD_TIMEOUT_MS && state !is State.NoCard) {
                Log.d(TAG, "⏱ NoCard timeout (${timeSinceLastValid}ms) → reset to NoCard")
                state = State.NoCard
            }
            return
        }

        // We have a valid detection
        lastValidDetectionTime = now
        val label = valid.label

        when (val s = state) {

            is State.NoCard -> {
                // Start building a candidate
                state = State.Candidate(label, frameCount = 1, firstSeenMs = now)
                Log.d(TAG, "🔍 Candidate started: $label (frame 1)")
            }

            is State.Candidate -> {
                if (s.label == label) {
                    val nextFrameCount = s.frameCount + 1
                    val elapsedMs = now - s.firstSeenMs
                    Log.d(TAG, "🔍 Candidate: $label frame $nextFrameCount / ${elapsedMs}ms")

                    if (nextFrameCount >= REQUIRED_FRAMES && elapsedMs >= REQUIRED_MS) {
                        // Promote to CardActive and emit
                        state = State.CardActive(label)
                        emitIfNew(label, sourceBitmap, now)
                    } else {
                        state = s.copy(frameCount = nextFrameCount)
                    }
                } else {
                    // Different label broke the streak → restart candidate
                    Log.d(TAG, "🔄 Streak broken (was ${s.label}, now $label) → restart candidate")
                    state = State.Candidate(label, frameCount = 1, firstSeenMs = now)
                }
            }

            is State.CardActive -> {
                if (s.label != label) {
                    // New card appearing — start fresh candidate streak
                    Log.d(TAG, "🔄 New card candidate while active: $label")
                    state = State.Candidate(label, frameCount = 1, firstSeenMs = now)
                }
                // If same label, stay in CardActive; no re-emission (deck uniqueness)
            }
        }
    }

    private fun emitIfNew(label: String, sourceBitmap: Bitmap?, now: Long) {
        if (dealtCardsInDeck.contains(label)) {
            Log.d(TAG, "♻️ $label already dealt this round — skip")
            return
        }
        if (now - lastEmittedTime < MIN_EMIT_INTERVAL_MS) {
            Log.d(TAG, "⏳ Too fast (${now - lastEmittedTime}ms) — skip $label")
            return
        }

        val imageBase64 = sourceBitmap?.let { createCardThumbnailBase64(it) }
        dealtCardsInDeck.add(label)
        lastEmittedTime = now
        Log.d(TAG, "✅ [3-FRAME CONFIRMED] Emitting card: $label (conf threshold: $confidenceThreshold)")
        onNewCard(label, imageBase64)
    }

    private fun createCardThumbnailBase64(bitmap: Bitmap): String? {
        return try {
            val scaled = Bitmap.createScaledBitmap(bitmap, 320, 240, true)
            val outputStream = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 75, outputStream)
            val bytes = outputStream.toByteArray()
            "data:image/jpeg;base64," + Base64.encodeToString(bytes, Base64.NO_WRAP)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create card thumbnail", e)
            null
        }
    }

    @Synchronized
    fun reset() {
        dealtCardsInDeck.clear()
        lastEmittedTime = 0L
        lastValidDetectionTime = 0L
        state = State.NoCard
        Log.d(TAG, "🔄 [DECK RESET] Fresh deck ready.")
    }
}
