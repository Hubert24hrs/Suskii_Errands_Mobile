package com.suskiierrands.app

import android.content.Context
import android.telephony.TelephonyManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // SecureScreen (lib/app/secure_screen.dart): KYC, wallet, PIN and payout screens block
        // screenshots, screen recording and the recents thumbnail while they are open.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "suskii/secure_screen")
            .setMethodCallHandler { call, result ->
                if (call.method == "setSecure") {
                    if (call.arguments as? Boolean == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        // The country the phone is in (lib/app/device_country.dart): the network it is registered
        // on, then the SIM's country. Neither read needs a permission.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "suskii/device_region")
            .setMethodCallHandler { call, result ->
                if (call.method == "signals") {
                    val telephony = getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
                    result.success(
                        mapOf(
                            "network" to runCatching { telephony?.networkCountryIso }.getOrNull().orEmpty(),
                            "sim" to runCatching { telephony?.simCountryIso }.getOrNull().orEmpty(),
                            "timeZone" to java.util.TimeZone.getDefault().id,
                        ),
                    )
                } else {
                    result.notImplemented()
                }
            }
    }
}
