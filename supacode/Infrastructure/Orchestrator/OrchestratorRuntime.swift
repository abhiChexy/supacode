import Foundation
import Network
import SupacodeSettingsShared

/// Owns the Python sidecar process, the Supacode-side bridge server, and the
/// WebSocket back-channel for streamed events. Single shared instance keyed
/// off the app process.
nonisolated final class OrchestratorRuntime: @unchecked Sendable {
  static let shared = OrchestratorRuntime()

  private let logger = SupaLogger("OrchestratorRuntime")
  private let lock = NSLock()

  // All mutable state below is guarded by `lock`.
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

  /// One-time bootstrap. Idempotent. `sharedToken` is the bearer secret used
  /// by both the bridge (inbound auth) and the sidecar (outbound auth on
  /// callbacks). Pass the SAME token to the bridge constructor.
  @MainActor
  func bootstrap(bridgeServer: OrchestratorBridgeServer, sharedToken: String) throws {
    let alreadyBootstrapped: Bool = {
      lock.lock(); defer { lock.unlock() }
      if bootstrapped { return true }
      bootstrapped = true
      self.bridgeServer = bridgeServer
      self.sharedToken = sharedToken
      let (stream, continuation) = AsyncStream<OrchestratorEvent>.makeStream(
        bufferingPolicy: .bufferingNewest(256)
      )
      eventStream = stream
      eventContinuation = continuation
      return false
    }()
    guard !alreadyBootstrapped else { return }

    let bridgePort = try bridgeServer.start()
    lock.lock()
    self.bridgePort = bridgePort
    let token = sharedToken
    lock.unlock()
    do {
      try spawnSidecar(bridgePort: bridgePort, sharedToken: token)
    } catch {
      logger.warning("Failed to spawn orchestrator sidecar: \(error). Orchestrator will be inert this session.")
    }
  }

  func shutdown() {
    let (process, server): (Process?, OrchestratorBridgeServer?) = {
      lock.lock(); defer { lock.unlock() }
      let result = (sidecarProcess, bridgeServer)
      streamTask?.cancel()
      streamTask = nil
      eventContinuation?.finish()
      eventContinuation = nil
      sidecarProcess = nil
      sidecarPort = nil
      bridgeServer = nil
      return result
    }()
    process?.terminate()
    Task { @MainActor in server?.stop() }
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
    // Apps launched via LaunchServices inherit a minimal PATH that does not
    // include /opt/homebrew/bin where `uv` lives. Augment so `env uv ...` works.
    var env = ProcessInfo.processInfo.environment
    let existingPath = env["PATH"] ?? ""
    let extras = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"]
    let merged = (extras + existingPath.split(separator: ":").map(String.init))
      .reduce(into: [String]()) { acc, p in if !acc.contains(p) { acc.append(p) } }
      .joined(separator: ":")
    env["PATH"] = merged
    process.environment = env

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // Tee stderr to a fixed debug file so we can inspect spawn failures when
    // launched via LaunchServices (where the app's own stdout is invisible).
    let stderrLog = FileHandle(forWritingAtPath: "/tmp/supacode-orchestrator-sidecar.stderr.log")
      ?? {
        FileManager.default.createFile(atPath: "/tmp/supacode-orchestrator-sidecar.stderr.log", contents: nil)
        return FileHandle(forWritingAtPath: "/tmp/supacode-orchestrator-sidecar.stderr.log")!
      }()
    stderrLog.write(Data("\n--- spawn at \(Date()) ---\n".utf8))
    stderrLog.write(Data("env PATH=\(env["PATH"] ?? "<unset>")\n".utf8))
    stderrLog.write(Data("cwd=\(sidecarDir.path)\n".utf8))
    stderrLog.write(Data("args=\(process.arguments ?? [])\n".utf8))

    do {
      try process.run()
    } catch {
      stderrLog.write(Data("RUN FAILED: \(error)\n".utf8))
      throw error
    }

    lock.lock()
    sidecarProcess = process
    lock.unlock()

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
        stderrLog.write(chunk)
      }
    }
  }

  private func handleSidecarStdoutLine(_ line: String) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("SIDECAR_PORT="),
      let portString = trimmed.split(separator: "=").last,
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
    if let resource = Bundle.main.url(forResource: "orchestrator-sidecar", withExtension: nil) {
      return resource
    }
    // Dev fallback: the source tree alongside the .app. We walk up from the
    // build product to find the repo root.
    let bundlePath = Bundle.main.bundleURL
    var probe = bundlePath
    for _ in 0..<10 {
      probe.deleteLastPathComponent()
      let candidate = probe.appending(path: "bins/orchestrator-sidecar", directoryHint: .isDirectory)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }
    // Last resort: hardcoded dev path.
    return URL(filePath: "\(NSHomeDirectory())/supacode-orchestrator/bins/orchestrator-sidecar")
  }

  // MARK: - WebSocket event stream

  private func startEventStream(port: UInt16) async {
    let url = URL(string: "ws://127.0.0.1:\(port)/stream")!
    var req = URLRequest(url: url)
    let token: String = lock.withLock { sharedToken }
    if !token.isEmpty {
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    let session = URLSession(configuration: .ephemeral)
    let task = session.webSocketTask(with: req)
    task.resume()

    let streamTask = Task { [weak self] in
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
    lock.withLock { self.streamTask = streamTask }
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
    lock.lock()
    eventContinuation?.yield(event)
    lock.unlock()
  }

  // MARK: - HTTP helpers

  private func postJSON(path: String, body: [String: Any]) async throws -> [String: Any]? {
    let data = try JSONSerialization.data(withJSONObject: body)
    return try await request(method: "POST", path: path, body: data)
  }

  private func request(method: String, path: String, body: Data?) async throws -> [String: Any]? {
    let snapshot: (UInt16?, String) = lock.withLock { (sidecarPort, sharedToken) }
    guard let port = snapshot.0 else {
      throw OrchestratorRuntimeError.notReady
    }
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    req.httpMethod = method
    if let body {
      req.httpBody = body
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if !snapshot.1.isEmpty {
      req.setValue("Bearer \(snapshot.1)", forHTTPHeaderField: "Authorization")
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
