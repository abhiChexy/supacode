import Foundation
import Network

/// Owns the Python sidecar process, the Supacode-side bridge server, and the
/// WebSocket back-channel for streamed events. Single shared instance keyed
/// off the app process.
///
/// Marked `@unchecked Sendable` because we serialize access to mutable state
/// via the internal lock.
final class OrchestratorRuntime: @unchecked Sendable {
  static let shared = OrchestratorRuntime()

  private let logger = SupaLogger("OrchestratorRuntime")
  private let lock = NSLock()

  private var sidecarProcess: Process?
  private var sidecarPort: UInt16?
  private var sharedToken: String = ""
  private var bridgeServer: OrchestratorBridgeServer?
  private var bridgePort: UInt16?
  private var eventContinuation: AsyncStream<OrchestratorEvent>.Continuation?
  private var eventStream: AsyncStream<OrchestratorEvent>?
  private var streamTask: Task<Void, Never>?
  private var bootstrapped = false

  var isReady: Bool {
    lock.lock(); defer { lock.unlock() }
    return sidecarPort != nil
  }

  /// One-time bootstrap. Wires the bridge server, spawns the sidecar, starts
  /// the event-stream reader. Idempotent.
  @MainActor
  func bootstrap(bridgeServer: OrchestratorBridgeServer) throws {
    lock.lock()
    if bootstrapped {
      lock.unlock()
      return
    }
    self.bridgeServer = bridgeServer
    sharedToken = UUID().uuidString
    let (stream, continuation) = AsyncStream<OrchestratorEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(256)
    )
    eventStream = stream
    eventContinuation = continuation
    bootstrapped = true
    lock.unlock()

    let bridgePort = try bridgeServer.start()
    self.bridgePort = bridgePort
    do {
      try spawnSidecar(bridgePort: bridgePort, sharedToken: sharedToken)
    } catch {
      logger.error("Failed to spawn orchestrator sidecar: \(error). Orchestrator will be inert this session.")
    }
  }

  func shutdown() {
    lock.lock()
    let process = sidecarProcess
    streamTask?.cancel()
    streamTask = nil
    eventContinuation?.finish()
    eventContinuation = nil
    sidecarProcess = nil
    sidecarPort = nil
    lock.unlock()
    process?.terminate()
    bridgeServer?.stop()
  }

  func events() -> AsyncStream<OrchestratorEvent> {
    lock.lock(); defer { lock.unlock() }
    return eventStream ?? AsyncStream { $0.finish() }
  }

  // MARK: - HTTP calls into the sidecar

  func startSession(conversationID: UUID, resumeSessionID: String?) async throws -> String? {
    var body: [String: Any] = ["conversation_id": conversationID.uuidString]
    if let resumeSessionID { body["resume_session_id"] = resumeSessionID }
    let response = try await postJSON(path: "/sessions", body: body)
    return response?["session_id"] as? String
  }

  func sendUserMessage(conversationID: UUID, content: String) async throws {
    _ = try await postJSON(
      path: "/sessions/\(conversationID.uuidString)/messages",
      body: ["content": content]
    )
  }

  func killSession(conversationID: UUID) async throws {
    _ = try await request(
      method: "DELETE",
      path: "/sessions/\(conversationID.uuidString)",
      body: nil
    )
  }

  // MARK: - Sidecar lifecycle

  private func spawnSidecar(bridgePort: UInt16, sharedToken: String) throws {
    let sidecarDir = locateSidecarDir()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "uv", "run", "python", "-m", "orchestrator",
      "--supacode-port", "\(bridgePort)",
      "--sidecar-port", "0",
      "--shared-token", sharedToken,
    ]
    process.currentDirectoryURL = sidecarDir

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()

    lock.lock()
    sidecarProcess = process
    lock.unlock()

    // Read stdout line-by-line for the SIDECAR_PORT=NNN line, then keep draining.
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let handle = stdoutPipe.fileHandleForReading
      var buffer = Data()
      while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
          let line = String(data: buffer.subdata(in: buffer.startIndex..<nl), encoding: .utf8) ?? ""
          buffer.removeSubrange(buffer.startIndex...nl)
          self?.handleSidecarStdoutLine(line)
        }
      }
    }
    DispatchQueue.global(qos: .utility).async {
      let handle = stderrPipe.fileHandleForReading
      while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
        let text = String(data: chunk, encoding: .utf8) ?? ""
        SupaLogger("OrchestratorRuntime").debug("[sidecar stderr] \(text)")
      }
    }
  }

  private func handleSidecarStdoutLine(_ line: String) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if let portString = trimmed.split(separator: "=").last,
      trimmed.hasPrefix("SIDECAR_PORT="),
      let port = UInt16(portString)
    {
      lock.lock()
      sidecarPort = port
      lock.unlock()
      logger.info("Sidecar bound to 127.0.0.1:\(port)")
      Task { await self.startEventStream(port: port) }
    } else if !trimmed.isEmpty {
      logger.debug("[sidecar] \(trimmed)")
    }
  }

  private func locateSidecarDir() -> URL {
    // Bundled location first; falls back to in-repo dev path.
    if let resource = Bundle.main.url(forResource: "orchestrator-sidecar", withExtension: nil) {
      return resource
    }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return cwd.appending(path: "bins/orchestrator-sidecar", directoryHint: .isDirectory)
  }

  // MARK: - WebSocket event stream

  private func startEventStream(port: UInt16) async {
    let url = URL(string: "ws://127.0.0.1:\(port)/stream")!
    let request: URLRequest = {
      var req = URLRequest(url: url)
      if !sharedToken.isEmpty {
        req.setValue("Bearer \(sharedToken)", forHTTPHeaderField: "Authorization")
      }
      return req
    }()
    let session = URLSession(configuration: .ephemeral)
    let task = session.webSocketTask(with: request)
    task.resume()

    streamTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          let message = try await task.receive()
          switch message {
          case .string(let text):
            self?.dispatchWSPayload(text)
          case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
              self?.dispatchWSPayload(text)
            }
          @unknown default:
            break
          }
        } catch {
          self?.logger.warning("WebSocket receive failed: \(error). Stream ending.")
          break
        }
      }
      task.cancel(with: .goingAway, reason: nil)
    }
  }

  private func dispatchWSPayload(_ text: String) {
    guard let data = text.data(using: .utf8),
      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return }
    let cid = (dict["conversation_id"] as? String).flatMap(UUID.init(uuidString:))
    let type = dict["type"] as? String ?? ""
    let event: OrchestratorEvent
    switch type {
    case "assistant_delta":
      guard let cid else { return }
      event = .assistantDelta(conversationID: cid, text: dict["text"] as? String ?? "")
    case "tool_use":
      guard let cid else { return }
      let inputJSON = (try? JSONSerialization.data(withJSONObject: dict["input"] ?? [:]))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
      event = .toolUse(
        conversationID: cid,
        tool: dict["tool"] as? String ?? "",
        id: dict["id"] as? String ?? "",
        inputJSON: inputJSON
      )
    case "tool_result":
      guard let cid else { return }
      event = .toolResult(
        conversationID: cid,
        toolUseID: dict["tool_use_id"] as? String ?? "",
        resultJSON: dict["result"] as? String ?? ""
      )
    case "turn_complete":
      guard let cid else { return }
      event = .turnComplete(conversationID: cid, sessionID: dict["session_id"] as? String)
    case "error":
      event = .error(conversationID: cid, message: dict["message"] as? String ?? "unknown")
    default:
      return
    }
    eventContinuation?.yield(event)
  }

  // MARK: - HTTP helpers

  private func postJSON(path: String, body: [String: Any]) async throws -> [String: Any]? {
    let data = try JSONSerialization.data(withJSONObject: body)
    return try await request(method: "POST", path: path, body: data)
  }

  private func request(method: String, path: String, body: Data?) async throws -> [String: Any]? {
    guard let port = sidecarPort else {
      throw OrchestratorRuntimeError.notReady
    }
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    req.httpMethod = method
    if let body {
      req.httpBody = body
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if !sharedToken.isEmpty {
      req.setValue("Bearer \(sharedToken)", forHTTPHeaderField: "Authorization")
    }
    let (responseData, response) = try await URLSession.shared.data(for: req)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw OrchestratorRuntimeError.httpStatus(http.statusCode)
    }
    guard !responseData.isEmpty else { return nil }
    return (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
  }
}

enum OrchestratorRuntimeError: Error {
  case notReady
  case httpStatus(Int)
}
