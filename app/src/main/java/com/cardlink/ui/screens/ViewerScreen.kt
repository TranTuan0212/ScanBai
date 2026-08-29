package com.cardlink.ui.screens

import android.app.Activity
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.cardlink.network.SocketManager
import com.cardlink.utils.BaiCaoCalculator
import com.cardlink.utils.BaiCaoColumn
import com.cardlink.utils.BaiCaoRankType
import com.cardlink.webrtc.AntMediaManager
import org.webrtc.EglBase
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer

@Composable
fun ViewerScreen(
    sessionId: String,
    rounds: Int,
    antMediaUrl: String,
    socketManager: SocketManager,
    antMediaManager: AntMediaManager,
    onBack: () -> Unit
) {
    val context = LocalContext.current
    val cardStack by socketManager.cardStackState.collectAsState()
    val viewerCount by socketManager.viewerCountState.collectAsState()

    var isLiveEnded by remember { mutableStateOf(false) }

    // Evaluate Bài Cào score for all columns in real-time
    val evaluatedColumns = remember(cardStack, rounds) {
        val safeStack = if (cardStack.size >= rounds) cardStack else {
            val list = cardStack.toMutableList()
            while (list.size < rounds) list.add(emptyList())
            list
        }
        BaiCaoCalculator.evaluateColumns(safeStack)
    }

    DisposableEffect(sessionId) {
        socketManager.connect()
        socketManager.joinRoom(sessionId)

        onDispose {
            socketManager.leaveRoom(sessionId)
            antMediaManager.stopStream()
        }
    }

    LaunchedEffect(Unit) {
        socketManager.liveEndedEvent.collect { endedId ->
            if (endedId == sessionId) {
                isLiveEnded = true
            }
        }
    }

    if (isLiveEnded) {
        AlertDialog(
            onDismissRequest = onBack,
            title = { Text("Phiên Live Đã Kết Thúc", fontWeight = FontWeight.Bold) },
            text = { Text("Người phát sóng đã kết thúc phiên Live.") },
            confirmButton = {
                Button(
                    onClick = onBack,
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFEF4444))
                ) {
                    Text("Trở về danh sách")
                }
            }
        )
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF090D16))
    ) {
        // ================= TOP SECTION: LIVE STREAM VIDEO (42% Height) =================
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(0.42f)
                .background(Color.Black)
        ) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx ->
                    SurfaceViewRenderer(ctx).apply {
                        val rootEglBase = EglBase.create()
                        init(rootEglBase.eglBaseContext, null)
                        setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT)
                        setEnableHardwareScaler(true)

                        post {
                            val activity = ctx as? Activity
                            antMediaManager.startPlay(
                                activity = activity,
                                serverUrl = antMediaUrl,
                                streamId = sessionId,
                                remoteRenderer = this
                            )
                        }
                    }
                }
            )

            // Top Overlays: Back button, LIVE badge, Viewer count
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                IconButton(
                    onClick = onBack,
                    modifier = Modifier
                        .size(38.dp)
                        .background(Color(0x80000000), CircleShape)
                ) {
                    Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = Color.White)
                }

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    // LIVE Pill
                    Surface(
                        shape = RoundedCornerShape(16.dp),
                        color = Color(0xFFDC2626),
                        shadowElevation = 4.dp
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(7.dp)
                                    .background(Color.White, CircleShape)
                            )
                            Spacer(modifier = Modifier.width(5.dp))
                            Text("LIVE", color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.ExtraBold)
                        }
                    }

                    // Viewer Count Pill
                    Surface(
                        shape = RoundedCornerShape(16.dp),
                        color = Color(0x99000000)
                    ) {
                        Text(
                            text = "👁️ $viewerCount",
                            color = Color.White,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp)
                        )
                    }
                }
            }
        }

        // ================= BOTTOM SECTION: BÀI CÀO RESULT ARENA (58% Height) =================
        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .weight(0.58f),
            color = Color(0xFF0F172A),
            shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
            shadowElevation = 16.dp
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 12.dp, vertical = 12.dp)
            ) {
                // Arena Header
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 4.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = "🎴 BẢNG ĐIỂM BÀI CÀO",
                            color = Color(0xFFF1F5F9),
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Black
                        )
                        Spacer(modifier = Modifier.width(6.dp))
                        Surface(
                            shape = RoundedCornerShape(6.dp),
                            color = Color(0xFF334155)
                        ) {
                            Text(
                                text = "$rounds Tụ",
                                color = Color(0xFF94A3B8),
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Bold,
                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                            )
                        }
                    }

                    // Winning Summary tag
                    val winnerCol = evaluatedColumns.firstOrNull { it.isWinner }
                    if (winnerCol != null && winnerCol.cards.isNotEmpty()) {
                        Surface(
                            shape = RoundedCornerShape(12.dp),
                            color = Color(0xFFB45309).copy(alpha = 0.3f),
                            border = androidx.compose.foundation.BorderStroke(1.dp, Color(0xFFF59E0B))
                        ) {
                            Text(
                                text = "🏆 Tụ ${winnerCol.columnIndex + 1} đang dẫn đầu",
                                color = Color(0xFFFDE68A),
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Bold,
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp)
                            )
                        }
                    }
                }

                Spacer(modifier = Modifier.height(8.dp))

                // Columns Horizontal Scroll
                LazyRow(
                    modifier = Modifier.fillMaxSize(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    items(evaluatedColumns) { column ->
                        BaiCaoColumnCard(column = column)
                    }
                }
            }
        }
    }
}

/**
 * Modern, High-Legibility Column Card for Bài Cào
 */
@Composable
fun BaiCaoColumnCard(column: BaiCaoColumn) {
    val isWinner = column.isWinner && column.cards.isNotEmpty()

    val cardBorder = if (isWinner) {
        androidx.compose.foundation.BorderStroke(2.dp, Brush.verticalGradient(listOf(Color(0xFFF59E0B), Color(0xFFD97706))))
    } else {
        androidx.compose.foundation.BorderStroke(1.dp, Color(0xFF334155))
    }

    val headerBg = if (isWinner) {
        Brush.horizontalGradient(listOf(Color(0xFF78350F), Color(0xFFB45309)))
    } else {
        Brush.horizontalGradient(listOf(Color(0xFF1E293B), Color(0xFF1E293B)))
    }

    Card(
        modifier = Modifier
            .width(108.dp)
            .fillMaxHeight()
            .shadow(if (isWinner) 10.dp else 2.dp, RoundedCornerShape(16.dp)),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = Color(0xFF161F30)),
        border = cardBorder
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(6.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            // Header Pill: Tụ X (+ 👑 Winner badge)
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(headerBg)
                    .padding(vertical = 4.dp),
                contentAlignment = Alignment.Center
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (isWinner) {
                        Text("👑", fontSize = 11.sp)
                        Spacer(modifier = Modifier.width(2.dp))
                    }
                    Text(
                        text = "TỤ ${column.columnIndex + 1}",
                        color = if (isWinner) Color(0xFFFEF08A) else Color(0xFFE2E8F0),
                        fontSize = 12.sp,
                        fontWeight = FontWeight.ExtraBold
                    )
                }
            }

            Spacer(modifier = Modifier.height(6.dp))

            // Score Badge (Sáp / Ba Tây / 9 Điểm / Bù)
            BaiCaoScoreBadge(score = column.score, isWinner = isWinner)

            Spacer(modifier = Modifier.height(8.dp))

            // Cards in this Column (Up to 3 cards)
            LazyColumn(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                verticalArrangement = Arrangement.spacedBy(6.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                if (column.cards.isEmpty()) {
                    item {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(90.dp)
                                .border(1.dp, Color(0xFF334155), RoundedCornerShape(8.dp)),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                text = "Chờ bài...",
                                color = Color(0xFF64748B),
                                fontSize = 11.sp,
                                textAlign = TextAlign.Center
                            )
                        }
                    }
                } else {
                    items(column.cards) { cardStr ->
                        RealisticPlayingCardTile(cardStr = cardStr)
                    }
                }
            }
        }
    }
}

/**
 * Score Badge with colorful high-contrast styling for Bài Cào
 */
@Composable
fun BaiCaoScoreBadge(score: com.cardlink.utils.BaiCaoScore, isWinner: Boolean) {
    val (bgColor, textColor) = when (score.rankType) {
        BaiCaoRankType.SAP -> Pair(Color(0xFFF59E0B), Color(0xFF451A03))
        BaiCaoRankType.BA_TAY -> Pair(Color(0xFF10B981), Color(0xFF022C22))
        BaiCaoRankType.DIEM -> {
            if (score.points >= 8) Pair(Color(0xFF3B82F6), Color.White)
            else Pair(Color(0xFF6366F1), Color.White)
        }
        BaiCaoRankType.BU -> Pair(Color(0xFF475569), Color(0xFFCBD5E1))
        BaiCaoRankType.PARTIAL -> Pair(Color(0xFFD97706), Color.White)
        BaiCaoRankType.EMPTY -> Pair(Color(0xFF1E293B), Color(0xFF64748B))
    }

    Surface(
        shape = RoundedCornerShape(8.dp),
        color = bgColor,
        modifier = Modifier.fillMaxWidth()
    ) {
        Text(
            text = score.displayText,
            color = textColor,
            fontSize = 11.sp,
            fontWeight = FontWeight.Black,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 4.dp, vertical = 3.dp),
            maxLines = 1
        )
    }
}

/**
 * High-legibility, Realistic Playing Card Tile with Real Camera Frame Snapshot
 */
@Composable
fun RealisticPlayingCardTile(cardStr: String) {
    val parsed = remember(cardStr) { BaiCaoCalculator.parseCard(cardStr) }
    val isRed = parsed.suit == "♥" || parsed.suit == "♦" || parsed.suit == "H" || parsed.suit == "D"
    val suitSymbol = when (parsed.suit) {
        "H", "♥" -> "♥"
        "D", "♦" -> "♦"
        "S", "♠" -> "♠"
        "C", "♣" -> "♣"
        else -> parsed.suit
    }
    val contentColor = if (isRed) Color(0xFFDC2626) else Color(0xFF0F172A)

    val imageBitmap = remember(parsed.image) {
        if (!parsed.image.isNullOrBlank() && parsed.image.contains("base64,")) {
            try {
                val cleanBase64 = parsed.image.substringAfter("base64,")
                val bytes = android.util.Base64.decode(cleanBase64, android.util.Base64.DEFAULT)
                android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
            } catch (_: Exception) {
                null
            }
        } else null
    }

    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .height(52.dp),
        shape = RoundedCornerShape(8.dp),
        color = Color(0xFFFFFFFF),
        shadowElevation = 3.dp
    ) {
        Row(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 6.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                if (imageBitmap != null) {
                    androidx.compose.foundation.Image(
                        bitmap = imageBitmap,
                        contentDescription = "Card Snapshot",
                        modifier = Modifier
                            .size(38.dp)
                            .clip(RoundedCornerShape(6.dp))
                            .border(1.dp, Color(0xFFCBD5E1), RoundedCornerShape(6.dp)),
                        contentScale = androidx.compose.ui.layout.ContentScale.Crop
                    )
                }

                Text(
                    text = parsed.rank,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.Black,
                    color = contentColor
                )
            }

            Text(
                text = suitSymbol,
                fontSize = 17.sp,
                fontWeight = FontWeight.Bold,
                color = contentColor
            )
        }
    }
}
