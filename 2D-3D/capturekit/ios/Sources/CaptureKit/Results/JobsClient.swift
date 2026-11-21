import Foundation

/// One HTTP exchange. Injectable so tests never touch the network.
public protocol HTTPTransport {
    /// Returns the body and the HTTP status code; throws when the server cannot be reached.
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// What one poll round tells the screen.
public struct JobUpdate {
    public let job: JobStatus?
    /// Set when there is no usable job and nothing good was shown before.
    public let error: String?
    /// Floor plan SVG fetched in this round (only when its URL changed); `svg` is nil when the fetch failed.
    public let plan: (url: String, svg: String?)?
}

/// Reads job status from the roomscan-recon job server (GET /jobs/<bundle_id>; POST /jobs when the server answers 404).
/// Port of the field ResultsGate status/fetchText plus ResultsActivity's poll loop.
public final class JobsClient {
    public let gate: ResultsGate
    private let transport: HTTPTransport

    public init(gate: ResultsGate, transport: HTTPTransport = URLSessionTransport()) {
        self.gate = gate
        self.transport = transport
    }

    private enum Reply { case ok(String), notFound, failed }

    private func request(_ url: String, method: String = "GET", body: Data? = nil) -> URLRequest? {
        guard let u = URL(string: url) else { return nil }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.timeoutInterval = 20
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    private func call(_ url: String, method: String = "GET", body: Data? = nil) async -> Reply {
        guard let r = request(url, method: method, body: body) else { return .failed }
        do {
            let (data, code) = try await transport.send(r)
            if code == 404 { return .notFound }
            guard (200..<300).contains(code) else { return .failed }
            return .ok(String(decoding: data, as: UTF8.self))
        } catch { return .failed }
    }

    /// GET /jobs/<id>; on 404 asks the server to start the job (POST /jobs, idempotent) and reads it again.
    public func status(_ bundleId: String) async -> Fetched {
        guard let jobUrl = gate.jobUrl(bundleId), let collection = gate.jobsCollectionUrl else { return Fetched(nil, ResultsGate.notSetUp) }
        switch await call(jobUrl) {
        case .ok(let t): return Fetched(t, nil)
        case .failed: return Fetched(nil, ResultsGate.unreachable)
        case .notFound:
            switch await call(collection, method: "POST", body: ResultsGate.startBody(bundleId)) {
            case .ok: break
            case .notFound: return Fetched(nil, ResultsGate.unknownScan)
            case .failed: return Fetched(nil, ResultsGate.unreachable)
            }
            switch await call(jobUrl) {
            case .ok(let t): return Fetched(t, nil)
            case .notFound: return Fetched(nil, ResultsGate.unknownScan)
            case .failed: return Fetched(nil, ResultsGate.unreachable)
            }
        }
    }

    /// Text file (for example the floor plan SVG) from a server-relative or absolute URL on this server.
    public func fetchText(_ rel: String) async -> Fetched {
        guard let abs = gate.absoluteUrl(rel) else { return Fetched(nil, ResultsGate.notOnServer) }
        if case .ok(let t) = await call(abs) { return Fetched(t, nil) }
        return Fetched(nil, "Could not load the file.")
    }

    /// Polls every `intervalSeconds` while the job is queued or running; returns on a terminal state, when there was never a good answer, or
    /// when the surrounding Task is cancelled (SwiftUI `.task` cancels on disappear, so no timer outlives the screen).
    /// A failed fetch after a good "still running" answer does not stop the polling.
    public func poll(bundleId: String, intervalSeconds: Double = 5,
                     sleep: @escaping (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                     onUpdate: @escaping (JobUpdate) -> Void) async {
        var lastGoodActive = false
        var haveGood = false
        var planLoadedFor: String?
        while !Task.isCancelled {
            let f = await status(bundleId)
            let job = f.text.flatMap { JobStatus.parse($0) }
            var plan: (url: String, svg: String?)?
            if let file = job?.file(kind: "floorplan_svg"), file.url != planLoadedFor {
                let svg = await fetchText(file.url).text
                plan = (file.url, svg)
                if svg != nil { planLoadedFor = file.url }
            }
            if Task.isCancelled { return }
            let error = (job == nil && !haveGood) ? (f.error ?? "The server sent an answer this app does not understand.") : nil
            onUpdate(JobUpdate(job: job, error: error, plan: plan))
            if let job { haveGood = true; lastGoodActive = job.isActive }
            if !lastGoodActive { return }
            do { try await sleep(intervalSeconds) } catch { return }
        }
    }
}
