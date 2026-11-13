package com.luogen.logen_audio

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "logen/demucs")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "separate" -> {
                    val model = call.argument<String>("model")
                    val mix = call.argument<String>("mix")
                    val vocal = call.argument<String>("vocal")
                    val inst = call.argument<String>("inst")
                    val samples = call.argument<Int>("samples") ?: 0
                    if (model == null || mix == null || vocal == null || inst == null) {
                        result.error("bad_args", "参数不全", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            DemucsRunner.separate(model, mix, vocal, inst, samples) { p ->
                                main.post {
                                    try {
                                        ch.invokeMethod("progress", p)
                                    } catch (_: Exception) {
                                    }
                                }
                            }
                            main.post { result.success(null) }
                        } catch (t: Throwable) {
                            main.post { result.error("demucs_fail", t.message ?: t.toString(), null) }
                        }
                    }.start()
                }
                "separateMdx" -> {
                    val model = call.argument<String>("model")
                    val mix = call.argument<String>("mix")
                    val vocal = call.argument<String>("vocal")
                    val inst = call.argument<String>("inst")
                    val samples = call.argument<Int>("samples") ?: 0
                    if (model == null || mix == null || vocal == null || inst == null) {
                        result.error("bad_args", "参数不全", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            MdxRunner.run(model, mix, vocal, inst, samples) { p ->
                                main.post {
                                    try {
                                        ch.invokeMethod("progress", p)
                                    } catch (_: Exception) {
                                    }
                                }
                            }
                            main.post { result.success(null) }
                        } catch (t: Throwable) {
                            main.post { result.error("mdx_fail", t.message ?: t.toString(), null) }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }
}
