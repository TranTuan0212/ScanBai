package com.cardlink.ml

import android.graphics.Bitmap

class MockDetector : CardDetector {

    private val cardDeck = listOf(
        "A♠", "K♠", "Q♠", "J♠", "10♠", "9♠", "8♠", "7♠",
        "A♥", "K♥", "Q♥", "J♥", "10♥", "9♥", "8♥", "7♥",
        "A♦", "K♦", "Q♦", "J♦", "10♦", "9♦", "8♦", "7♦",
        "A♣", "K♣", "Q♣", "J♣", "10♣", "9♣", "8♣", "7♣"
    )

    private var frameCounter = 0
    private var currentCardIndex = 0

    override fun detect(bitmap: Bitmap): Detection? {
        frameCounter++
        // Simulate a card detection pattern every 30 frames
        val showCard = (frameCounter % 60) < 40
        return if (showCard) {
            val card = cardDeck[currentCardIndex % cardDeck.size]
            if (frameCounter % 60 == 0) {
                currentCardIndex++
            }
            Detection(label = card, confidence = 0.92f)
        } else {
            null
        }
    }

    override fun close() {
        frameCounter = 0
    }
}
