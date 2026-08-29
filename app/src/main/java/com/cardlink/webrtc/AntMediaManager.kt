package com.cardlink.webrtc

import android.app.Activity
import android.content.Context
import android.util.Log
import io.antmedia.webrtcandroidframework.api.DefaultWebRTCListener
import io.antmedia.webrtcandroidframework.api.IWebRTCClient
import io.antmedia.webrtcandroidframework.api.WebRTCClientBuilder
import io.antmedia.webrtcandroidframework.core.WebRTCClient
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoTrack

class AntMediaManager(private val context: Context) {

    private var webRTCClient: WebRTCClient? = null
    private var currentStreamId: String? = null
    private var isPublishing: Boolean = false

    interface StreamEventsListener {
        fun onPublishStarted(streamId: String)
        fun onPlayStarted(streamId: String)
        fun onStreamEnded(streamId: String)
        fun onError(description: String)
    }

    private var listener: StreamEventsListener? = null

    fun setStreamEventsListener(listener: StreamEventsListener) {
        this.listener = listener
    }

    /**
     * Start WebRTC Publish (Broadcaster)
     */
    fun startPublish(
        activity: Activity?,
        serverUrl: String,
        streamId: String,
        localRenderer: SurfaceViewRenderer? = null
    ) {
        this.currentStreamId = streamId
        this.isPublishing = true

        try {
            val builder = IWebRTCClient.builder()
                .setServerUrl(serverUrl)
                .setStreamId(streamId)
                .setVideoCallEnabled(true)
                .setAudioCallEnabled(true)
                .setReconnectionEnabled(true)
                .setVideoSource(IWebRTCClient.StreamSource.REAR_CAMERA)
                .setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT)

            if (activity != null) {
                builder.setActivity(activity)
            }

            if (localRenderer != null) {
                builder.setLocalVideoRenderer(localRenderer)
            }

            builder.setWebRTCListener(object : DefaultWebRTCListener() {
                override fun onWebSocketConnected() {
                    Log.d("AntMediaManager", "WebSocket connected to Ant Media Server: $serverUrl")
                    webRTCClient?.publish(streamId)
                }

                override fun onPublishStarted(streamId: String) {
                    Log.d("AntMediaManager", "Publish started for stream: $streamId")
                    listener?.onPublishStarted(streamId)
                }

                override fun onPublishFinished(streamId: String) {
                    Log.d("AntMediaManager", "Publish finished for stream: $streamId")
                    listener?.onStreamEnded(streamId)
                }

                override fun onError(description: String, streamId: String?) {
                    Log.e("AntMediaManager", "Ant Media Publish Error: $description")
                    listener?.onError(description)
                }
            })

            webRTCClient = builder.build()
            Log.d("AntMediaManager", "AntMedia WebRTCClient initialized for publish: $streamId")
        } catch (e: Exception) {
            Log.e("AntMediaManager", "Failed to start publish", e)
            listener?.onError("Init Error: ${e.message}")
        }
    }

    /**
     * Start WebRTC Play (Viewer)
     */
    fun startPlay(
        activity: Activity?,
        serverUrl: String,
        streamId: String,
        remoteRenderer: SurfaceViewRenderer
    ) {
        this.currentStreamId = streamId
        this.isPublishing = false

        try {
            val builder = IWebRTCClient.builder()
                .setServerUrl(serverUrl)
                .setStreamId(streamId)
                .setVideoCallEnabled(true)
                .setAudioCallEnabled(true)
                .setReconnectionEnabled(true)
                .addRemoteVideoRenderer(remoteRenderer)
                .setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT)

            if (activity != null) {
                builder.setActivity(activity)
            }

            builder.setWebRTCListener(object : DefaultWebRTCListener() {
                override fun onWebSocketConnected() {
                    Log.d("AntMediaManager", "WebSocket connected. Playing stream: $streamId")
                    webRTCClient?.play(streamId)
                }

                override fun onPlayStarted(streamId: String) {
                    Log.d("AntMediaManager", "Play started for stream: $streamId")
                    listener?.onPlayStarted(streamId)
                }

                override fun onPlayFinished(streamId: String) {
                    Log.d("AntMediaManager", "Play finished for stream: $streamId")
                    listener?.onStreamEnded(streamId)
                }

                override fun onNewVideoTrack(videoTrack: VideoTrack, streamId: String?) {
                    Log.d("AntMediaManager", "New video track received for stream: $streamId")
                    webRTCClient?.setRendererForVideoTrack(remoteRenderer, videoTrack)
                }

                override fun onError(description: String, streamId: String?) {
                    Log.e("AntMediaManager", "Ant Media Play Error: $description")
                    listener?.onError(description)
                }
            })

            webRTCClient = builder.build()
            Log.d("AntMediaManager", "AntMedia WebRTCClient initialized for play: $streamId")
        } catch (e: Exception) {
            Log.e("AntMediaManager", "Failed to start play", e)
            listener?.onError("Init Error: ${e.message}")
        }
    }

    /**
     * Switch camera during active publish
     */
    fun switchCamera() {
        if (isPublishing && webRTCClient != null) {
            try {
                webRTCClient?.switchCamera()
                Log.d("AntMediaManager", "Switched camera in Ant Media WebRTCClient")
            } catch (e: Exception) {
                Log.e("AntMediaManager", "Error switching camera in WebRTCClient", e)
            }
        }
    }

    fun stopStream() {
        val streamId = currentStreamId
        if (streamId != null && webRTCClient != null) {
            try {
                webRTCClient?.stop(streamId)
            } catch (e: Exception) {
                Log.e("AntMediaManager", "Error stopping stream", e)
            }
        }
        currentStreamId = null
        webRTCClient = null
    }
}
