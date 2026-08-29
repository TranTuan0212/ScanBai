package com.cardlink.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExitToApp
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.cardlink.network.ActiveSessionDto
import com.cardlink.network.ApiService
import com.cardlink.network.StartSessionRequest
import com.cardlink.utils.SharedPrefs
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SelectSessionScreen(
    sharedPrefs: SharedPrefs,
    apiService: ApiService,
    onStartLiveSuccess: (sessionId: String, rounds: Int, antMediaUrl: String) -> Unit,
    onJoinViewerSuccess: (sessionId: String, rounds: Int, antMediaUrl: String) -> Unit,
    onLogout: () -> Unit
) {
    var rounds by remember { mutableStateOf(3) }
    var activeSessions by remember { mutableStateOf<List<ActiveSessionDto>>(emptyList()) }
    var isLoadingList by remember { mutableStateOf(false) }
    var isStartingLive by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    val canBroadcast = sharedPrefs.userRole == "live" || sharedPrefs.userRole == "admin"

    val refreshActiveSessions = {
        scope.launch {
            isLoadingList = true
            errorMessage = null
            try {
                val response = apiService.getActiveSessions()
                if (response.isSuccessful) {
                    activeSessions = response.body() ?: emptyList()
                } else {
                    errorMessage = "Không thể tải danh sách phiên (${response.code()})"
                }
            } catch (e: Exception) {
                errorMessage = "Lỗi kết nối Wi-Fi: ${e.message}"
            } finally {
                isLoadingList = false
            }
        }
    }

    LaunchedEffect(Unit) {
        refreshActiveSessions()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("CardLink Broadcast", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = Color.White)
                        Text(
                            "${sharedPrefs.userEmail} (${sharedPrefs.userRole?.uppercase()})",
                            fontSize = 12.sp,
                            color = Color(0xFF94A3B8)
                        )
                    }
                },
                actions = {
                    IconButton(onClick = onLogout) {
                        Icon(Icons.Default.ExitToApp, contentDescription = "Logout", tint = Color(0xFFF87171))
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color(0xFF1E293B))
            )
        },
        containerColor = Color(0xFF0F172A)
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp)
        ) {
            if (errorMessage != null) {
                Surface(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 16.dp),
                    shape = RoundedCornerShape(12.dp),
                    color = Color(0x33EF4444)
                ) {
                    Row(
                        modifier = Modifier.padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(Icons.Default.Warning, contentDescription = null, tint = Color(0xFFF87171))
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(errorMessage ?: "", color = Color(0xFFF87171), fontSize = 13.sp)
                    }
                }
            }

            // Section 1: Broadcaster Controls
            if (canBroadcast) {
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(20.dp),
                    colors = CardDefaults.cardColors(containerColor = Color(0xFF1E293B))
                ) {
                    Column(modifier = Modifier.padding(20.dp)) {
                        Text(
                            "🎙️ Bắt Đầu Phiên Phát Trực Tiếp",
                            fontSize = 16.sp,
                            fontWeight = FontWeight.Bold,
                            color = Color.White
                        )
                        Text(
                            "Chọn số cột bài (N) và phát sóng cho các thiết bị khác xem",
                            fontSize = 12.sp,
                            color = Color(0xFF94A3B8),
                            modifier = Modifier.padding(top = 2.dp, bottom = 16.dp)
                        )

                        Text("Số Cột Ghép Bài (Rounds): $rounds cột", fontSize = 14.sp, color = Color.White)
                        Slider(
                            value = rounds.toFloat(),
                            onValueChange = { rounds = it.toInt() },
                            valueRange = 2f..9f,
                            steps = 6,
                            colors = SliderDefaults.colors(
                                thumbColor = Color(0xFFEF4444),
                                activeTrackColor = Color(0xFFEF4444),
                                inactiveTrackColor = Color(0xFF334155)
                            )
                        )

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            (2..9).forEach { r ->
                                Surface(
                                    modifier = Modifier
                                        .size(32.dp)
                                        .clickable { rounds = r },
                                    shape = RoundedCornerShape(8.dp),
                                    color = if (rounds == r) Color(0xFFEF4444) else Color(0xFF334155)
                                ) {
                                    Box(contentAlignment = Alignment.Center) {
                                        Text("$r", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                                    }
                                }
                            }
                        }

                        Spacer(modifier = Modifier.height(20.dp))

                        Button(
                            onClick = {
                                scope.launch {
                                    isStartingLive = true
                                    errorMessage = null
                                    try {
                                        val res = apiService.startSession(StartSessionRequest(rounds = rounds))
                                        if (res.isSuccessful && res.body() != null) {
                                            val body = res.body()!!
                                            onStartLiveSuccess(body.sessionId, body.rounds, body.antMediaWebSocketUrl)
                                        } else if (res.code() == 409) {
                                            errorMessage = "Một máy khác đang phát Live! Chỉ 1 máy được Live tại một thời điểm."
                                        } else if (res.code() == 403) {
                                            errorMessage = "Tài khoản của bạn đã hết hạn sử dụng!"
                                        } else {
                                            errorMessage = "Không thể tạo phiên Live (${res.code()})"
                                        }
                                    } catch (e: Exception) {
                                        errorMessage = "Lỗi kết nối Server: ${e.message}"
                                    } finally {
                                        isStartingLive = false
                                    }
                                }
                            },
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(50.dp),
                            shape = RoundedCornerShape(12.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFEF4444)),
                            enabled = !isStartingLive
                        ) {
                            if (isStartingLive) {
                                CircularProgressIndicator(color = Color.White, modifier = Modifier.size(20.dp))
                            } else {
                                Text("Bắt Đầu Phát Live (Broadcaster)", fontWeight = FontWeight.Bold, color = Color.White)
                            }
                        }
                    }
                }

                Spacer(modifier = Modifier.height(20.dp))
            }

            // Section 2: Active Sessions for Viewers
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    "📺 Phiên Đang Live Trong Mạng Wi-Fi",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
                IconButton(onClick = { refreshActiveSessions() }) {
                    Icon(Icons.Default.Refresh, contentDescription = "Refresh", tint = Color(0xFF818CF8))
                }
            }

            if (isLoadingList) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = Color(0xFFEF4444))
                }
            } else if (activeSessions.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        "Hiện chưa có phiên phát trực tiếp nào trong mạng.",
                        color = Color(0xFF64748B),
                        fontSize = 14.sp
                    )
                }
            } else {
                LazyColumn(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    items(activeSessions) { session ->
                        Card(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    onJoinViewerSuccess(session.sessionId, session.rounds, session.antMediaWebSocketUrl)
                                },
                            shape = RoundedCornerShape(16.dp),
                            colors = CardDefaults.cardColors(containerColor = Color(0xFF1E293B))
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(16.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column {
                                    Text(
                                        "Stream: ${session.broadcasterEmail ?: "Live Session"}",
                                        color = Color.White,
                                        fontWeight = FontWeight.Bold,
                                        fontSize = 15.sp
                                    )
                                    Text(
                                        "${session.rounds} cột ghép | Đã nhận: ${session.cardCount} lá",
                                        color = Color(0xFF94A3B8),
                                        fontSize = 13.sp,
                                        modifier = Modifier.padding(top = 2.dp)
                                    )
                                }

                                Button(
                                    onClick = {
                                        onJoinViewerSuccess(session.sessionId, session.rounds, session.antMediaWebSocketUrl)
                                    },
                                    shape = RoundedCornerShape(10.dp),
                                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF3B82F6))
                                ) {
                                    Icon(Icons.Default.PlayArrow, contentDescription = null, modifier = Modifier.size(16.dp))
                                    Spacer(modifier = Modifier.width(4.dp))
                                    Text("Xem", fontSize = 13.sp)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
