package com.cardlink

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.*
import androidx.core.content.ContextCompat
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.cardlink.network.ApiService
import com.cardlink.network.SocketManager
import com.cardlink.ui.screens.LiveScreen
import com.cardlink.ui.screens.LoginScreen
import com.cardlink.ui.screens.SelectSessionScreen
import com.cardlink.ui.screens.ViewerScreen
import com.cardlink.utils.SharedPrefs
import com.cardlink.webrtc.AntMediaManager
import dagger.hilt.android.AndroidEntryPoint
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import javax.inject.Inject

@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    @Inject lateinit var sharedPrefs: SharedPrefs
    @Inject lateinit var apiService: ApiService
    @Inject lateinit var socketManager: SocketManager
    @Inject lateinit var antMediaManager: AntMediaManager

    private val requestPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { _ -> }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        checkAndRequestPermissions()

        setContent {
            val navController = rememberNavController()
            val startDestination = if (sharedPrefs.token != null) "select_session" else "login"

            NavHost(
                navController = navController,
                startDestination = startDestination
            ) {
                composable("login") {
                    LoginScreen(
                        sharedPrefs = sharedPrefs,
                        onLoginSuccess = {
                            navController.navigate("select_session") {
                                popUpTo("login") { inclusive = true }
                            }
                        }
                    )
                }

                composable("select_session") {
                    SelectSessionScreen(
                        sharedPrefs = sharedPrefs,
                        apiService = apiService,
                        onStartLiveSuccess = { sessionId, rounds, antMediaUrl ->
                            val encodedUrl = URLEncoder.encode(antMediaUrl, StandardCharsets.UTF_8.toString())
                            navController.navigate("live/$sessionId/$rounds/$encodedUrl")
                        },
                        onJoinViewerSuccess = { sessionId, rounds, antMediaUrl ->
                            val encodedUrl = URLEncoder.encode(antMediaUrl, StandardCharsets.UTF_8.toString())
                            navController.navigate("viewer/$sessionId/$rounds/$encodedUrl")
                        },
                        onLogout = {
                            sharedPrefs.clearAuth()
                            navController.navigate("login") {
                                popUpTo("select_session") { inclusive = true }
                            }
                        }
                    )
                }

                composable(
                    route = "live/{sessionId}/{rounds}/{antMediaUrl}",
                    arguments = listOf(
                        navArgument("sessionId") { type = NavType.StringType },
                        navArgument("rounds") { type = NavType.IntType },
                        navArgument("antMediaUrl") { type = NavType.StringType }
                    )
                ) { backStackEntry ->
                    val sessionId = backStackEntry.arguments?.getString("sessionId") ?: ""
                    val rounds = backStackEntry.arguments?.getInt("rounds") ?: 3
                    val rawUrl = backStackEntry.arguments?.getString("antMediaUrl") ?: ""
                    val antMediaUrl = URLDecoder.decode(rawUrl, StandardCharsets.UTF_8.toString())

                    LiveScreen(
                        sessionId = sessionId,
                        rounds = rounds,
                        antMediaUrl = antMediaUrl,
                        apiService = apiService,
                        socketManager = socketManager,
                        antMediaManager = antMediaManager,
                        onStopLive = {
                            navController.popBackStack()
                        }
                    )
                }

                composable(
                    route = "viewer/{sessionId}/{rounds}/{antMediaUrl}",
                    arguments = listOf(
                        navArgument("sessionId") { type = NavType.StringType },
                        navArgument("rounds") { type = NavType.IntType },
                        navArgument("antMediaUrl") { type = NavType.StringType }
                    )
                ) { backStackEntry ->
                    val sessionId = backStackEntry.arguments?.getString("sessionId") ?: ""
                    val rounds = backStackEntry.arguments?.getInt("rounds") ?: 3
                    val rawUrl = backStackEntry.arguments?.getString("antMediaUrl") ?: ""
                    val antMediaUrl = URLDecoder.decode(rawUrl, StandardCharsets.UTF_8.toString())

                    ViewerScreen(
                        sessionId = sessionId,
                        rounds = rounds,
                        antMediaUrl = antMediaUrl,
                        socketManager = socketManager,
                        antMediaManager = antMediaManager,
                        onBack = {
                            navController.popBackStack()
                        }
                    )
                }
            }
        }
    }

    private fun checkAndRequestPermissions() {
        val permissions = mutableListOf(
            Manifest.permission.CAMERA,
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.ACCESS_NETWORK_STATE,
            Manifest.permission.ACCESS_WIFI_STATE
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        }

        val neededPermissions = permissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }

        if (neededPermissions.isNotEmpty()) {
            requestPermissionLauncher.launch(neededPermissions.toTypedArray())
        }
    }
}
