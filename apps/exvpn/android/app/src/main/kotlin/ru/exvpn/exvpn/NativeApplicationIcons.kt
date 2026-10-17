package ru.exvpn.exvpn

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import java.io.ByteArrayOutputStream

/** Data only: fixed raster dimensions and bounded PNG, never provider content. */
internal object NativeApplicationIcons {
    fun png(context: Context, packageId: String): ByteArray? = try {
        val drawable = context.packageManager.getApplicationIcon(packageId).mutate()
        val bitmap = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888)
        try {
            drawable.setBounds(0, 0, 64, 64)
            drawable.draw(Canvas(bitmap))
            val output = ByteArrayOutputStream(16 * 1024)
            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) null
            else output.toByteArray().takeIf { it.isNotEmpty() && it.size <= 64 * 1024 }
        } finally { bitmap.recycle() }
    } catch (_: Exception) { null }
}
