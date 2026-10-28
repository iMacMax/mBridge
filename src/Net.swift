import Foundation

// Plain BSD sockets. Wire format is one text line per message, e.g. "p 120 340" (cursor), "k 65 0 1" (key down).

struct Peer {
    var id: String
    var name: String
    var host: String
    var port: UInt16
    var size: CGSize
    var seen: Date
}

private func ipv4(_ host: String, _ port: UInt16) -> sockaddr_in? {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
    return addr
}

// MARK: - Finding the PC

/// Listens for the PC's "I'm here" broadcast: "mBridge|id|name|width|height|port".
final class Discovery {
    static let port: UInt16 = 24801

    func start(onPeer: @escaping (Peer) -> Void) {
        Thread.detachNewThread {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = Discovery.port.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0 else { Darwin.close(fd); return }

            var buf = [UInt8](repeating: 0, count: 512)
            while true {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
                }
                if n < 0 { if errno == EINTR { continue }; break }
                var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var source = from.sin_addr
                inet_ntop(AF_INET, &source, &ip, socklen_t(INET_ADDRSTRLEN))

                let fields = String(decoding: buf[0..<n], as: UTF8.self).split(separator: "|", omittingEmptySubsequences: false)
                guard fields.count >= 6, fields[0] == "mBridge",
                      let w = Double(fields[3]), let h = Double(fields[4]), let port = UInt16(fields[5]) else { continue }
                let peer = Peer(id: String(fields[1]), name: String(fields[2]), host: String(cString: ip), port: port,
                                size: CGSize(width: w, height: h), seen: Date())
                DispatchQueue.main.async { onPeer(peer) }
            }
        }
    }
}

// MARK: - Talking to the PC

enum OpenResult {
    case failed
    case denied
    case ok(Link, CGSize)
}

final class Link {
    private let fd: Int32
    private var hungUp = false
    private var released = false

    private init(fd: Int32) { self.fd = fd }

    /// Connects and says hello. Blocking: call it off the main thread.
    static func open(host: String, port: UInt16, hello: String) -> OpenResult {
        guard var addr = ipv4(host, port) else { return .failed }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed }

        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)   // so connect can time out
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var error: Int32 = 0
        var errorLen = socklen_t(MemoryLayout<Int32>.size)
        guard r == 0 || (errno == EINPROGRESS && poll(&poller, 1, 3000) > 0
                         && getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &errorLen) == 0 && error == 0) else {
            Darwin.close(fd)
            return .failed
        }
        _ = fcntl(fd, F_SETFL, flags)

        var on: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var sendTimeout = timeval(tv_sec: 0, tv_usec: 500_000)   // a stuck PC must never freeze the Mac's mouse
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        var replyTimeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &replyTimeout, socklen_t(MemoryLayout<timeval>.size))

        let link = Link(fd: fd)
        link.send(hello)
        guard let reply = link.readLineBlocking() else { Darwin.close(fd); return .failed }
        let parts = reply.split(separator: " ")
        guard parts.first == "ok", parts.count >= 3, let w = Double(parts[1]), let h = Double(parts[2]) else {
            Darwin.close(fd)
            return parts.first == "deny" ? .denied : .failed
        }

        // The PC sends a "." every second; silence for 5 seconds means it is gone.
        var runTimeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &runTimeout, socklen_t(MemoryLayout<timeval>.size))
        return .ok(link, CGSize(width: w, height: h))
    }

    private func readLineBlocking() -> String? {
        var bytes = [UInt8]()
        var byte: UInt8 = 0
        while bytes.count < 256 {
            let n = read(fd, &byte, 1)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
        return nil
    }

    /// Main thread only. A failed write closes the link, which the reader then reports.
    func send(_ line: String) {
        guard !hungUp else { return }
        let bytes = Array((line + "\n").utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { hangUp(); return }
            sent += n
        }
    }

    /// Makes the reader stop; `finish()` then frees the socket.
    func hangUp() {
        guard !hungUp else { return }
        hungUp = true
        shutdown(fd, SHUT_RDWR)
    }

    func finish() {
        hangUp()
        guard !released else { return }
        released = true
        Darwin.close(fd)
    }

    /// Reads lines on a background thread and reports them on the main thread.
    func listen(onLine: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        let fd = self.fd
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 4096)
            var pending = [UInt8]()
            while true {
                let n = read(fd, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                pending.append(contentsOf: buf[0..<n])
                while let newline = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending[0..<newline], as: UTF8.self)
                    pending.removeSubrange(0...newline)
                    DispatchQueue.main.async { onLine(line) }
                }
            }
            DispatchQueue.main.async { onClose() }
        }
    }
}
