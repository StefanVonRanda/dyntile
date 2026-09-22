import Foundation

/// A tiny line protocol over a unix socket, so `dyntile msg <command>` can drive a
/// running instance. Useful for scripting, for testing bindings, and for anyone who
/// would rather keep their hotkeys in skhd or Karabiner.
enum IPC {
    static var socketPath: String {
        "/tmp/dyntile-\(getuid()).sock"
    }

    /// Fill a sockaddr_un. Built in one place because sun_path is a fixed-size tuple
    /// and writing into it needs an exclusive borrow of the whole struct.
    fileprivate static func address(for path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                _ = path.withCString { strncpy(dst, $0, capacity - 1) }
            }
        }
        return addr
    }

    final class Server {
        private var fd: Int32 = -1
        private var source: DispatchSourceRead?
        private let handler: (String) -> String

        init(handler: @escaping (String) -> String) {
            self.handler = handler
        }

        func start() throws {
            let path = IPC.socketPath
            unlink(path)
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ConfigError("socket(): \(String(cString: strerror(errno)))") }

            var addr = IPC.address(for: path)
            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
            }
            guard bound == 0 else { throw ConfigError("bind(\(path)): \(String(cString: strerror(errno)))") }
            guard listen(fd, 8) == 0 else {
                throw ConfigError("listen(): \(String(cString: strerror(errno)))")
            }
            chmod(path, 0o600)

            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            src.setEventHandler { [weak self] in self?.accept() }
            src.resume()
            source = src
        }

        private func accept() {
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = read(client, &buffer, buffer.count)
            guard n > 0 else { return }
            let request = String(decoding: buffer[0..<n], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var reply = handler(request)
            if !reply.hasSuffix("\n") { reply += "\n" }
            _ = reply.withCString { write(client, $0, strlen($0)) }
        }

        func stop() {
            source?.cancel()
            if fd >= 0 { close(fd) }
            unlink(IPC.socketPath)
        }
    }

    /// Send one command to a running dyntile. Returns its reply.
    static func send(_ message: String) throws -> String {
        let path = socketPath
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConfigError("socket(): \(String(cString: strerror(errno)))") }
        defer { close(fd) }

        var addr = IPC.address(for: path)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else {
            throw ConfigError("dyntile is not running (no socket at \(path))")
        }
        _ = message.withCString { write(fd, $0, strlen($0)) }
        shutdown(fd, SHUT_WR)

        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { return "" }
        return String(decoding: buffer[0..<n], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
