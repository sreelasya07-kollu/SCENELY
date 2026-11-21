package dev.capturekit.capture

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.HandlerThread

/**
 * Feeds a [StillnessCalibrator] from the gyroscope, the uncalibrated gyroscope (drift estimate values[3..5], when the
 * phone has it) and the accelerometer, on a dedicated thread (never the AR/GL thread). SensorEvent.timestamp is on the
 * elapsedRealtimeNanos base, the same base the calibrator's start time must use. Separate from [SensorBridge] on purpose:
 * that one writes to a session; this one runs before any session exists.
 */
class StillnessSensors(context: Context, private val calibrator: StillnessCalibrator) : SensorEventListener {
    private val sm = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private var thread: HandlerThread? = null

    /** False when the phone has no gyroscope or no accelerometer: the calibration can never finish (the caller says so). */
    fun start(): Boolean {
        val gyro = sm.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
        val accel = sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        if (gyro == null || accel == null) return false
        val t = HandlerThread("ck-still").also { it.start() }
        thread = t
        val h = Handler(t.looper)
        sm.registerListener(this, gyro, PERIOD_US, h)
        sm.registerListener(this, accel, PERIOD_US, h)
        sm.getDefaultSensor(Sensor.TYPE_GYROSCOPE_UNCALIBRATED)?.let { sm.registerListener(this, it, PERIOD_US, h) }
        return true
    }

    fun stop() {
        sm.unregisterListener(this)
        thread?.quitSafely()
        thread = null
    }

    override fun onSensorChanged(e: SensorEvent) {
        val v = e.values
        when (e.sensor.type) {
            Sensor.TYPE_GYROSCOPE -> calibrator.onGyro(e.timestamp, v[0].toDouble(), v[1].toDouble(), v[2].toDouble())
            Sensor.TYPE_GYROSCOPE_UNCALIBRATED -> if (v.size >= 6) calibrator.onGyroUncalibrated(e.timestamp, v[3].toDouble(), v[4].toDouble(), v[5].toDouble())
            Sensor.TYPE_ACCELEROMETER -> calibrator.onAccel(e.timestamp, v[0].toDouble(), v[1].toDouble(), v[2].toDouble())
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    private companion object { const val PERIOD_US = 5000 }
}
