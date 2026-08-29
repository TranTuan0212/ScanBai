package com.cardlink.utils

import org.json.JSONObject

data class BaiCaoCard(
    val raw: String,
    val rank: String,
    val suit: String,
    val value: Int,
    val isFace: Boolean,
    val rankWeight: Int,
    val image: String? = null
)

enum class BaiCaoRankType {
    SAP,       // Three of a Kind (AAA, KKK, 777...)
    BA_TAY,    // 3 Face Cards (J, Q, K)
    DIEM,      // Normal points (1..9)
    BU,        // 0 points (Bù)
    PARTIAL,   // 1 or 2 cards
    EMPTY      // 0 cards
}

data class BaiCaoScore(
    val points: Int,
    val rankType: BaiCaoRankType,
    val displayText: String,
    val weight: Int,
    val isSpecial: Boolean
)

data class BaiCaoColumn(
    val columnIndex: Int,
    val cards: List<String>,
    val score: BaiCaoScore,
    val isWinner: Boolean = false
)

object BaiCaoCalculator {

    fun parseCard(cardInput: String): BaiCaoCard {
        var rawLabel = cardInput.trim()
        var imageSnapshot: String? = null

        if (rawLabel.startsWith("{") && rawLabel.endsWith("}")) {
            try {
                val json = JSONObject(rawLabel)
                rawLabel = json.optString("label", "")
                imageSnapshot = json.optString("image", null)
            } catch (_: Exception) {}
        }

        val clean = rawLabel.uppercase()
        var rank = clean
        var suit = ""

        if (clean.isNotEmpty()) {
            val lastChar = clean.last().toString()
            if (listOf("♠", "♥", "♦", "♣", "S", "H", "D", "C").contains(lastChar)) {
                suit = lastChar
                rank = clean.dropLast(1)
            }
        }

        var value = 0
        var isFace = false
        var rankWeight = 0

        when (rank) {
            "A" -> {
                value = 1
                rankWeight = 14
            }
            "K" -> {
                value = 10
                isFace = true
                rankWeight = 13
            }
            "Q" -> {
                value = 10
                isFace = true
                rankWeight = 12
            }
            "J" -> {
                value = 10
                isFace = true
                rankWeight = 11
            }
            "10" -> {
                value = 10
                rankWeight = 10
            }
            "9" -> {
                value = 9
                rankWeight = 9
            }
            "8" -> {
                value = 8
                rankWeight = 8
            }
            "7" -> {
                value = 7
                rankWeight = 7
            }
            "6" -> {
                value = 6
                rankWeight = 6
            }
            "5" -> {
                value = 5
                rankWeight = 5
            }
            "4" -> {
                value = 4
                rankWeight = 4
            }
            "3" -> {
                value = 3
                rankWeight = 3
            }
            "2" -> {
                value = 2
                rankWeight = 2
            }
            else -> {
                val parsed = rank.toIntOrNull() ?: 0
                value = parsed
                rankWeight = parsed
            }
        }

        return BaiCaoCard(
            raw = rawLabel,
            rank = rank,
            suit = suit,
            value = value,
            isFace = isFace,
            rankWeight = rankWeight,
            image = imageSnapshot
        )
    }

    fun calculateScore(cards: List<String>): BaiCaoScore {
        if (cards.isEmpty()) {
            return BaiCaoScore(
                points = 0,
                rankType = BaiCaoRankType.EMPTY,
                displayText = "Chưa có bài",
                weight = -1,
                isSpecial = false
            )
        }

        val parsed = cards.map { parseCard(it) }

        if (cards.size < 3) {
            val sum = parsed.sumOf { it.value }
            val pts = sum % 10
            return BaiCaoScore(
                points = pts,
                rankType = BaiCaoRankType.PARTIAL,
                displayText = if (pts == 0) "Bù (Tạm tính)" else "$pts Điểm (Tạm tính)",
                weight = pts,
                isSpecial = false
            )
        }

        val three = parsed.take(3)

        // 1. Check SÁP (Three of a Kind)
        val isSap = (three[0].rank == three[1].rank) && (three[1].rank == three[2].rank)
        if (isSap) {
            val sapRank = three[0].rank
            val sapWeight = 3000 + three[0].rankWeight
            return BaiCaoScore(
                points = 10,
                rankType = BaiCaoRankType.SAP,
                displayText = "Sáp $sapRank",
                weight = sapWeight,
                isSpecial = true
            )
        }

        // 2. Check BA TÂY / BA TIÊN (3 Face cards J, Q, K)
        val isBaTay = three.all { it.isFace }
        if (isBaTay) {
            return BaiCaoScore(
                points = 10,
                rankType = BaiCaoRankType.BA_TAY,
                displayText = "Ba Tây",
                weight = 2000,
                isSpecial = true
            )
        }

        // 3. Normal points (Modulo 10)
        val sum = three.sumOf { it.value }
        val pts = sum % 10

        if (pts === 0) {
            return BaiCaoScore(
                points = 0,
                rankType = BaiCaoRankType.BU,
                displayText = "Bù (0 Điểm)",
                weight = 0,
                isSpecial = false
            )
        }

        return BaiCaoScore(
            points = pts,
            rankType = BaiCaoRankType.DIEM,
            displayText = "$pts Điểm",
            weight = 100 + pts,
            isSpecial = (pts == 9)
        )
    }

    fun evaluateColumns(cardStack: List<List<String>>): List<BaiCaoColumn> {
        val initialCols = cardStack.mapIndexed { idx, cards ->
            val score = calculateScore(cards)
            BaiCaoColumn(
                columnIndex = idx,
                cards = cards,
                score = score,
                isWinner = false
            )
        }

        var maxWeight = -1
        initialCols.forEach { col ->
            if (col.score.weight > maxWeight && col.score.rankType != BaiCaoRankType.EMPTY) {
                maxWeight = col.score.weight
            }
        }

        return if (maxWeight > 0) {
            initialCols.map { col ->
                if (col.score.weight == maxWeight) col.copy(isWinner = true) else col
            }
        } else {
            initialCols
        }
    }
}
