package io.tilde.dynamictabbar

import android.app.Application
import dev.hotwire.core.bridge.BridgeComponentFactory
import dev.hotwire.core.config.Hotwire
import dev.hotwire.core.turbo.config.PathConfiguration
import dev.hotwire.navigation.config.defaultFragmentDestination
import dev.hotwire.navigation.config.registerBridgeComponents
import dev.hotwire.navigation.config.registerFragmentDestinations
import dev.hotwire.navigation.fragments.HotwireWebBottomSheetFragment
import dev.hotwire.navigation.fragments.HotwireWebFragment

class DynamicTabBarApplication : Application() {
    companion object {
        private const val BASE_URL = "http://10.0.2.2:3000"
    }

    override fun onCreate() {
        super.onCreate()

        Hotwire.loadPathConfiguration(
            context = this,
            location = PathConfiguration.Location(
                assetFilePath = "json/path-configuration.json",
                remoteFileUrl = "$BASE_URL/configurations/navigation"
            )
        )

        Hotwire.defaultFragmentDestination = HotwireWebFragment::class
        Hotwire.registerFragmentDestinations(
            HotwireWebFragment::class,
            HotwireWebBottomSheetFragment::class
        )

        Hotwire.registerBridgeComponents(
            BridgeComponentFactory("navigation", ::NavigationComponent)
        )

        Hotwire.config.debugLoggingEnabled = true
    }
}
