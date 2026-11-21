import Foundation

/// The AR camera at one frame: T_world_from_camera (rotation `qw`..`qz`, translation `tx`..`tz`; ARKit camera axes, X right /
/// Y up / looking down -Z, aligned with the captured image) and the pixel intrinsics of a `w` x `h` image.
/// Own pinhole math (not ARCamera.projectPoint); the ARKit -> OpenCV axis flip happens only in `project`, `depthOf` and `ray`
/// (AGENTS.md C). Pure Foundation so the macOS host tests compile it.
public struct CameraSnapshot: Equatable {
    public var qw: Double, qx: Double, qy: Double, qz: Double
    public var tx: Double, ty: Double, tz: Double
    public var fx: Double, fy: Double, cx: Double, cy: Double
    public var w: Int, h: Int

    public static let minDepthM = 0.1

    public init(qw: Double, qx: Double, qy: Double, qz: Double, tx: Double, ty: Double, tz: Double,
                fx: Double, fy: Double, cx: Double, cy: Double, w: Int, h: Int) {
        self.qw = qw; self.qx = qx; self.qy = qy; self.qz = qz; self.tx = tx; self.ty = ty; self.tz = tz
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy; self.w = w; self.h = h
    }

    /// From an ARKit `camera.transform` (simd_float4x4, column-major: 16 floats) and `camera.intrinsics` values (pixels of the
    /// `w` x `h` captured image).
    public init(columnMajor m: [Float], fx: Double, fy: Double, cx: Double, cy: Double, w: Int, h: Int) {
        precondition(m.count == 16)
        // Rotation matrix r[row][col] = m[col * 4 + row].
        func r(_ row: Int, _ col: Int) -> Double { Double(m[col * 4 + row]) }
        let trace = r(0, 0) + r(1, 1) + r(2, 2)
        var qw: Double, qx: Double, qy: Double, qz: Double
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            qw = 0.25 * s; qx = (r(2, 1) - r(1, 2)) / s; qy = (r(0, 2) - r(2, 0)) / s; qz = (r(1, 0) - r(0, 1)) / s
        } else if r(0, 0) > r(1, 1) && r(0, 0) > r(2, 2) {
            let s = (1 + r(0, 0) - r(1, 1) - r(2, 2)).squareRoot() * 2
            qw = (r(2, 1) - r(1, 2)) / s; qx = 0.25 * s; qy = (r(0, 1) + r(1, 0)) / s; qz = (r(0, 2) + r(2, 0)) / s
        } else if r(1, 1) > r(2, 2) {
            let s = (1 + r(1, 1) - r(0, 0) - r(2, 2)).squareRoot() * 2
            qw = (r(0, 2) - r(2, 0)) / s; qx = (r(0, 1) + r(1, 0)) / s; qy = 0.25 * s; qz = (r(1, 2) + r(2, 1)) / s
        } else {
            let s = (1 + r(2, 2) - r(0, 0) - r(1, 1)).squareRoot() * 2
            qw = (r(1, 0) - r(0, 1)) / s; qx = (r(0, 2) + r(2, 0)) / s; qy = (r(1, 2) + r(2, 1)) / s; qz = 0.25 * s
        }
        self.init(qw: qw, qx: qx, qy: qy, qz: qz, tx: Double(m[12]), ty: Double(m[13]), tz: Double(m[14]),
                  fx: fx, fy: fy, cx: cx, cy: cy, w: w, h: h)
    }

    /// Row-major 3x3 rotation world_from_camera.
    public func rotation() -> [Double] {
        var n = (qw * qw + qx * qx + qy * qy + qz * qz).squareRoot()
        if !(n > 0) { n = 1 }
        let w = qw / n, x = qx / n, y = qy / n, z = qz / n
        return [
            1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
            2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
            2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y),
        ]
    }

    /// Distance of world point `p` along the optical axis (OpenCV z); negative or tiny when behind the camera.
    public func depthOf(_ p: Vec3) -> Double {
        let r = rotation()
        let dx = Double(p.x) - tx, dy = Double(p.y) - ty, dz = Double(p.z) - tz
        return -(r[2] * dx + r[5] * dy + r[8] * dz)
    }

    /// Image pixel (u, v) of world point `p`, or nil when it is behind or too close to the camera (< `minDepthM`).
    public func project(_ p: Vec3) -> (u: Float, v: Float)? {
        let r = rotation()
        let dx = Double(p.x) - tx, dy = Double(p.y) - ty, dz = Double(p.z) - tz
        // camera (ARKit axes) = R^T d; OpenCV = (x, -y, -z)
        let gx = r[0] * dx + r[3] * dy + r[6] * dz
        let gy = r[1] * dx + r[4] * dy + r[7] * dz
        let gz = r[2] * dx + r[5] * dy + r[8] * dz
        let z = -gz
        if z < CameraSnapshot.minDepthM { return nil }
        return (Float(fx * gx / z + cx), Float(fy * -gy / z + cy))
    }

    /// World ray through image pixel (`u`, `v`) as (origin, unit direction): what an `ARRaycastQuery(origin:direction:...)` takes.
    /// Built from THIS snapshot, so a result applied later still casts the ray of the camera that took the image.
    public func ray(_ u: Float, _ v: Float) -> (origin: Vec3, direction: Vec3) {
        let ox = (Double(u) - cx) / fx, oy = (Double(v) - cy) / fy   // OpenCV: x right, y down, z forward = 1
        let gx = ox, gy = -oy, gz = -1.0                             // ARKit camera axes
        let r = rotation()
        var dx = r[0] * gx + r[1] * gy + r[2] * gz
        var dy = r[3] * gx + r[4] * gy + r[5] * gz
        var dz = r[6] * gx + r[7] * gy + r[8] * gz
        let n = (dx * dx + dy * dy + dz * dz).squareRoot()
        dx /= n; dy /= n; dz /= n
        return (Vec3(Float(tx), Float(ty), Float(tz)), Vec3(Float(dx), Float(dy), Float(dz)))
    }

    public func inImage(_ u: Float, _ v: Float, marginFrac: Float = 0.02) -> Bool {
        let mx = Float(w) * marginFrac, my = Float(h) * marginFrac
        return u >= mx && u < Float(w) - mx && v >= my && v < Float(h) - my
    }
}
