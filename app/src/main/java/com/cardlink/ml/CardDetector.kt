package com.cardlink.ml

import android.graphics.Bitmap

data class Detection(
    val label: String,
    val confidence: Float
)

interface CardDetector {
    /**
     * Run inference on bitmap frame and return highest confidence detection if above threshold
     */
    fun detect(bitmap: Bitmap): Detection?

    fun close()
}
