package com.cardlink.ml

import android.graphics.Bitmap
import android.graphics.Color
import android.util.Base64
import android.util.Log
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentLinkedDeque

/**
 * High-Sensitivity Playing Card Slicer with Skin-Ratio Minimization & Corner-Index Focus
 *
 * Key Enhancements:
 * 1. Skin-Ratio Minimization: Rejects frames where bare skin/hand covers > 40% of the ROI
 * 2. Corner Index Exposure Score: Prioritizes frames with neutral white card paper + dark/red printed ink
 * 3. Laplacian Sharpness Weighting: Ensures card edges are crisp while ignoring skin wrinkles
 */
class CardSlowMoSlicer(
    private val totalRounds: Int = 3,
    private val onCardExtracted: (slotNumber: Int, roundIdx: Int, cardIdx: Int, isRoundComplete: Boolean, imageBase64: String) -> Unit
) {

    private data class CandidateFrame(
        val bitmap: Bitmap,
        val sharpness: Double,
        val cardScore: Double,
        val skinRatio: Double,
        val timestamp: Long
    )

    private val rollingBuffer = ConcurrentLinkedDeque<CandidateFrame>()
    private var isCardPresent = false
    private var cardStartTime = 0L
    private var currentDealCount = 0
    private var lastDealtTime = 0L

    private val maxCardsPerRound = totalRounds * 3

    @Synchronized
    fun processFrame(bitmap: Bitmap) {
        val now = System.currentTimeMillis()

        val (cardScore, skinRatio) = evaluateCardPresenceAndSkin(bitmap)
        val sharpness = FrameSharpnessEvaluator.calculateSharpness(bitmap)

        // Sensitive threshold: Must have genuine card paper, edge contrast, and low skin obstruction
        val hasCard = cardScore >= 8.0 && sharpness >= 4.0 && skinRatio <= 0.45

        if (hasCard) {
            if (!isCardPresent) {
                isCardPresent = true
                cardStartTime = now
                rollingBuffer.clear()
            }

            rollingBuffer.addLast(CandidateFrame(bitmap, sharpness, cardScore, skinRatio, now))
            while (rollingBuffer.size > 12) {
                rollingBuffer.pollFirst()
            }

            if ((now - cardStartTime >= 120L) && (now - lastDealtTime >= 450L)) {
                emitBestFrame(now)
                rollingBuffer.clear()
            }
        } else {
            if (isCardPresent) {
                isCardPresent = false
                if (rollingBuffer.isNotEmpty() && (now - lastDealtTime >= 450L)) {
                    emitBestFrame(now)
                }
                rollingBuffer.clear()
            }
        }
    }

    private fun emitBestFrame(now: Long) {
        val candidates = rollingBuffer.toList()
        if (candidates.isEmpty()) return

        // Select candidate with highest combined score: Low skin ratio + high paper/ink contrast + high sharpness
        val best = candidates.maxByOrNull {
            (it.sharpness * 1.5) + (it.cardScore) - (it.skinRatio * 150.0)
        } ?: candidates.maxByOrNull { it.sharpness } ?: candidates.last()

        val imageBase64 = encodeFrameToBase64(best.bitmap)
        if (imageBase64 != null) {
            currentDealCount++
            val currentSlot = ((currentDealCount - 1) % maxCardsPerRound) + 1
            val roundIdx = ((currentSlot - 1) % totalRounds) + 1
            val cardIdx = ((currentSlot - 1) / totalRounds) + 1
            val isRoundComplete = currentSlot == maxCardsPerRound

            lastDealtTime = now
            Log.d("CardSlowMoSlicer", "🎬 [INDEX EXPOSED] Slot #$currentSlot (Tụ $roundIdx - Lá $cardIdx) | Sharpness=${best.sharpness} | Score=${best.cardScore} | SkinRatio=${best.skinRatio}")

            onCardExtracted(currentSlot, roundIdx, cardIdx, isRoundComplete, imageBase64)
        }
    }

    @Synchronized
    fun manualCapture(bitmap: Bitmap) {
        val now = System.currentTimeMillis()
        val imageBase64 = encodeFrameToBase64(bitmap)
        if (imageBase64 != null) {
            currentDealCount++
            val currentSlot = ((currentDealCount - 1) % maxCardsPerRound) + 1
            val roundIdx = ((currentSlot - 1) % totalRounds) + 1
            val cardIdx = ((currentSlot - 1) / totalRounds) + 1
            val isRoundComplete = currentSlot == maxCardsPerRound

            lastDealtTime = now
            Log.d("CardSlowMoSlicer", "📸 [MANUAL SNAP] Slot #$currentSlot (Tụ $roundIdx - Lá $cardIdx)")
            onCardExtracted(currentSlot, roundIdx, cardIdx, isRoundComplete, imageBase64)
        }
    }

    /**
     * Evaluates playing card presence AND skin ratio
     * - Returns Pair(cardScore, skinRatio)
     */
    private fun evaluateCardPresenceAndSkin(bitmap: Bitmap): Pair<Double, Double> {
        val width = bitmap.width
        val height = bitmap.height
        if (width < 30 || height < 30) return Pair(0.0, 1.0)

        val stepX = (width / 40).coerceAtLeast(1)
        val stepY = (height / 30).coerceAtLeast(1)

        var neutralWhitePaperPixels = 0
        var cardInkPixels = 0
        var skinPixels = 0
        var totalSamples = 0
        var edgeTransitions = 0
        var prevIsPaper = false

        for (y in 0 until height step stepY) {
            prevIsPaper = false
            for (x in 0 until width step stepX) {
                val p = bitmap.getPixel(x, y)
                val r = Color.red(p)
                val g = Color.green(p)
                val b = Color.blue(p)
                val lum = 0.299 * r + 0.587 * g + 0.114 * b

                // Neutral White Playing Card Paper
                val isNeutralWhite = (lum > 95) &&
                        (Math.abs(r - g) <= 18) &&
                        (Math.abs(g - b) <= 18) &&
                        (Math.abs(r - b) <= 22)

                // Human Skin Tone Filter: R > G > B and R - B > 18
                val isSkinTone = (r > 95) && (g > 40) && (b > 20) && (r > g) && ((r - b) > 18)

                // Card Ink: Black (♠, ♣) or Red (♥, ♦)
                val isBlackInk = (lum < 75) && (Math.abs(r - g) <= 22) && (Math.abs(g - b) <= 22)
                val isRedSuitInk = (r > 120) && (g < 75) && (b < 75)
                val isCardInk = isBlackInk || isRedSuitInk

                if (isNeutralWhite) {
                    neutralWhitePaperPixels++
                } else if (isCardInk) {
                    cardInkPixels++
                }

                if (isSkinTone) {
                    skinPixels++
                }

                if (isNeutralWhite != prevIsPaper) {
                    edgeTransitions++
                    prevIsPaper = isNeutralWhite
                }

                totalSamples++
            }
        }

        if (totalSamples == 0) return Pair(0.0, 1.0)

        val paperRatio = neutralWhitePaperPixels.toDouble() / totalSamples
        val inkRatio = cardInkPixels.toDouble() / totalSamples
        val skinRatio = skinPixels.toDouble() / totalSamples

        if (paperRatio < 0.04 || paperRatio > 0.94) return Pair(0.0, skinRatio)
        if (inkRatio < 0.003 && edgeTransitions < 3) return Pair(0.0, skinRatio)

        val cardScore = (paperRatio * 100.0) + (inkRatio * 250.0) + (edgeTransitions * 1.5)
        return Pair(cardScore, skinRatio)
    }

    private fun encodeFrameToBase64(bitmap: Bitmap): String? {
        return try {
            val scaled = Bitmap.createScaledBitmap(bitmap, 420, 315, true)
            val outputStream = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 85, outputStream)
            val bytes = outputStream.toByteArray()
            "data:image/jpeg;base64," + Base64.encodeToString(bytes, Base64.NO_WRAP)
        } catch (e: Exception) {
            Log.e("CardSlowMoSlicer", "Failed to encode card frame", e)
            null
        }
    }

    @Synchronized
    fun reset() {
        rollingBuffer.clear()
        isCardPresent = false
        cardStartTime = 0L
        currentDealCount = 0
        lastDealtTime = 0L
    }
}
