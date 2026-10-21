package ru.exvpn.exvpn

import android.content.res.Configuration

/** Presentation only: no permissions, storage, routes, or VPN state changes. */
internal object AndroidPresentation {
    fun isTelevision(uiMode: Int, televisionFeature: Boolean, leanbackFeature: Boolean): Boolean =
        uiMode and Configuration.UI_MODE_TYPE_MASK == Configuration.UI_MODE_TYPE_TELEVISION ||
            televisionFeature || leanbackFeature
}
