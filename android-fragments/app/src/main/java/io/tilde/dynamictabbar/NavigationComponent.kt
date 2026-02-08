package io.tilde.dynamictabbar

import android.util.Log
import dev.hotwire.core.bridge.BridgeComponent
import dev.hotwire.core.bridge.BridgeDelegate
import dev.hotwire.core.bridge.Message
import dev.hotwire.navigation.destinations.HotwireDestination
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

private const val TAG = "Navigation"

/** Singleton for NavigationComponent → MainActivity communication. */
object TabDirectiveRouter {
    var listener: ((TabsDirective) -> Unit)? = null
    fun send(directive: TabsDirective) { listener?.invoke(directive) }
}

class NavigationComponent(
    name: String,
    private val delegate: BridgeDelegate<HotwireDestination>
) : BridgeComponent<HotwireDestination>(name, delegate) {

    override fun onReceive(message: Message) {
        when (message.event) {
            "configure" -> handleConfigure(message)
            else -> Log.w(TAG, "Received unknown event: ${message.event}")
        }
    }

    private fun handleConfigure(message: Message) {
        val data = try {
            json.decodeFromString<MessageData>(message.jsonData)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to decode message data")
            return
        }

        val directive = if (data.tabs.isEmpty()) {
            TabsDirective.Bootstrap
        } else {
            val active = data.active
            if (active == null) {
                Log.e(TAG, "Protocol violation: non-empty tabs without active field")
                return
            }
            TabsDirective.Tabbed(active = active, tabs = data.tabs)
        }

        TabDirectiveRouter.send(directive)

        val mode = if (directive.tabsList.isEmpty()) "Bootstrap" else "Tabbed(${directive.tabsList.size})"
        Log.d(TAG, "Sent tab config: $mode")
    }

    companion object {
        private val json = Json { ignoreUnknownKeys = true }
    }
}

@Serializable
private data class MessageData(
    val active: String? = null,
    val tabs: List<TabData> = emptyList()
)
