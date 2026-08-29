package com.cardlink.network

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log
import kotlinx.coroutines.*
import org.json.JSONObject
import java.net.*

object ServerDiscovery {

    private const val DISCOVERY_PORT = 3001
    private const val DISCOVERY_MESSAGE = "CARDLINK_DISCOVERY_REQUEST"

    /**
     * Automatically discover the CardLink Server IP in the local Wi-Fi / Hotspot network
     */
    suspend fun discoverServerIp(context: Context, currentHost: String? = null): String? = withContext(Dispatchers.IO) {
        val phoneIp = getDeviceIpAddress()
        val gatewayIp = getGatewayIp(context)
        Log.d("ServerDiscovery", "Phone IP: $phoneIp, Gateway IP: $gatewayIp, Current Host: $currentHost")

        // 1. Try UDP Broadcast Discovery with multiple broadcast targets
        val udpResult = discoverViaUdp(phoneIp)
        if (udpResult != null) {
            Log.d("ServerDiscovery", "⚡ Found server via UDP Broadcast: $udpResult")
            return@withContext udpResult
        }

        // 2. High-speed Parallel HTTP Subnet Scanner (scans candidates concurrently)
        val candidates = mutableListOf<String>()

        // Add Emulator host, Gateway, and CurrentHost
        candidates.add("10.0.2.2")
        if (!gatewayIp.isNullOrBlank()) candidates.add(gatewayIp)
        if (!currentHost.isNullOrBlank() && currentHost != "192.168.1.100") candidates.add(currentHost)

        // Generate subnet IP list from phone's IP (e.g. 192.168.1.1..30 or 172.20.10.1..20)
        if (phoneIp != null && phoneIp.contains(".")) {
            val prefix = phoneIp.substringBeforeLast(".")
            // Common IPs assigned by Wi-Fi / Hotspot DHCP
            for (i in 1..25) {
                val ip = "$prefix.$i"
                if (ip != phoneIp) {
                    candidates.add(ip)
                }
            }
        }

        val distinctCandidates = candidates.distinct()
        Log.d("ServerDiscovery", "Scanning ${distinctCandidates.size} candidate IPs in parallel...")

        // Probe all candidates concurrently with short timeout
        val foundIp = findFirstRespondingIp(distinctCandidates)
        if (foundIp != null) {
            Log.d("ServerDiscovery", "⚡ Found server via fast Subnet Probe: $foundIp")
            return@withContext foundIp
        }

        Log.w("ServerDiscovery", "No server found during auto-discovery.")
        return@withContext null
    }

    private suspend fun findFirstRespondingIp(candidates: List<String>): String? = coroutineScope {
        val deferredList = candidates.map { ip ->
            async(Dispatchers.IO) {
                if (probeHttpHealth(ip)) ip else null
            }
        }

        for (deferred in deferredList) {
            val res = deferred.await()
            if (res != null) {
                // Cancel remaining tasks immediately once found
                coroutineContext.cancelChildren()
                return@coroutineScope res
            }
        }
        null
    }

    private fun discoverViaUdp(phoneIp: String?): String? {
        var socket: DatagramSocket? = null
        try {
            socket = DatagramSocket().apply {
                broadcast = true
                soTimeout = 800 // 800ms timeout
            }

            val sendData = DISCOVERY_MESSAGE.toByteArray(Charsets.UTF_8)

            // Broadcast to 255.255.255.255
            val globalBroadcast = InetAddress.getByName("255.255.255.255")
            socket.send(DatagramPacket(sendData, sendData.size, globalBroadcast, DISCOVERY_PORT))

            // Also broadcast to subnet broadcast (e.g. 192.168.1.255 or 172.20.10.255)
            if (phoneIp != null && phoneIp.contains(".")) {
                try {
                    val subnetBroadcast = InetAddress.getByName("${phoneIp.substringBeforeLast(".")}.255")
                    socket.send(DatagramPacket(sendData, sendData.size, subnetBroadcast, DISCOVERY_PORT))
                } catch (_: Exception) {}
            }

            val receiveBuffer = ByteArray(1024)
            val receivePacket = DatagramPacket(receiveBuffer, receiveBuffer.size)
            socket.receive(receivePacket)

            val responseString = String(receivePacket.data, 0, receivePacket.length, Charsets.UTF_8).trim()
            val json = JSONObject(responseString)

            if (json.optString("service") == "cardlink") {
                val ip = json.optString("ip")
                if (ip.isNotBlank()) {
                    return ip
                }
            }
            return receivePacket.address.hostAddress
        } catch (e: Exception) {
            Log.d("ServerDiscovery", "UDP broadcast timeout/error: ${e.message}")
            return null
        } finally {
            socket?.close()
        }
    }

    private fun probeHttpHealth(ip: String): Boolean {
        return try {
            val url = URL("http://$ip:3000/api/health")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                connectTimeout = 600
                readTimeout = 600
                requestMethod = "GET"
            }
            val code = conn.responseCode
            conn.disconnect()
            code == 200
        } catch (_: Exception) {
            false
        }
    }

    fun getDeviceIpAddress(): String? {
        try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            while (interfaces.hasMoreElements()) {
                val iface = interfaces.nextElement()
                val addresses = iface.inetAddresses
                while (addresses.hasMoreElements()) {
                    val addr = addresses.nextElement()
                    if (!addr.isLoopbackAddress && addr is Inet4Address) {
                        val host = addr.hostAddress
                        if (host != null && !host.startsWith("127.") && !host.startsWith("169.254")) {
                            return host
                        }
                    }
                }
            }
        } catch (_: Exception) {}
        return null
    }

    private fun getGatewayIp(context: Context): String? {
        return try {
            val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            val dhcp = wifiManager?.dhcpInfo ?: return null
            val gateway = dhcp.gateway
            if (gateway == 0) return null
            "${gateway and 0xFF}.${gateway shr 8 and 0xFF}.${gateway shr 16 and 0xFF}.${gateway shr 24 and 0xFF}"
        } catch (_: Exception) {
            null
        }
    }
}
