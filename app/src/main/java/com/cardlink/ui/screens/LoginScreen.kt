package com.cardlink.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.cardlink.network.LoginRequest
import com.cardlink.network.RetrofitClient
import com.cardlink.network.ServerDiscovery
import com.cardlink.utils.SharedPrefs
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LoginScreen(
    sharedPrefs: SharedPrefs,
    onLoginSuccess: () -> Unit
) {
    val context = LocalContext.current
    var email by remember { mutableStateOf("user@cardlink.com") }
    var password by remember { mutableStateOf("password123") }
    var serverHost by remember { mutableStateOf(sharedPrefs.serverHost) }
    var showServerConfig by remember { mutableStateOf(false) }

    var isDiscovering by remember { mutableStateOf(false) }
    var discoveredStatus by remember { mutableStateOf<String?>("Đang quét tìm Server Wi-Fi...") }
    var discoverySuccess by remember { mutableStateOf(false) }

    var isLoading by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    // Auto-discover server on Wi-Fi upon opening
    val runAutoDiscovery = {
        scope.launch {
            isDiscovering = true
            discoveredStatus = "Đang tìm máy chủ trong mạng Wi-Fi..."
            discoverySuccess = false

            val foundIp = ServerDiscovery.discoverServerIp(context, serverHost)
            if (foundIp != null) {
                serverHost = foundIp
                sharedPrefs.serverHost = foundIp
                discoveredStatus = "Đã tự động kết nối: $foundIp"
                discoverySuccess = true
            } else {
                discoveredStatus = "Dùng IP hiện tại: $serverHost"
                discoverySuccess = false
            }
            isDiscovering = false
        }
    }

    LaunchedEffect(Unit) {
        runAutoDiscovery()
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF0F172A)),
        contentAlignment = Alignment.Center
    ) {
        Card(
            modifier = Modifier
                .fillMaxWidth(0.92f)
                .padding(16.dp),
            shape = RoundedCornerShape(24.dp),
            colors = CardDefaults.cardColors(containerColor = Color(0xFF1E293B)),
            elevation = CardDefaults.cardElevation(8.dp)
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Text(
                    text = "📡 CardLink Broadcast",
                    fontSize = 24.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
                Text(
                    text = "Hệ thống phát & xem trong mạng Wi-Fi",
                    fontSize = 13.sp,
                    color = Color(0xFF94A3B8),
                    modifier = Modifier.padding(top = 4.dp, bottom = 16.dp)
                )

                // Auto-Discovery Wi-Fi Status Banner
                Surface(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 16.dp),
                    shape = RoundedCornerShape(12.dp),
                    color = if (discoverySuccess) Color(0x2210B981) else Color(0x226366F1),
                    border = androidx.compose.foundation.BorderStroke(
                        1.dp,
                        if (discoverySuccess) Color(0xFF10B981) else Color(0xFF6366F1)
                    )
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.weight(1f)
                        ) {
                            if (isDiscovering) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(16.dp),
                                    strokeWidth = 2.dp,
                                    color = Color(0xFF818CF8)
                                )
                            } else if (discoverySuccess) {
                                Icon(
                                    Icons.Default.CheckCircle,
                                    contentDescription = null,
                                    tint = Color(0xFF10B981),
                                    modifier = Modifier.size(16.dp)
                                )
                            } else {
                                Text("📶", fontSize = 14.sp)
                            }
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(
                                text = discoveredStatus ?: "",
                                color = if (discoverySuccess) Color(0xFFA7F3D0) else Color(0xFFC7D2FE),
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold
                            )
                        }

                        IconButton(
                            onClick = { runAutoDiscovery() },
                            modifier = Modifier.size(24.dp)
                        ) {
                            Icon(
                                Icons.Default.Refresh,
                                contentDescription = "Quét lại",
                                tint = Color(0xFF94A3B8),
                                modifier = Modifier.size(16.dp)
                            )
                        }
                    }
                }

                if (errorMessage != null) {
                    Surface(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(bottom = 16.dp),
                        shape = RoundedCornerShape(12.dp),
                        color = Color(0x33EF4444)
                    ) {
                        Text(
                            text = errorMessage ?: "",
                            color = Color(0xFFF87171),
                            fontSize = 13.sp,
                            modifier = Modifier.padding(12.dp)
                        )
                    }
                }

                OutlinedTextField(
                    value = email,
                    onValueChange = { email = it },
                    label = { Text("Email") },
                    leadingIcon = { Icon(Icons.Default.Person, contentDescription = null, tint = Color(0xFF94A3B8)) },
                    modifier = Modifier.fillMaxWidth(),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = Color.White,
                        unfocusedTextColor = Color.White,
                        focusedBorderColor = Color(0xFFEF4444),
                        unfocusedBorderColor = Color(0xFF334155)
                    ),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                    singleLine = true
                )

                Spacer(modifier = Modifier.height(12.dp))

                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it },
                    label = { Text("Mật khẩu") },
                    leadingIcon = { Icon(Icons.Default.Lock, contentDescription = null, tint = Color(0xFF94A3B8)) },
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.fillMaxWidth(),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = Color.White,
                        unfocusedTextColor = Color.White,
                        focusedBorderColor = Color(0xFFEF4444),
                        unfocusedBorderColor = Color(0xFF334155)
                    ),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    singleLine = true
                )

                Spacer(modifier = Modifier.height(14.dp))

                // Server Wi-Fi Config Toggle
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    TextButton(
                        onClick = { showServerConfig = !showServerConfig },
                        colors = ButtonDefaults.textButtonColors(contentColor = Color(0xFF818CF8))
                    ) {
                        Icon(Icons.Default.Settings, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(if (showServerConfig) "Ẩn cấu hình IP" else "Chỉnh IP thủ công", fontSize = 12.sp)
                    }
                }

                if (showServerConfig) {
                    OutlinedTextField(
                        value = serverHost,
                        onValueChange = {
                            serverHost = it
                            sharedPrefs.serverHost = it
                        },
                        label = { Text("Server IP (LAN Wi-Fi)") },
                        modifier = Modifier.fillMaxWidth(),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedTextColor = Color.White,
                            unfocusedTextColor = Color.White,
                            focusedBorderColor = Color(0xFF6366F1),
                            unfocusedBorderColor = Color(0xFF334155)
                        ),
                        singleLine = true
                    )
                    Spacer(modifier = Modifier.height(12.dp))
                }

                Spacer(modifier = Modifier.height(8.dp))

                Button(
                    onClick = {
                        scope.launch {
                            isLoading = true
                            errorMessage = null
                            try {
                                sharedPrefs.serverHost = serverHost
                                val api = RetrofitClient.create(sharedPrefs)
                                val response = api.login(
                                    LoginRequest(
                                        email = email.trim(),
                                        password = password,
                                        deviceId = sharedPrefs.deviceId
                                    )
                                )

                                if (response.isSuccessful && response.body() != null) {
                                    val body = response.body()!!
                                    sharedPrefs.token = body.token
                                    sharedPrefs.userId = body.user.id
                                    sharedPrefs.userEmail = body.user.email
                                    sharedPrefs.userRole = body.user.role
                                    sharedPrefs.userExpiredAt = body.user.expiredAt

                                    onLoginSuccess()
                                } else {
                                    errorMessage = when (response.code()) {
                                        403 -> "Tài khoản của bạn đã hết hạn sử dụng!"
                                        401 -> "Sai email hoặc mật khẩu!"
                                        else -> "Đăng nhập thất bại (${response.code()})"
                                    }
                                }
                            } catch (e: Exception) {
                                errorMessage = "Lỗi kết nối tới Server Wi-Fi ($serverHost): ${e.message}"
                            } finally {
                                isLoading = false
                            }
                        }
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(52.dp),
                    shape = RoundedCornerShape(14.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFEF4444)),
                    enabled = !isLoading
                ) {
                    if (isLoading) {
                        CircularProgressIndicator(color = Color.White, modifier = Modifier.size(24.dp))
                    } else {
                        Text("Đăng Nhập", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                    }
                }
            }
        }
    }
}
