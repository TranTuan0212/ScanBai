package com.cardlink.utils

import android.content.Context
import android.content.SharedPreferences
import java.util.UUID

class SharedPrefs(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences("cardlink_prefs", Context.MODE_PRIVATE)

    companion object {
        private const val KEY_DEVICE_ID = "key_device_id"
        private const val KEY_SERVER_HOST = "key_server_host"
        private const val KEY_TOKEN = "key_jwt_token"
        private const val KEY_USER_ID = "key_user_id"
        private const val KEY_USER_EMAIL = "key_user_email"
        private const val KEY_USER_ROLE = "key_user_role"
        private const val KEY_USER_EXPIRED_AT = "key_user_expired_at"
        private const val DEFAULT_SERVER_HOST = "192.168.1.4"
    }

    /**
     * Stable UUID v4 device identifier generated once upon first install
     */
    val deviceId: String
        get() {
            var id = prefs.getString(KEY_DEVICE_ID, null)
            if (id.isNullOrBlank()) {
                id = UUID.randomUUID().toString()
                prefs.edit().putString(KEY_DEVICE_ID, id).apply()
            }
            return id
        }

    var serverHost: String
        get() {
            val saved = prefs.getString(KEY_SERVER_HOST, null)
            return if (saved.isNullOrBlank() || saved == "192.168.1.100") DEFAULT_SERVER_HOST else saved
        }
        set(value) = prefs.edit().putString(KEY_SERVER_HOST, value.trim()).apply()

    val apiBaseUrl: String
        get() = "http://$serverHost:3000/api/"

    val socketUrl: String
        get() = "http://$serverHost:3000"

    var token: String?
        get() = prefs.getString(KEY_TOKEN, null)
        set(value) = prefs.edit().putString(KEY_TOKEN, value).apply()

    var userId: String?
        get() = prefs.getString(KEY_USER_ID, null)
        set(value) = prefs.edit().putString(KEY_USER_ID, value).apply()

    var userEmail: String?
        get() = prefs.getString(KEY_USER_EMAIL, null)
        set(value) = prefs.edit().putString(KEY_USER_EMAIL, value).apply()

    var userRole: String?
        get() = prefs.getString(KEY_USER_ROLE, "view")
        set(value) = prefs.edit().putString(KEY_USER_ROLE, value).apply()

    var userExpiredAt: String?
        get() = prefs.getString(KEY_USER_EXPIRED_AT, null)
        set(value) = prefs.edit().putString(KEY_USER_EXPIRED_AT, value).apply()

    fun clearAuth() {
        prefs.edit()
            .remove(KEY_TOKEN)
            .remove(KEY_USER_ID)
            .remove(KEY_USER_EMAIL)
            .remove(KEY_USER_ROLE)
            .remove(KEY_USER_EXPIRED_AT)
            .apply()
    }
}
