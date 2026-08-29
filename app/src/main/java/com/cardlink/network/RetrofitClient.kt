package com.cardlink.network

import com.cardlink.utils.SharedPrefs
import com.google.gson.annotations.SerializedName
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Response
import retrofit2.Retrofit
import retrofit2.converter.gson.GsonConverterFactory
import retrofit2.http.*
import java.util.concurrent.TimeUnit

data class LoginRequest(
    @SerializedName("email") val email: String,
    @SerializedName("password") val password: String,
    @SerializedName("deviceId") val deviceId: String
)

data class UserDto(
    @SerializedName("id") val id: String,
    @SerializedName("email") val email: String,
    @SerializedName("role") val role: String,
    @SerializedName("expiredAt") val expiredAt: String
)

data class LoginResponse(
    @SerializedName("user") val user: UserDto,
    @SerializedName("token") val token: String
)

data class StartSessionRequest(
    @SerializedName("rounds") val rounds: Int
)

data class StartSessionResponse(
    @SerializedName("sessionId") val sessionId: String,
    @SerializedName("streamId") val streamId: String,
    @SerializedName("antMediaWebSocketUrl") val antMediaWebSocketUrl: String,
    @SerializedName("rounds") val rounds: Int,
    @SerializedName("cardStack") val cardStack: List<List<String>>,
    @SerializedName("cardCount") val cardCount: Int
)

data class HeartbeatRequest(
    @SerializedName("sessionId") val sessionId: String
)

data class HeartbeatResponse(
    @SerializedName("success") val success: Boolean
)

data class GenericResponse(
    @SerializedName("success") val success: Boolean,
    @SerializedName("message") val message: String? = null
)

data class ActiveSessionDto(
    @SerializedName("sessionId") val sessionId: String,
    @SerializedName("streamId") val streamId: String,
    @SerializedName("antMediaWebSocketUrl") val antMediaWebSocketUrl: String,
    @SerializedName("deviceId") val deviceId: String,
    @SerializedName("startedAt") val startedAt: String,
    @SerializedName("rounds") val rounds: Int,
    @SerializedName("cardStack") val cardStack: List<List<String>>,
    @SerializedName("cardCount") val cardCount: Int,
    @SerializedName("broadcasterEmail") val broadcasterEmail: String?
)

interface ApiService {
    @POST("auth/login")
    suspend fun login(@Body req: LoginRequest): Response<LoginResponse>

    @GET("users/me")
    suspend fun getMe(): Response<UserDto>

    @POST("sessions/start")
    suspend fun startSession(@Body req: StartSessionRequest): Response<StartSessionResponse>

    @POST("sessions/heartbeat")
    suspend fun heartbeat(@Body req: HeartbeatRequest): Response<HeartbeatResponse>

    @DELETE("sessions/{sessionId}")
    suspend fun stopSession(@Path("sessionId") sessionId: String): Response<GenericResponse>

    @GET("sessions/active")
    suspend fun getActiveSessions(): Response<List<ActiveSessionDto>>
}

class DynamicBaseUrlInterceptor(private val sharedPrefs: SharedPrefs) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): okhttp3.Response {
        var request = chain.request()
        val currentHost = sharedPrefs.serverHost
        val newBaseUrl = "http://$currentHost:3000/api/".toHttpUrlOrNull()

        if (newBaseUrl != null) {
            val newUrl = request.url.newBuilder()
                .scheme(newBaseUrl.scheme)
                .host(newBaseUrl.host)
                .port(newBaseUrl.port)
                .build()
            request = request.newBuilder().url(newUrl).build()
        }

        // Add Authorization header if token exists
        val token = sharedPrefs.token
        if (!token.isNullOrBlank()) {
            request = request.newBuilder()
                .header("Authorization", "Bearer $token")
                .build()
        }

        return chain.proceed(request)
    }
}

object RetrofitClient {
    fun create(sharedPrefs: SharedPrefs): ApiService {
        val logging = HttpLoggingInterceptor().apply {
            level = HttpLoggingInterceptor.Level.BODY
        }

        val okHttpClient = OkHttpClient.Builder()
            .addInterceptor(DynamicBaseUrlInterceptor(sharedPrefs))
            .addInterceptor(logging)
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .writeTimeout(10, TimeUnit.SECONDS)
            .build()

        return Retrofit.Builder()
            .baseUrl(sharedPrefs.apiBaseUrl)
            .client(okHttpClient)
            .addConverterFactory(GsonConverterFactory.create())
            .build()
            .create(ApiService::class.java)
    }
}
