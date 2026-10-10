import AppKit
import Darwin
import Foundation

extension Ghostty {
    /// A tool-specific resume target, never a captured arbitrary command line.
    struct TerminalSession: Codable, Equatable {
        enum Tool: String, Codable {
            case pi, claude, codex, copilot, tmux, zellij
        }

        let tool: Tool
        let sessionId: String
        let sessionFile: String?
        let cwd: String
        // tmux servers can use custom sockets; preserve the exact server.
        var socket: String?

        var resumeCommand: String? {
            guard cwd.hasPrefix("/"), !sessionId.isEmpty,
                  cwd.rangeOfCharacter(from: .controlCharacters) == nil,
                  sessionId.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            let target = Ghostty.Shell.quote(sessionId)
            switch tool {
            case .pi:
                guard let sessionFile,
                      Ghostty.PiSession(sessionId: sessionId, sessionFile: sessionFile, cwd: cwd).isValid else {
                    return nil
                }
                return "pi --session \(Ghostty.Shell.quote(sessionFile))"
            case .claude, .codex, .copilot:
                guard UUID(uuidString: sessionId) != nil, let sessionFile,
                      Self.transcript(tool: tool, path: sessionFile, cwd: cwd)?.sessionId == sessionId else { return nil }
                switch tool {
                case .claude: return "claude --resume \(target)"
                case .codex: return "codex resume \(target)"
                default: return "copilot --resume=\(target)"
                }
            case .tmux:
                guard let socket, socket.hasPrefix("/"),
                      socket.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
                // Attach only: never recreate or replay a dead server's commands.
                return "tmux -S \(Ghostty.Shell.quote(socket)) attach-session -t \(target)"
            case .zellij:
                // Never use --force-run-commands when resurrecting a session.
                return "zellij attach -- \(target)"
            }
        }

        @MainActor
        static func current(for surface: Ghostty.Surface?, cwd: String?) -> Self? {
            guard let surface, let cwd, let foreground = surface.foregroundPID,
                  let pid = Int32(exactly: foreground) else { return nil }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
                    == MemoryLayout.size(ofValue: info), info.pbi_uid == getuid(),
                  let args = arguments(pid), let first = args.first else { return nil }
            let executable = URL(fileURLWithPath: first.trimmingCharacters(in: .whitespaces)).lastPathComponent
            let tool: Tool?
            if executable == "node" || executable == "bun" {
                tool = args.dropFirst().prefix(2).compactMap { argument in
                    let name = URL(fileURLWithPath: argument).lastPathComponent
                    return Tool(rawValue: name.replacingOccurrences(of: ".js", with: ""))
                }.first
            } else {
                tool = Tool(rawValue: executable)
            }
            guard let tool else { return nil }
            // Pi overwrites argv and closes its transcript after every append.
            // Its session-manager plugin provides the exact live TTY mapping.
            if tool == .pi {
                return piSession(pid: pid, info: info, tty: surface.ttyName, cwd: cwd)
            }
            let paths = openFiles(pid)
            if tool == .tmux {
                return tmuxSession(pid: pid, paths: paths, cwd: cwd)
            }
            // Zellij's client socket identifies the active named session even
            // when the session was selected through its picker.
            if tool == .zellij {
                let sockets = paths.filter { $0.contains("/zellij-") }
                let names = Set(sockets.map { URL(fileURLWithPath: $0).lastPathComponent })
                guard names.count == 1, let name = names.first else { return nil }
                return Self(tool: tool, sessionId: name, sessionFile: nil, cwd: cwd)
            }
            // The active transcript must be held by this exact foreground
            // process. Multiple candidates (e.g. subagents) are ambiguous.
            let sessions = Set(paths.compactMap { transcript(tool: tool, path: $0, cwd: cwd) })
            guard sessions.count == 1 else { return nil }
            return sessions.first
        }

        private struct PiLiveRecord: Decodable {
            let version: Int
            let instanceId: String
            let active: Bool
            let pid: Int32
            let sessionId: String
            let sessionFile: String
            let tty: String
            let cwd: String
            let updatedAt: Double
        }

        private static func piSession(pid: Int32, info: proc_bsdinfo, tty: String?, cwd: String) -> Self? {
            guard let tty else { return nil }
            let liveFile = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".pi/agent/pi-session-manager/by-pid/\(pid).json")
            guard FileManager.default.fileExists(atPath: liveFile.path) else { return nil }
            do {
                let target = liveFile.resolvingSymlinksInPath()
                let expectedDirectory = liveFile.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("live").resolvingSymlinksInPath()
                guard target.deletingLastPathComponent() == expectedDirectory,
                      let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 64 * 1024 else { return nil }
                let record = try JSONDecoder().decode(PiLiveRecord.self, from: Data(contentsOf: target))
                let startedAt = Double(info.pbi_start_tvsec) * 1000 + Double(info.pbi_start_tvusec) / 1000
                // PID, TTY and process start time must all match; crash leftovers
                // are never mistaken for a newly started process using the same PID.
                guard record.version == 1, record.active, UUID(uuidString: record.instanceId) != nil,
                      target.lastPathComponent == "\(record.instanceId).json",
                      record.pid == pid, record.tty == tty,
                      record.cwd == cwd, record.updatedAt >= startedAt else { return nil }
                let session = Self(tool: .pi, sessionId: record.sessionId,
                                   sessionFile: record.sessionFile, cwd: record.cwd)
                return session.resumeCommand == nil ? nil : session
            } catch {
                AppDelegate.logger.debug("Cannot resolve live Pi session: \(error.localizedDescription)")
                return nil
            }
        }

        private static func transcript(tool: Tool, path: String, cwd: String) -> Self? {
            guard path.hasSuffix(".jsonl") else { return nil }
            let id: String
            switch tool {
            case .claude:
                guard path.contains("/projects/"), !path.contains("/subagents/") else { return nil }
                id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                guard records(path).contains(where: {
                    $0["sessionId"] as? String == id && $0["cwd"] as? String == cwd
                }) else { return nil }
            case .copilot:
                guard path.contains("/session-state/"), path.hasSuffix("/events.jsonl") else { return nil }
                id = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                guard let row = records(path).first, row["type"] as? String == "session.start",
                      let data = row["data"] as? [String: Any], data["sessionId"] as? String == id,
                      let context = data["context"] as? [String: Any], context["cwd"] as? String == cwd else {
                    return nil
                }
            case .codex:
                guard path.contains("/sessions/"), let row = records(path).first,
                      row["type"] as? String == "session_meta",
                      let payload = row["payload"] as? [String: Any],
                      payload["cwd"] as? String == cwd,
                      let value = payload["id"] as? String else { return nil }
                id = value
            default: return nil
            }
            guard UUID(uuidString: id) != nil else { return nil }
            return Self(tool: tool, sessionId: id, sessionFile: path, cwd: cwd)
        }

        private static func records(_ path: String) -> [[String: Any]] {
            do {
                let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { file.closeFile() }
                guard let data = try file.read(upToCount: 256 * 1024),
                      let newline = data.lastIndex(of: 10) else { return [] }
                // Read a bounded metadata prefix, excluding any partial final line.
                return try data[..<newline].split(separator: 10).prefix(32).compactMap {
                    try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
                }
            } catch {
                AppDelegate.logger.debug("Cannot read native session metadata: \(error.localizedDescription)")
                return []
            }
        }

        /// KERN_PROCARGS2 includes the environment too; only decode argc entries.
        private static func arguments(_ pid: Int32) -> [String]? {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
                  size > MemoryLayout<Int32>.size, size <= 1024 * 1024 else { return nil }
            var bytes = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
            let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            guard argc > 0, argc < 4096 else { return nil }
            var index = MemoryLayout<Int32>.size
            while index < size && bytes[index] != 0 { index += 1 }
            while index < size && bytes[index] == 0 { index += 1 }
            var result: [String] = []
            for _ in 0..<argc {
                let start = index
                while index < size && bytes[index] != 0 { index += 1 }
                guard index < size else { return nil }
                result.append(String(decoding: bytes[start..<index], as: UTF8.self))
                index += 1
            }
            return result
        }

        /// Native macOS FD inspection: no lsof subprocess, no transcript scans.
        private static func openFiles(_ pid: Int32) -> [String] {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0, size < 1024 * 1024 else { return [] }
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 16)
            let count = descriptors.withUnsafeMutableBytes {
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            guard count > 0, Int(count) <= descriptors.count * MemoryLayout<proc_fdinfo>.size else { return [] }
            var result: [String] = []
            for descriptor in descriptors.prefix(Int(count) / MemoryLayout<proc_fdinfo>.size) {
                if descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
                    var value = vnode_fdinfowithpath()
                    guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO,
                                        &value, Int32(MemoryLayout.size(ofValue: value))) > 0 else { continue }
                    let path = withUnsafePointer(to: &value.pvip.vip_path) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                    }
                    result.append(path)
                } else if descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
                    var value = socket_fdinfo()
                    guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO,
                                        &value, Int32(MemoryLayout.size(ofValue: value))) > 0,
                          value.psi.soi_family == AF_UNIX else { continue }
                    let path = withUnsafePointer(to: &value.psi.soi_proto.pri_un.unsi_caddr) {
                        $0.withMemoryRebound(to: sockaddr_un.self, capacity: 1) { address in
                            withUnsafePointer(to: address.pointee.sun_path) {
                                $0.withMemoryRebound(to: CChar.self, capacity: 104) { String(cString: $0) }
                            }
                        }
                    }
                    if !path.isEmpty { result.append(path) }
                }
            }
            return result
        }

        private static func tmuxSession(pid: Int32, paths: [String], cwd: String) -> Self? {
            // Socket discovery is native. Ask that server which session this
            // exact client is attached to, without changing any server state.
            let sockets = Set(paths.filter { $0.contains("/tmux-") || $0.hasSuffix(".sock") })
            guard sockets.count == 1, let socket = sockets.first else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["tmux", "-S", socket, "list-clients", "-F", "#{client_pid}\t#{session_id}"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let completed = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in completed.signal() }
            do {
                try process.run()
                if completed.wait(timeout: .now() + 1) == .timedOut {
                    process.terminate()
                    return nil
                }
                guard process.terminationStatus == 0 else { return nil }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let matches = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { row -> String? in
                    let fields = row.split(separator: "\t")
                    guard fields.count == 2, fields[0] == String(pid) else { return nil }
                    return String(fields[1])
                }
                guard matches.count == 1 else { return nil }
                return Self(tool: .tmux, sessionId: matches[0], sessionFile: nil, cwd: cwd, socket: socket)
            } catch {
                AppDelegate.logger.debug("Cannot query tmux client: \(error.localizedDescription)")
                return nil
            }
        }
    }
}

extension Ghostty.TerminalSession: Hashable {}
