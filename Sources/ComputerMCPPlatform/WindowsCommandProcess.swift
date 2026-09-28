#if os(Windows)
  import Dispatch
  import Foundation
  import Synchronization
  import WinSDK

  /// Owns the root process and the parent ends of its two output pipes.
  final class WindowsCommandProcess: Sendable {
    struct Capture: Sendable {
      var data = Data()
      var truncated = false
    }

    // HANDLE is an opaque kernel token. Only this owner's mutex guards access
    // and closing; synchronous Job admission borrows the tokens without retaining them.
    private struct Handles: @unchecked Sendable {
      let process: HANDLE
      let thread: HANDLE
    }

    private let handles: Mutex<Handles>
    let stdout: WindowsCommandPipe
    let stderr: WindowsCommandPipe

    init(
      path: String, arguments: [String], cwd: String, environment: [String: String],
      job: WindowsProcessJob
    ) throws {
      var command = Array(([path] + arguments).map(Self.quote).joined(separator: " ").utf16) + [0]
      guard command.count <= 32_767 else {
        throw CommandRunnerError.launchFailed("Command line exceeds the Windows launch limit.")
      }
      let output = try Self.pipe()
      defer { CloseHandle(output.write) }
      let stdout = WindowsCommandPipe(output.read)
      let error = try Self.pipe()
      defer { CloseHandle(error.write) }
      let stderr = WindowsCommandPipe(error.read)
      let input = try Self.pipe()
      // Closing the only writer supplies EOF without inheriting the host's stdin.
      CloseHandle(input.write)
      defer { CloseHandle(input.read) }
      guard SetHandleInformation(input.read, DWORD(HANDLE_FLAG_INHERIT), DWORD(HANDLE_FLAG_INHERIT))
      else { throw Self.error("SetHandleInformation") }

      var environmentBlock =
        Array(
          environment.sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\0").utf16) + [0, 0]
      var info = STARTUPINFOEXW()
      info.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
      info.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES) | DWORD(STARTF_USESHOWWINDOW)
      info.StartupInfo.wShowWindow = WORD(SW_HIDE)
      info.StartupInfo.hStdInput = input.read
      info.StartupInfo.hStdOutput = output.write
      info.StartupInfo.hStdError = error.write

      var attributeBytes: SIZE_T = 0
      _ = InitializeProcThreadAttributeList(nil, 1, 0, &attributeBytes)
      guard attributeBytes > 0 else { throw Self.error("InitializeProcThreadAttributeList") }
      let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(attributeBytes), alignment: 16)
      defer { storage.deallocate() }
      let attributes = LPPROC_THREAD_ATTRIBUTE_LIST(storage)
      guard InitializeProcThreadAttributeList(attributes, 1, 0, &attributeBytes) else {
        throw Self.error("InitializeProcThreadAttributeList")
      }
      var inherited = [input.read, output.write, error.write]
      var created = PROCESS_INFORMATION()
      try inherited.withUnsafeMutableBufferPointer { list in
        defer { DeleteProcThreadAttributeList(attributes) }
        // PROC_THREAD_ATTRIBUTE_HANDLE_LIST: attribute 2, input flag. The SDK macro
        // uses a C expression that is not imported by Swift.
        guard
          UpdateProcThreadAttribute(
            attributes, 0, 0x0002_0002, list.baseAddress,
            SIZE_T(list.count * MemoryLayout<HANDLE>.stride), nil, nil)
        else { throw Self.error("UpdateProcThreadAttribute") }
        info.lpAttributeList = attributes
        let launched = path.withCString(encodedAs: UTF16.self) { executable in
          cwd.withCString(encodedAs: UTF16.self) { directory in
            environmentBlock.withUnsafeMutableBufferPointer { environment in
              withUnsafeMutablePointer(to: &info) { extended in
                extended.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { startup in
                  CreateProcessW(
                    executable, &command, nil, nil, true,
                    DWORD(
                      CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT),
                    environment.baseAddress, directory, startup, &created)
                }
              }
            }
          }
        }
        guard launched else { throw Self.error("CreateProcessW") }
      }
      handles = Mutex(Handles(process: created.hProcess!, thread: created.hThread!))
      self.stdout = stdout
      self.stderr = stderr
      job.start(process: created.hProcess!, thread: created.hThread!)
    }

    deinit {
      handles.withLock {
        CloseHandle($0.thread)
        CloseHandle($0.process)
      }
    }

    func wait(job: WindowsProcessJob) async -> Result<Int32, CommandRunnerError> {
      while true {
        let status = handles.withLock { WaitForSingleObject($0.process, 0) }
        switch status {
        case DWORD(WAIT_OBJECT_0):
          job.stop(.exited)
          return handles.withLock {
            var code: DWORD = 0
            guard GetExitCodeProcess($0.process, &code) else {
              return .failure(Self.error("GetExitCodeProcess"))
            }
            return .success(Int32(bitPattern: code))
          }
        case DWORD(WAIT_TIMEOUT):
          try? await Task.sleep(for: .milliseconds(10))
        default:
          let error = Self.error("WaitForSingleObject")
          job.stop(.failed)
          return .failure(error)
        }
      }
    }

    private static func pipe() throws -> (read: HANDLE, write: HANDLE) {
      var security = SECURITY_ATTRIBUTES()
      security.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
      security.bInheritHandle = true
      var read: HANDLE?
      var write: HANDLE?
      guard CreatePipe(&read, &write, &security, 0), let read, let write else {
        throw error("CreatePipe")
      }
      guard SetHandleInformation(read, DWORD(HANDLE_FLAG_INHERIT), 0) else {
        let failure = error("SetHandleInformation")
        CloseHandle(read)
        CloseHandle(write)
        throw failure
      }
      return (read, write)
    }

    /// Encodes one CRT argument, including empty values and trailing backslashes.
    private static func quote(_ argument: String) -> String {
      if !argument.isEmpty, !argument.contains(where: { " \t\r\n\"".contains($0) }) {
        return argument
      }
      var result = "\""
      var slashes = 0
      for character in argument.unicodeScalars {
        if character == "\\" {
          slashes += 1
        } else {
          result += String(repeating: "\\", count: character == "\"" ? slashes * 2 + 1 : slashes)
          result.unicodeScalars.append(character)
          slashes = 0
        }
      }
      return result + String(repeating: "\\", count: slashes * 2) + "\""
    }

    static func error(_ operation: String, code: DWORD = GetLastError()) -> CommandRunnerError {
      .launchFailed("\(operation) failed (Windows error \(code)).")
    }
  }

  /// A blocking reader runs on a dispatch worker and retains its handle until EOF.
  final class WindowsCommandPipe: Sendable {
    // The native token is never dereferenced. The mutex guards the reader's
    // exclusive ownership through ReadFile and CloseHandle.
    private struct State: @unchecked Sendable {
      var handle: HANDLE?
    }

    private let state: Mutex<State>
    private let reader = DispatchQueue(label: "computer-mcp.command.output", qos: .utility)

    init(_ handle: HANDLE) { state = Mutex(State(handle: handle)) }
    deinit { state.withLock { if let value = $0.handle { CloseHandle(value) } } }

    func capture(
      limit: Int, job: WindowsProcessJob
    ) async -> Result<WindowsCommandProcess.Capture, CommandRunnerError> {
      await withCheckedContinuation { continuation in
        reader.async {
          let result = self.state.withLock {
            state -> Result<WindowsCommandProcess.Capture, CommandRunnerError> in
            guard let pipe = state.handle else {
              return .failure(.launchFailed("Command output pipe is closed."))
            }
            defer {
              CloseHandle(pipe)
              state.handle = nil
            }
            var captured = WindowsCommandProcess.Capture()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
              var count: DWORD = 0
              guard ReadFile(pipe, &buffer, DWORD(buffer.count), &count, nil) else {
                let code = GetLastError()
                if code == DWORD(ERROR_BROKEN_PIPE) { return .success(captured) }
                return .failure(WindowsCommandProcess.error("ReadFile", code: code))
              }
              if count == 0 { return .success(captured) }
              let retained = min(Int(count), limit - captured.data.count)
              captured.data.append(contentsOf: buffer.prefix(retained))
              captured.truncated = captured.truncated || retained < Int(count)
            }
          }
          if case .failure = result { job.stop(.failed) }
          continuation.resume(returning: result)
        }
      }
    }
  }
#endif
