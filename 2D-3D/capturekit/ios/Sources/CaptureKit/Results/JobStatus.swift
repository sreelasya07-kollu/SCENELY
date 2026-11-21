import Foundation

/// `GET /jobs/<bundle_id>` of the roomscan-recon job service (contract `roomscan.job/1`, owner: backend-app-connection, read-only here).
/// Readers ignore unknown keys; `url` values are relative to the job server base; `verdict` comes only from the server (never computed here).
public struct JobStatus: Equatable {
    public struct Issue: Equatable { public let code: String, severity: String, message: String }
    public struct Validation: Equatable { public let verdict: String, issues: [Issue] }
    public struct Stage: Equatable { public let name: String, status: String, reason: String?, where_: String }
    public struct Rescan: Equatable { public let surface: String, reason: String, priority: Double, areaM2: Double, instruction: String }
    public struct Measurements: Equatable {
        public var floorAreaM2: Double?
        public var perimeterM: Double?
        public var wallLengthsM: [Double] = []
        public var ceilingHeightM: Double?
        public var volumeM3: Double?
        public var bboxM: [Double] = []
        public var floorPolygonSource: String?
        public var scaleConfidence: Double?
        public var scaleSource: String?
        public var warnings: [String] = []
    }
    public struct File: Equatable { public let name: String, kind: String, url: String, size: Int64, sha256: String }

    public let schema: String
    public let bundleId: String
    /// queued | running | done | failed | rejected (unknown values are kept as is).
    public let state: String
    public let created: String
    public let updated: String
    public let error: String?
    public let validation: Validation?
    public let stages: [Stage]
    /// pass | pass_with_warnings | needs_rescan | nil
    public let verdict: String?
    public let rescan: [Rescan]
    public let measurements: Measurements?
    public let files: [File]

    /// Polling stops in these states.
    public var isTerminal: Bool { state == "done" || state == "failed" || state == "rejected" }
    /// Keep polling every 5 s while queued or running.
    public var isActive: Bool { state == "queued" || state == "running" }

    public static let schemaId = "roomscan.job/1"

    /// First file of a kind (floorplan_svg, floorplan_dxf, mesh_glb, point_cloud_laz, room_shell_usda, splat_ply, job_report, measurements, spatial_map_zip).
    public func file(kind: String) -> File? { files.first { $0.kind == kind } }

    /// Parses the service's JSON. Nil when it is not a JSON object of schema `roomscan.job/1` with the required `bundle_id` and `state`.
    public static func parse(_ data: Data) -> JobStatus? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (root["schema"] as? String) == schemaId,
              let bundleId = root["bundle_id"] as? String, let state = root["state"] as? String else { return nil }

        func str(_ d: [String: Any], _ k: String) -> String? { d[k] as? String }
        func num(_ d: [String: Any], _ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        func nums(_ d: [String: Any], _ k: String) -> [Double] { ((d[k] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.doubleValue } }

        var validation: Validation?
        if let v = root["validation"] as? [String: Any] {
            let issues: [Issue] = ((v["issues"] as? [Any]) ?? []).compactMap { o in
                guard let m = o as? [String: Any] else { return nil }
                return Issue(code: str(m, "code") ?? "", severity: str(m, "severity") ?? "", message: str(m, "message") ?? "")
            }
            validation = Validation(verdict: str(v, "verdict") ?? "", issues: issues)
        }
        let stages: [Stage] = ((root["stages"] as? [Any]) ?? []).compactMap { o in
            guard let m = o as? [String: Any], let n = str(m, "name") else { return nil }
            return Stage(name: n, status: str(m, "status") ?? "pending", reason: str(m, "reason"), where_: str(m, "where") ?? "local")
        }
        let rescan: [Rescan] = ((root["rescan"] as? [Any]) ?? []).compactMap { o in
            guard let m = o as? [String: Any] else { return nil }
            return Rescan(surface: str(m, "surface") ?? "", reason: str(m, "reason") ?? "", priority: num(m, "priority") ?? 0,
                          areaM2: num(m, "area_m2") ?? 0, instruction: str(m, "instruction") ?? "")
        }
        var measurements: Measurements?
        if let m = root["measurements"] as? [String: Any] {
            var r = Measurements()
            r.floorAreaM2 = num(m, "floor_area_m2"); r.perimeterM = num(m, "perimeter_m"); r.wallLengthsM = nums(m, "wall_lengths_m")
            r.ceilingHeightM = num(m, "ceiling_height_m"); r.volumeM3 = num(m, "volume_m3"); r.bboxM = nums(m, "bbox_m")
            r.floorPolygonSource = str(m, "floor_polygon_source"); r.scaleConfidence = num(m, "scale_confidence")
            r.scaleSource = str(m, "scale_source")
            r.warnings = ((m["warnings"] as? [Any]) ?? []).compactMap { $0 as? String }
            measurements = r
        }
        let files: [File] = ((root["files"] as? [Any]) ?? []).compactMap { o in
            guard let m = o as? [String: Any], let name = str(m, "name"), let url = str(m, "url") else { return nil }
            return File(name: name, kind: str(m, "kind") ?? "", url: url, size: Int64(num(m, "size") ?? 0), sha256: str(m, "sha256") ?? "")
        }
        return JobStatus(schema: schemaId, bundleId: bundleId, state: state, created: str(root, "created") ?? "",
                         updated: str(root, "updated") ?? "", error: str(root, "error"), validation: validation, stages: stages,
                         verdict: str(root, "verdict"), rescan: rescan, measurements: measurements, files: files)
    }

    public static func parse(_ json: String) -> JobStatus? { json.data(using: .utf8).flatMap { parse($0) } }
}
