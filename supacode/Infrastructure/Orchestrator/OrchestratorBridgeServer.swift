import Foundation
import Network

/// Tiny HTTP/1.1 server bound to 127.0.0.1 that lets the Python sidecar call
/// back into Supacode. Built on `Network.framework` to avoid pulling in a
/// third-party Swift HTTP server (per spec §9).
///
/// Not a general-purpose web server — handles only the small set of JSON
/// POST endpoints used by orchestrator tools. Request bodies are bounded by
/// `maxBodyBytes`. One handler is invoked per request.
@MainActor
final class OrchestratorBridgeServer {
  /// JSON dictionary of request body fields. Always a top-level object.
  typealias Body = [String: Any]
  /// Handler returns a JSON-serializable dictionary or `nil` for 204.
  typealias Handler = @MainActor (Body) async throws -> Body?

  private let logger = SupaLogger("OrchestratorBridge")
  private let queue = DispatchQueue(label: "app.supabit.supacode.orchestrator-bridge")
  private let sharedToken: String
  private var listener: NWListener?
  private var routes: [String: Handler] = [:]
  private let maxBodyBytes = 1 << 20  // 1 MiB

  private(set) var boundPort: UInt16?

  init(sharedToken: String) {
    self.sharedToken = sharedToken
  }

  func register(path: String, handler: @escaping Handler) {
    routes[path] = handler
  }

  /// Starts the listener on an OS-chosen port. Returns the bound port.
  func start() throws -> UInt16 {
    let params = NWParameters.tcp
    params.acceptLocalOnly = true
    let listener = try NWListener(using: params, on: .any)
    self.listener = listener
    listener.newConnectionHandler = { [weak self] connection in
      self?.queue.async { self?.handle(connection: connection) }
    }
    listener.start(queue: queue)
    // Wait briefly for the port to be assigned.
    let deadline = Date().addingTimeInterval(2)
    while listener.port == nil, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    guard let port = listener.port?.rawValue else {
      throw OrchestratorBridgeError.listenerFailed
    }
    boundPort = port
    logger.info("OrchestratorBridge listening on 127.0.0.1:\(port)")
    return port
  }

  func stop() {
    listener?.cancel()
    listener = nil
    boundPort = nil
  }

  // MARK: - Connection handling

  private nonisolated func handle(connection: NWConnection) {
    connection.start(queue: queue)
    receiveAll(on: connection, accumulated: Data())
  }

  private nonisolated func receiveAll(on connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, _ in
      guard let self else { return }
      var buffer = accumulated
      if let data { buffer.append(data) }
      if buffer.count > self.maxBodyBytes {
        self.respond(connection: connection, status: 413, body: "payload too large")
        return
      }
      if let request = HTTPRequest.parse(buffer) {
        Task { @MainActor [weak self] in
          await self?.dispatch(request: request, connection: connection)
        }
        return
      }
      if isComplete {
        self.respond(connection: connection, status: 400, body: "bad request")
        return
      }
      self.receiveAll(on: connection, accumulated: buffer)
    }
  }

  @MainActor
  private func dispatch(request: HTTPRequest, connection: NWConnection) async {
    if !sharedToken.isEmpty {
      let expected = "Bearer \(sharedToken)"
      if request.headers["authorization"] != expected {
        respond(connection: connection, status: 401, body: "unauthorized")
        return
      }
    }
    guard request.method == "POST", let handler = routes[request.path] else {
      respond(connection: connection, status: 404, body: "no route")
      return
    }
    let body: Body
    if request.body.isEmpty {
      body = [:]
    } else {
      do {
        let parsed = try JSONSerialization.jsonObject(with: request.body)
        guard let dict = parsed as? Body else { throw OrchestratorBridgeError.malformedBody }
        body = dict
      } catch {
        respond(connection: connection, status: 400, body: "bad json")
        return
      }
    }
    do {
      let response = try await handler(body)
      if let response {
        let data = try JSONSerialization.data(withJSONObject: response)
        respond(connection: connection, status: 200, contentType: "application/json", bodyData: data)
      } else {
        respond(connection: connection, status: 204, body: "")
      }
    } catch {
      logger.error("Handler for \(request.path) threw: \(error)")
      respond(connection: connection, status: 500, body: "\(error)")
    }
  }

  private nonisolated func respond(
    connection: NWConnection,
    status: Int,
    contentType: String = "text/plain; charset=utf-8",
    body: String = "",
    bodyData: Data? = nil
  ) {
    let payload = bodyData ?? Data(body.utf8)
    var head = "HTTP/1.1 \(status) \(reasonPhrase(for: status))\r\n"
    head += "Content-Type: \(contentType)\r\n"
    head += "Content-Length: \(payload.count)\r\n"
    head += "Connection: close\r\n\r\n"
    var data = Data(head.utf8)
    data.append(payload)
    connection.send(content: data, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  private nonisolated func reasonPhrase(for status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 202: return "Accepted"
    case 204: return "No Content"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 404: return "Not Found"
    case 413: return "Payload Too Large"
    case 500: return "Internal Server Error"
    default: return "Status"
    }
  }
}

enum OrchestratorBridgeError: Error {
  case listenerFailed
  case malformedBody
}

/// Minimal HTTP/1.1 request parser. Returns nil if the request is not yet
/// fully buffered.
struct HTTPRequest {
  let method: String
  let path: String
  let headers: [String: String]
  let body: Data

  static func parse(_ buffer: Data) -> HTTPRequest? {
    guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
    guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
    let lines = headerString.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2 else { return nil }
    let method = String(parts[0])
    let path = String(parts[1])
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      if let colon = line.firstIndex(of: ":") {
        let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        headers[name] = value
      }
    }
    let bodyStart = headerEnd.upperBound
    let expected = headers["content-length"].flatMap { Int($0) } ?? 0
    let available = buffer.count - bodyStart
    if available < expected { return nil }
    let bodyData = buffer.subdata(in: bodyStart..<(bodyStart + expected))
    return HTTPRequest(method: method, path: path, headers: headers, body: bodyData)
  }
}
