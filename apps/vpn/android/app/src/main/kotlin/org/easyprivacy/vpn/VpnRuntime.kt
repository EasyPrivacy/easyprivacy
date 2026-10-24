package org.easyprivacy.vpn

import android.content.Context
import android.content.Intent
import android.os.Build
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.Tunnel
import com.wireguard.config.Config
import java.io.ByteArrayInputStream
import java.util.concurrent.Executors

object VpnRuntime {
    val executor = Executors.newSingleThreadExecutor()
    private lateinit var context: Context
    private val backend: GoBackend by lazy { GoBackend(context) }
    private val tunnel = object : Tunnel {
        override fun getName() = "EasyPrivacy"
        override fun onStateChange(state: Tunnel.State) {
            if (state == Tunnel.State.DOWN) {
                context.stopService(Intent(context, VpnForegroundService::class.java))
                VpnNotifications.publish(context, mapOf("active" to false))
            }
        }
    }
    fun initialize(ctx: Context) { context = ctx.applicationContext }
    fun status(): Map<String, Any> {
        val active = backend.getState(tunnel) == Tunnel.State.UP
        var handshake = 0L
        val stats = backend.getStatistics(tunnel)
        for (peer in stats.peers()) handshake = maxOf(handshake, (stats.peer(peer)?.latestHandshakeEpochMillis() ?: 0) / 1000)
        return mapOf("installed" to true, "active" to active, "last_handshake" to handshake, "received" to stats.totalRx(), "sent" to stats.totalTx())
    }
    fun connect(values: Map<*, *>) {
        fun text(name: String): String {
            val value = values[name] as? String ?: error("Missing VPN setting")
            require(value.isNotEmpty() && value.length < 300 && !value.contains('\n') && !value.contains('\r') && !value.contains('\u0000'))
            return value
        }
        val dns = (values["dns"] as? List<*>)?.map { it as String } ?: error("Missing DNS servers")
        require(dns.isNotEmpty() && dns.size <= 3 && dns.all { it.matches(Regex("[0-9.]{7,15}")) })
        require(values["mtu"] == 1280 && values["keepalive"] == 25)
        val management = (values["management_routes"] as? List<*>)?.map { it as String } ?: emptyList()
        require(management.size <= 16 && management.distinct().size == management.size)
        for (route in management) {
            require(route.matches(Regex("[0-9.]{7,15}/32")))
            val octets = route.removeSuffix("/32").split('.').map { it.toInt() }
            require(octets.size == 4 && octets.all { it in 0..255 })
            require(octets[0] == 10 || (octets[0] == 172 && octets[1] in 16..31) || (octets[0] == 192 && octets[1] == 168))
        }
        val allowed = (listOf("0.0.0.0/0", "::/0") + management).joinToString(", ")
        val config = """
            [Interface]
            PrivateKey = ${text("private_key")}
            Address = ${text("address")}, ${text("address_v6")}
            DNS = ${dns.joinToString(", ")}
            MTU = 1280
            ExcludedApplications = org.easyprivacy.easyprivacy

            [Peer]
            PublicKey = ${text("public_key")}
            Endpoint = ${text("endpoint")}
            AllowedIPs = $allowed
            PersistentKeepalive = 25
        """.trimIndent()
        val parsed = Config.parse(ByteArrayInputStream(config.toByteArray(Charsets.UTF_8)))
        backend.setState(tunnel, Tunnel.State.UP, parsed)
        try {
            val intent = Intent(context, VpnForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        } catch (error: Exception) {
            backend.setState(tunnel, Tunnel.State.DOWN, null)
            throw error
        }
    }
    fun disconnect() { backend.setState(tunnel, Tunnel.State.DOWN, null); context.stopService(Intent(context, VpnForegroundService::class.java)) }
}
