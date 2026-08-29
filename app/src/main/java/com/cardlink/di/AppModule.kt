package com.cardlink.di

import android.content.Context
import com.cardlink.network.ApiService
import com.cardlink.network.RetrofitClient
import com.cardlink.network.SocketManager
import com.cardlink.utils.SharedPrefs
import com.cardlink.webrtc.AntMediaManager
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    @Provides
    @Singleton
    fun provideSharedPrefs(@ApplicationContext context: Context): SharedPrefs {
        return SharedPrefs(context)
    }

    @Provides
    @Singleton
    fun provideApiService(sharedPrefs: SharedPrefs): ApiService {
        return RetrofitClient.create(sharedPrefs)
    }

    @Provides
    @Singleton
    fun provideSocketManager(sharedPrefs: SharedPrefs): SocketManager {
        return SocketManager(sharedPrefs)
    }

    @Provides
    @Singleton
    fun provideAntMediaManager(@ApplicationContext context: Context): AntMediaManager {
        return AntMediaManager(context)
    }
}
