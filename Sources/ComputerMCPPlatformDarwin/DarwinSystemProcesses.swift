import ComputerMCPPlatform
import Darwin
import Foundation

extension DarwinSystemProbe {
  package func processes(
    deadline: ContinuousClock.Instant, visit: (SystemProcess) throws -> Bool
  ) throws -> Bool {
    let clock = ContinuousClock()
    var capacity = max(Int(proc_listallpids(nil, 0)), 1) + 64
    var pids: [pid_t]
    while true {
      if clock.now >= deadline { return true }
      pids = [pid_t](repeating: 0, count: capacity)
      let count = pids.withUnsafeMutableBytes {
        proc_listallpids($0.baseAddress, Int32($0.count))
      }
      guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
      if count < capacity {
        pids.removeSubrange(Int(count)...)
        break
      }
      capacity *= 2
    }

    var argumentBuffer = [UInt8](repeating: 0, count: max(Int(sysconf(_SC_ARG_MAX)), 4096))
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    let physicalMemory = Double(ProcessInfo.processInfo.physicalMemory)
    var users: [uid_t: String] = [:]
    for pid in pids.filter({ $0 > 0 }).sorted() {
      if clock.now >= deadline { return true }
      var bsd = proc_bsdinfo()
      let bsdSize = Int32(MemoryLayout.size(ofValue: bsd))
      let hasBSD = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize
      var short = proc_bsdshortinfo()
      if !hasBSD {
        let size = Int32(MemoryLayout.size(ofValue: short))
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, size) == size else {
          continue
        }
      }
      let uid = hasBSD ? bsd.pbi_uid : short.pbsi_uid
      if users[uid] == nil { users[uid] = processUser(uid) }
      let fullName = processString(bsd.pbi_name)
      let name =
        hasBSD
        ? (fullName.isEmpty ? processString(bsd.pbi_comm) : fullName)
        : processString(short.pbsi_comm)
      var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
      let pathSize = path.withUnsafeMutableBytes {
        proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
      }
      let executable =
        pathSize > 0 ? String(decoding: path.prefix(Int(pathSize)), as: UTF8.self) : name
      let arguments = processArguments(
        pid, flags: hasBSD ? bsd.pbi_flags : short.pbsi_flags, buffer: &argumentBuffer)
      let elapsed =
        hasBSD
        ? max(
          0,
          Date().timeIntervalSince1970 - Double(bsd.pbi_start_tvsec)
            - Double(bsd.pbi_start_tvusec) / 1_000_000) : nil
      var task = proc_taskinfo()
      let taskSize = Int32(MemoryLayout.size(ofValue: task))
      let hasTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize
      let cpu =
        hasTask
        ? elapsed.map {
          $0 > 0
            ? (Double(task.pti_total_user) + Double(task.pti_total_system))
              * secondsPerTick / $0 * 100 : 0
        } : nil
      let memory = hasTask ? Double(task.pti_resident_size) / physicalMemory * 100 : nil
      let process = SystemProcess(
        pid: pid, parentPID: Int32(hasBSD ? bsd.pbi_ppid : short.pbsi_ppid),
        user: users[uid]!,
        state: processState(
          hasBSD ? bsd.pbi_status : short.pbsi_status,
          flags: hasBSD ? bsd.pbi_flags : short.pbsi_flags, bsd: hasBSD ? bsd : nil,
          task: hasTask ? task : nil),
        cpuPercent: cpu, memoryPercent: memory, elapsedSeconds: elapsed,
        executable: executable, arguments: arguments)
      if clock.now >= deadline { return true }
      if try !visit(process) { return false }
    }
    return false
  }
}

private func processArguments(_ pid: pid_t, flags: UInt32, buffer: inout [UInt8]) -> [String]? {
  var mib = [CTL_KERN, KERN_PROCARGS2, pid]
  var size = buffer.count
  let status = buffer.withUnsafeMutableBytes {
    sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0)
  }
  // A full sysctl buffer may contain a suffix of the strings area, without argv's prefix.
  guard status == 0, size >= MemoryLayout<Int32>.size, size < buffer.count else { return nil }
  let count = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
  guard count > 0, count <= size - MemoryLayout<Int32>.size else { return nil }
  // XNU aligns the executable path area to the target's pointer width. Its stripped
  // "executable_path=" prefix is 16 bytes, so alignment survives KERN_PROCARGS2.
  // Skipping arbitrary NULs would consume empty argv entries and reach the environment.
  var offset = MemoryLayout<Int32>.size
  guard let pathEnd = buffer[offset..<size].firstIndex(of: 0) else { return nil }
  let width = flags & UInt32(PROC_FLAG_LP64) != 0 ? 8 : 4
  let pathBytes = pathEnd + 1 - offset
  offset += (pathBytes + width - 1) / width * width
  guard offset <= size, buffer[pathEnd..<offset].allSatisfy({ $0 == 0 }) else { return nil }
  var arguments: [String] = []
  for _ in 0..<count {
    guard offset < size, let end = buffer[offset..<size].firstIndex(of: 0) else { return nil }
    arguments.append(String(decoding: buffer[offset..<end], as: UTF8.self))
    offset = end + 1
  }
  return arguments
}

private func processState(
  _ status: UInt32, flags: UInt32, bsd: proc_bsdinfo?, task: proc_taskinfo?
) -> String {
  var state: String
  switch Int32(status) {
  case SIDL: state = "I"
  case SRUN: state = task.map { $0.pti_numrunning > 0 ? "R" : "S" } ?? "R"
  case SSLEEP: state = "S"
  case SSTOP: state = "T"
  case SZOMB: state = "Z"
  default: state = "?"
  }
  if let bsd {
    if bsd.pbi_nice < 0 { state += "<" }
    if bsd.pbi_nice > 0 { state += "N" }
  }
  if flags & UInt32(PROC_FLAG_TRACED) != 0 { state += "X" }
  if flags & UInt32(PROC_FLAG_SLEADER) != 0 { state += "s" }
  if let bsd, flags & UInt32(PROC_FLAG_CTTY) != 0, bsd.pbi_pgid == bsd.e_tpgid { state += "+" }
  return state
}

private func processString<T>(_ value: T) -> String {
  withUnsafeBytes(of: value) { bytes in
    String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
  }
}

private func processUser(_ uid: uid_t) -> String {
  var entry = passwd()
  var result: UnsafeMutablePointer<passwd>?
  var buffer = [CChar](repeating: 0, count: max(Int(sysconf(_SC_GETPW_R_SIZE_MAX)), 16_384))
  return buffer.withUnsafeMutableBufferPointer {
    guard getpwuid_r(uid, &entry, $0.baseAddress, $0.count, &result) == 0,
      result != nil, let name = entry.pw_name
    else { return String(uid) }
    return String(cString: name)
  }
}
