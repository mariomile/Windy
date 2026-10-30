import Foundation

typealias JSON = [String: Any]

enum Paths {
    static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Windy", isDirectory: true)
    }
    static var socket: String { support.appendingPathComponent("windy.sock").path }
    static var workspaces: URL { support.appendingPathComponent("workspaces.json") }
}

/// Newline-delimited JSON over a Unix domain socket.
enum Socket {
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let fits = withUnsafeMutableBytes(of: &addr.sun_path) { buffer -> Bool in
            guard bytes.count < buffer.count else { return false }
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
            return true
        }
        return fits ? addr : nil
    }

    static func connect(_ path: String) -> Int32? {
        guard var addr = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); return nil }
        configure(fd, timeout: 40)
        return fd
    }

    static func configure(_ fd: Int32, timeout seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Reads up to the first newline (or the end), at most 1 MB.
    static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 1_000_000 {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
            if let newline = data.firstIndex(of: 10) { return data[..<newline] }
        }
        return data.isEmpty ? nil : data
    }

    static func write(_ fd: Int32, _ object: JSON) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard n > 0 else { return }
                offset += n
            }
        }
    }
}

/// The app's end of the `windy` command: one JSON request per connection, one JSON reply.
/// The socket sits in your Library with owner-only permissions, so only your user can reach it.
final class CommandServer {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var inode: ino_t = 0
    private let handle: (JSON, @escaping (JSON) -> Void) -> Void

    /// `handle` runs on the main thread and calls its reply closure once, from any thread.
    init(handle: @escaping (JSON, @escaping (JSON) -> Void) -> Void) {
        self.handle = handle
    }

    /// Returns false when another copy of Windy already answers on the socket.
    @discardableResult
    func start() -> Bool {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let path = Paths.socket
        if let other = Socket.connect(path) {
            close(other)
            return false
        }
        unlink(path)
        guard var addr = Socket.address(path) else { return true }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 128) == 0 else {
            close(fd)
            fd = -1
            return true
        }
        var info = stat()
        if stat(path, &info) == 0 { inode = info.st_ino }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.resume()
        self.source = source
        return true
    }

    func stop() {
        source?.cancel()
        if fd >= 0 { close(fd) }
        // Only remove the socket if it's still ours, not one a newer copy of Windy made.
        var info = stat()
        if inode != 0, stat(Paths.socket, &info) == 0, info.st_ino == inode { unlink(Paths.socket) }
    }

    /// Takes every connection waiting, so a burst of commands doesn't overflow the queue.
    private func acceptClients() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        // Accepted sockets inherit non-blocking mode; replies use blocking IO with timeouts.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        Socket.configure(client, timeout: 5)
        DispatchQueue.global().async { [handle] in
            guard let line = Socket.readLine(client),
                  let request = (try? JSONSerialization.jsonObject(with: line)) as? JSON else {
                Socket.write(client, ["ok": false, "error": "Windy couldn't read that request."])
                close(client)
                return
            }
            DispatchQueue.main.async {
                handle(request) { reply in
                    DispatchQueue.global().async {
                        Socket.write(client, reply)
                        close(client)
                    }
                }
            }
        }
    }
}
