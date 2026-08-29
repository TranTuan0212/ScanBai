package com.cardlink.ui.screens

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import androidx.camera.view.PreviewView
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.cardlink.network.ApiService
import com.cardlink.network.SocketManager
import com.cardlink.service.LiveForegroundService
import com.cardlink.webrtc.AntMediaManager
import kotlinx.coroutines.launch

/**
 * Pure Full-Screen Live Camera Viewfinder (Broadcaster Role)
 * Distraction-Free: Zero card overlays/scores cluttering the screen.
 * Dedicated strictly to capturing crystal-clear live video & deal photos.
 */
@Composable
fun LiveScreen(
    sessionId: String,
    rounds: Int,
    antMediaUrl: String,
    apiService: ApiService,
    socketManager: SocketManager,
    antMediaManager: AntMediaManager,
    onStopLive: () -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    val viewerCount by socketManager.viewerCountState.collectAsState()

    var liveService by remember { mutableStateOf<LiveForegroundService?>(null) }
    var isBound by remember { mutableStateOf(false) }

    // Bind to LiveForegroundService
    DisposableEffect(sessionId) {
        val intent = Intent(context, LiveForegroundService::class.java).apply {
            action = LiveForegroundService.ACTION_START_LIVE
            putExtra(LiveForegroundService.EXTRA_SESSION_ID, sessionId)
            putExtra(LiveForegroundService.EXTRA_ROUNDS, rounds)
        }
        context.startForegroundService(intent)

        val serviceConnection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
                val binder = service as? LiveForegroundService.LocalBinder
                liveService = binder?.getService()
                isBound = true
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                liveService = null
                isBound = false
            }
        }

        context.bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)

        onDispose {
            if (isBound) {
                context.unbindService(serviceConnection)
            }
        }
    }

    LaunchedEffect(Unit) {
        socketManager.liveEndedEvent.collect { endedSessionId ->
            if (endedSessionId == sessionId) {
                onStopLive()
            }
        }
    }

    var isCapturingFlash by remember { mutableStateOf(false) }

    fun triggerSnap() {
        liveService?.captureCurrentFrameAsCard()
        scope.launch {
            isCapturingFlash = true
            kotlinx.coroutines.delay(250)
            isCapturingFlash = false
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .clickable {
                triggerSnap()
            }
    ) {
        // Fullscreen CameraX Preview View
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                PreviewView(ctx).apply {
                    implementationMode = PreviewView.ImplementationMode.COMPATIBLE
                    post {
                        liveService?.getCameraXManager()?.attachPreviewView(this)
                    }
                }
            },
            update = { previewView ->
                liveService?.getCameraXManager()?.attachPreviewView(previewView)
            }
        )

        // Green HUD Capture Flash Border
        if (isCapturingFlash) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .border(BorderStroke(4.dp, Color(0xFF22C55E)))
            )
        }

        // Top Control Bar
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            // Live Status & Viewer Count Badges
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Surface(
                    shape = RoundedCornerShape(20.dp),
                    color = Color(0xFFDC2626)
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(
                            modifier = Modifier
                                .size(8.dp)
                                .background(Color.White, CircleShape)
                        )
                        Spacer(modifier = Modifier.width(6.dp))
                        Text("LIVE", color = Color.White, fontWeight = FontWeight.Black, fontSize = 12.sp)
                    }
                }

                Surface(
                    shape = RoundedCornerShape(20.dp),
                    color = Color(0x99000000)
                ) {
                    Text(
                        text = "👁️ $viewerCount",
                        color = Color.White,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp)
                    )
                }
            }

            // Quick Control Buttons (Snap, Torch, Switch Camera, Stop)
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                var isTorchOn by remember { mutableStateOf(false) }

                // Quick Snapshot Button
                IconButton(
                    onClick = {
                        triggerSnap()
                    },
                    modifier = Modifier.background(Color(0xFF3B82F6), CircleShape)
                ) {
                    Text("📸", fontSize = 16.sp)
                }

                // Flash Torch Button
                IconButton(
                    onClick = {
                        val newState = liveService?.toggleTorch() ?: false
                        isTorchOn = newState
                    },
                    modifier = Modifier.background(if (isTorchOn) Color(0xFFF59E0B) else Color(0x99000000), CircleShape)
                ) {
                    Text("⚡", fontSize = 16.sp)
                }

                // Switch Camera Button
                IconButton(
                    onClick = {
                        liveService?.switchCamera()
                    },
                    modifier = Modifier.background(Color(0x99000000), CircleShape)
                ) {
                    Icon(Icons.Default.Refresh, contentDescription = "Switch Camera", tint = Color.White)
                }

                // Stop Live Button
                IconButton(
                    onClick = {
                        scope.launch {
                            try {
                                apiService.stopSession(sessionId)
                            } catch (_: Exception) {}
                            val stopIntent = Intent(context, LiveForegroundService::class.java).apply {
                                action = LiveForegroundService.ACTION_STOP_LIVE
                            }
                            context.startService(stopIntent)
                            onStopLive()
                        }
                    },
                    modifier = Modifier.background(Color(0xCCEF4444), CircleShape)
                ) {
                    Icon(Icons.Default.Close, contentDescription = "Stop Live", tint = Color.White)
                }
            }
        }

        // 1-Tap Floating Photo Deal Button on Right Edge
        FloatingActionButton(
            onClick = {
                triggerSnap()
            },
            modifier = Modifier
                .align(Alignment.CenterEnd)
                .padding(end = 16.dp),
            containerColor = Color(0xFF3B82F6),
            contentColor = Color.White,
            shape = CircleShape
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp)
            ) {
                Text("📸", fontSize = 22.sp)
                Text("Chụp Lá", fontSize = 9.sp, fontWeight = FontWeight.Black, color = Color.White)
            }
        }
    }
}
