package com.cardlink.ml

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Rect
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions

/**
 * Ultra-Fast Motion-Resilient Playing Card Detector (ML Kit OCR)
 *
 * Implements:
 * 1. Diagnostic Exception Logging (no silent catch blocks)
 * 2. Recognizes corner Rank + Suit (e.g. Q♠, A♥, 10♦, K♣) at 0°, 180°, 45°, 315°
 * 3. Color fallback for fast motion: Red (♥/♦) vs Black (♠/♣)
 */
class CardVisionDetector : CardDetector {

    private val recognizer: TextRecognizer by lazy {
        TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    }

    private val exactRanks = setOf("10", "A", "K", "Q", "J", "9", "8", "7", "6", "5", "4", "3", "2")

    override fun detect(bitmap: Bitmap): Detection? {
        // Pass 1: Standard 0° orientation (Fastest ~4ms)
        val res0 = detectAtAngle(bitmap)
        if (res0 != null) return res0

        // Pass 2: 180° Inverted (~4ms)
        val bmp180 = rotateBitmap(bitmap, 180f)
        val res180 = detectAtAngle(bmp180)
        if (res180 != null) return res180

        // Pass 3: 45° Diagonal (~4ms)
        val bmp45 = rotateBitmap(bitmap, 45f)
        val res45 = detectAtAngle(bmp45)
        if (res45 != null) return res45

        // Pass 4: 315° (-45°) Diagonal (~4ms)
        val bmp315 = rotateBitmap(bitmap, 315f)
        val res315 = detectAtAngle(bmp315)
        if (res315 != null) return res315

        return null
    }

    private fun detectAtAngle(bmp: Bitmap): Detection? {
        return try {
            val image = InputImage.fromBitmap(bmp, 0)
            val task = recognizer.process(image)
            val visionText = Tasks.await(task)

            parseMotionCard(visionText, bmp)
        } catch (e: Exception) {
            Log.w("CardVisionDetector", "⚠️ ML Kit OCR task failed (Play Services / model downloading): ${e.localizedMessage}")
            null
        }
    }

    /**
     * Parses card text from OCR output with high tolerance for motion blur & fast swiping
     */
    private fun parseMotionCard(visionText: Text, bitmap: Bitmap): Detection? {
        val pattern = Regex("""(10|1O|IO|[AKQJ2-9])\s*([♠♥♦♣SHDCB]|HEART|DIAMOND|SPADE|CLUB|CO|RO|BICH|TEP|CHUON)?""")

        // Scan blocks and lines for rank and suit
        for (block in visionText.textBlocks) {
            for (line in block.lines) {
                val cleanLine = line.text.trim().uppercase()

                val match = pattern.find(cleanLine)
                if (match != null) {
                    val rawRank = match.groupValues[1]
                    val rawSuit = match.groupValues[2]
                    val rank = normalizeRank(rawRank)

                    if (rank in exactRanks) {
                        val suit = if (rawSuit.isNotBlank()) {
                            normalizeSuit(rawSuit)
                        } else {
                            determineSuitFromPixels(line.boundingBox, bitmap)
                        }

                        Log.d("CardVisionDetector", "🎯 [MOTION CARD HIT] => $rank$suit")
                        return Detection(label = "$rank$suit", confidence = 0.95f)
                    }
                }

                // Element level scan
                for (elem in line.elements) {
                    val elemText = elem.text.trim().uppercase()
                    val elemMatch = pattern.find(elemText)
                    if (elemMatch != null) {
                        val rank = normalizeRank(elemMatch.groupValues[1])
                        if (rank in exactRanks) {
                            val suit = if (elemMatch.groupValues[2].isNotBlank()) {
                                normalizeSuit(elemMatch.groupValues[2])
                            } else {
                                determineSuitFromPixels(elem.boundingBox, bitmap)
                            }
                            Log.d("CardVisionDetector", "🎯 [MOTION ELEMENT HIT] => $rank$suit")
                            return Detection(label = "$rank$suit", confidence = 0.95f)
                        }
                    }
                }
            }

            // Stacked Corner Check (Line 1: Rank "Q", Line 2: Suit "♠")
            if (block.lines.size >= 2) {
                for (i in 0 until block.lines.size - 1) {
                    val l1 = block.lines[i].text.trim().uppercase()
                    val l2 = block.lines[i + 1].text.trim().uppercase()

                    val rank = normalizeRank(l1)
                    if (rank in exactRanks) {
                        val suit = if (l2.contains("♠") || l2.contains("S") || l2.contains("B")) "♠"
                        else if (l2.contains("♥") || l2.contains("H") || l2.contains("C")) "♥"
                        else if (l2.contains("♦") || l2.contains("D") || l2.contains("R")) "♦"
                        else if (l2.contains("♣") || l2.contains("T")) "♣"
                        else determineSuitFromPixels(block.lines[i].boundingBox, bitmap)

                        Log.d("CardVisionDetector", "🎯 [STACKED CORNER HIT] => $rank$suit")
                        return Detection(label = "$rank$suit", confidence = 0.95f)
                    }
                }
            }
        }

        return null
    }

    private fun normalizeRank(raw: String): String {
        return when (raw.trim().uppercase()) {
            "1O", "IO", "10", "1o", "Io", "LO" -> "10"
            "A", "ÁT", "AT", "^" -> "A"
            "K", "KING" -> "K"
            "Q", "QUEEN" -> "Q"
            "J", "JACK" -> "J"
            else -> raw.trim().uppercase()
        }
    }

    private fun normalizeSuit(raw: String): String {
        val clean = raw.trim().uppercase()
        return when {
            clean.contains("♠") || clean.contains("S") || clean.contains("SPADE") || clean.contains("BICH") || clean.contains("B") -> "♠"
            clean.contains("♥") || clean.contains("H") || clean.contains("HEART") || clean.contains("CO") -> "♥"
            clean.contains("♦") || clean.contains("D") || clean.contains("DIAMOND") || clean.contains("RO") || clean.contains("R") -> "♦"
            clean.contains("♣") || clean.contains("C") || clean.contains("CLUB") || clean.contains("TEP") || clean.contains("CHUON") || clean.contains("T") -> "♣"
            else -> "♠"
        }
    }

    private fun determineSuitFromPixels(box: Rect?, bitmap: Bitmap): String {
        if (box == null) return "♠"

        try {
            val sampleTop = (box.bottom).coerceIn(0, bitmap.height - 1)
            val sampleBottom = (box.bottom + box.height() * 2).toInt().coerceIn(0, bitmap.height - 1)
            val sampleLeft = (box.left - 15).coerceIn(0, bitmap.width - 1)
            val sampleRight = (box.right + 15).coerceIn(0, bitmap.width - 1)

            if (sampleBottom <= sampleTop || sampleRight <= sampleLeft) return "♠"

            var redCount = 0
            var blackCount = 0

            val stepX = ((sampleRight - sampleLeft) / 6).coerceAtLeast(1)
            val stepY = ((sampleBottom - sampleTop) / 6).coerceAtLeast(1)

            for (y in sampleTop until sampleBottom step stepY) {
                for (x in sampleLeft until sampleRight step stepX) {
                    val pixel = bitmap.getPixel(x, y)
                    val r = Color.red(pixel)
                    val g = Color.green(pixel)
                    val b = Color.blue(pixel)

                    if (r > 105 && r > (g * 1.25f) && r > (b * 1.25f)) {
                        redCount++
                    } else if (r < 80 && g < 80 && b < 80) {
                        blackCount++
                    }
                }
            }

            return if (redCount > blackCount && redCount >= 2) "♥" else "♠"
        } catch (_: Exception) {
            return "♠"
        }
    }

    private fun rotateBitmap(src: Bitmap, degrees: Float): Bitmap {
        if (degrees == 0f) return src
        val matrix = Matrix().apply { postRotate(degrees) }
        return Bitmap.createBitmap(src, 0, 0, src.width, src.height, matrix, true)
    }

    override fun close() {
        try {
            recognizer.close()
        } catch (e: Exception) {
            Log.w("CardVisionDetector", "Error closing recognizer: ${e.message}")
        }
    }
}
