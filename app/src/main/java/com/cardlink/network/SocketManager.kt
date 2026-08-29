package com.cardlink.network

import android.util.Log
import com.cardlink.utils.SharedPrefs
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import io.socket.client.IO
import io.socket.client.Socket
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

class SocketManager(private val sharedPrefs: SharedPrefs) {

    private var socket: Socket? = null
    private val gson = Gson()

    private val _cardStackState = MutableStateFlow<List<List<String>>>(emptyList())
    val cardStackState: StateFlow<List<List<String>>> = _cardStackState.asStateFlow()

    private val _viewerCountState = MutableStateFlow(0)
    val viewerCountState: StateFlow<Int> = _viewerCountState.asStateFlow()

    private val _liveEndedEvent = MutableSharedFlow<String>()
    val liveEndedEvent: SharedFlow<String> = _liveEndedEvent.asSharedFlow()

    private val _isConnected = MutableStateFlow(false)
    val isConnected: StateFlow<Boolean> = _isConnected.asStateFlow()

    fun connect() {
        if (socket?.connected() == true) return

        try {
            val options = IO.Options().apply {
                auth = mapOf("token" to (sharedPrefs.token ?: ""))
                reconnection = true
                reconnectionAttempts = 10
                reconnectionDelay = 1000
                timeout = 10000
            }

            val url = sharedPrefs.socketUrl
            Log.d("SocketManager", "Connecting to Socket.IO at $url")
            socket = IO.socket(url, options)

            socket?.on(Socket.EVENT_CONNECT) {
                Log.d("SocketManager", "Socket.IO connected successfully")
                _isConnected.value = true
            }

            socket?.on(Socket.EVENT_DISCONNECT) {
                Log.d("SocketManager", "Socket.IO disconnected")
                _isConnected.value = false
            }

            socket?.on(Socket.EVENT_CONNECT_ERROR) { args ->
                Log.e("SocketManager", "Socket.IO connect error: ${args.firstOrNull()}")
                _isConnected.value = false
            }

            socket?.on("card_state") { args ->
                try {
                    val rawData = args.firstOrNull()
                    if (rawData != null) {
                        val jsonString = rawData.toString()
                        val type = object : TypeToken<List<List<String>>>() {}.type
                        val stack: List<List<String>> = gson.fromJson(jsonString, type)
                        _cardStackState.value = stack
                    }
                } catch (e: Exception) {
                    Log.e("SocketManager", "Error parsing card_state", e)
                }
            }

            socket?.on("viewer_count") { args ->
                try {
                    val count = (args.firstOrNull() as? Number)?.toInt() ?: 0
                    _viewerCountState.value = count
                } catch (e: Exception) {
                    Log.e("SocketManager", "Error parsing viewer_count", e)
                }
            }

            socket?.on("live_ended") { args ->
                val sessionId = args.firstOrNull()?.toString() ?: ""
                _liveEndedEvent.tryEmit(sessionId)
            }

            socket?.connect()
        } catch (e: Exception) {
            Log.e("SocketManager", "Socket.IO initialization error", e)
        }
    }

    fun joinRoom(sessionId: String) {
        connect()
        socket?.emit("join_room", sessionId)
        Log.d("SocketManager", "Emitted join_room for session: $sessionId")
    }

    fun leaveRoom(sessionId: String) {
        socket?.emit("leave_room", sessionId)
        Log.d("SocketManager", "Emitted leave_room for session: $sessionId")
    }

    fun sendCardDetected(sessionId: String, label: String, cardImage: String? = null) {
        val payload = JSONObject().apply {
            put("sessionId", sessionId)
            put("label", label)
            if (cardImage != null) {
                put("cardImage", cardImage)
            }
        }
        socket?.emit("card_detected", payload)
        Log.d("SocketManager", "Emitted card_detected: $label (hasImage=${cardImage != null}) for session: $sessionId")
    }

    fun sendLiveFrame(sessionId: String, frameBase64: String) {
        val payload = JSONObject().apply {
            put("sessionId", sessionId)
            put("frame", frameBase64)
        }
        socket?.emit("live_frame", payload)
    }

    fun disconnect() {
        socket?.disconnect()
        socket?.off()
        socket = null
        _isConnected.value = false
        _cardStackState.value = emptyList()
        _viewerCountState.value = 0
    }
}
