# Proguard Rules for CardLink Broadcast

# WebRTC and Ant Media SDK
-keep class org.webrtc.** { *; }
-keep class io.antmedia.webrtcandroidframework.** { *; }

# TensorFlow Lite
-keep class org.tensorflow.lite.** { *; }

# Socket.IO
-keep class io.socket.** { *; }
-keep class io.socket.client.** { *; }
-keep class io.socket.emitter.** { *; }
-keep class io.socket.engineio.client.** { *; }

# Gson models
-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
-keep class com.cardlink.network.models.** { *; }
