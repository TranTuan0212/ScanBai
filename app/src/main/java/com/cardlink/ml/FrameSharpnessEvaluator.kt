package com.cardlink.ml

import android.graphics.Bitmap
import android.graphics.Color
import kotlin.math.abs

/**
 * High-Speed Laplacian Sharpness Evaluator for Motion-Blur Filtering
 * Filters out blurred frames from fast hand-waving and selects only sharp frames (< 1ms execution)
 */
object FrameSharpnessEvaluator {

    /**
     * Calculates the Laplacian Variance (Độ sắc nét của khung hình)
     * Higher score = Sharper image with high edge contrast
     * Lower score = Blurry / Motion-blurred frame
     */
    fun calculateSharpness(bitmap: Bitmap): Double {
        val width = bitmap.width
        val height = bitmap.height

        if (width < 20 || height < 20) return 0.0

        // Subsample grid for ultra-fast calculation
        val stepX = (width / 60).coerceAtLeast(1)
        val stepY = (height / 45).coerceAtLeast(1)

        var sumLaplacian = 0.0
        var sumLaplacianSq = 0.0
        var count = 0

        for (y in stepY until height - stepY step stepY) {
            for (x in stepX until width - stepX step stepX) {
                val center = getLuminance(bitmap.getPixel(x, y))
                val left = getLuminance(bitmap.getPixel(x - stepX, y))
                val right = getLuminance(bitmap.getPixel(x + stepX, y))
                val top = getLuminance(bitmap.getPixel(x, y - stepY))
                val bottom = getLuminance(bitmap.getPixel(x, y + stepY))

                // Discrete 2D Laplacian operator: 4*C - (L + R + T + B)
                val lap = (4 * center - (left + right + top + bottom)).toDouble()

                sumLaplacian += lap
                sumLaplacianSq += lap * lap
                count++
            }
        }

        if (count == 0) return 0.0

        val mean = sumLaplacian / count
        val variance = (sumLaplacianSq / count) - (mean * mean)

        return variance.coerceAtLeast(0.0)
    }

    private inline fun getLuminance(pixel: Int): Int {
        val r = Color.red(pixel)
        val g = Color.green(pixel)
        val b = Color.blue(pixel)
        return (0.299 * r + 0.587 * g + 0.114 * b).toInt()
    }
}
