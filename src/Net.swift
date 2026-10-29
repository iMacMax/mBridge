import Foundation

// Plain BSD sockets. Wire format is one text line per message, e.g. "p 120 340" (cursor), "k 65 0 1" (key down).
// Every computer both announces itself and listens, so any computer can control any other.

struct Peer {
    var id: String
    var name: String
    var host: String
    var port: UInt16
    var size: CGSize
    var platform: String   // "mac" or "win"
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

private func configure(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var sendTimeout = timeval(tv_sec: 0, tv_usec: 500_000)   // a stuck computer must never freeze the mouse
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
}

private func setReceiveTimeout(_ fd: Int32, seconds: Int) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

// MARK: - Finding other computers

/// Listens for other computers' "I'm here" broadcasts: "mBridge|id|name|width|height|port|platform".
final class Discovery {
    static let port: UInt16 = 24801

    func start(selfID: String, onPeer: @escaping (Peer) -> Void) {
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
                guard fields.count >= 6, fields[0] == "mBridge", String(fields[1]) != selfID,
                      let w = Double(fields[3]), let h = Double(fields[4]), let port = UInt16(fields[5]) else { continue }
                // computers older than the platform field are Windows PCs
                let platform = fields.count > 6 ? String(fields[6]).trimmingCharacters(in: .whitespacesAndNewlines) : "win"
                let peer = Peer(id: String(fields[1]), name: String(fields[2]), host: String(cString: ip), port: port,
                                size: CGSize(width: w, height: h), platform: platform, seen: Date())
                DispatchQueue.main.async { onPeer(peer) }
            }
        }
    }
}

/// Shouts "I'm here" once a second, on every network this computer is on.
final class Beacon {
    func start(payload: @escaping () -> String) {
        Thread.detachNewThread {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
            while true {
                let data = Array(payload().utf8)
                for address in Beacon.broadcastAddresses() {
                    var dest = sockaddr_in()
                    dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    dest.sin_family = sa_family_t(AF_INET)
                    dest.sin_port = Discovery.port.bigEndian
                    dest.sin_addr = address
                    withUnsafePointer(to: &dest) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            _ = sendto(fd, data, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    /// 255.255.255.255 plus the broadcast address of every active network interface.
    private static func broadcastAddresses() -> [in_addr] {
        var result = [in_addr(s_addr: 0xFFFF_FFFF)]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return result }
        var next = list
        while let entry = next {
            let flags = Int32(entry.pointee.ifa_flags)
            if flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
               let dst = entry.pointee.ifa_dstaddr, dst.pointee.sa_family == sa_family_t(AF_INET) {
                dst.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { result.append($0.pointee.sin_addr) }
            }
            next = entry.pointee.ifa_next
        }
        freeifaddrs(list)
        return result
    }
}

// MARK: - Being controlled

/// Which computer is allowed to control this one: the first one that connects is remembered, others are turned away.
enum Pairing {
    private static let key = "pairedController"

    static func allows(_ candidate: String) -> Bool {
        if let saved = UserDefaults.standard.string(forKey: key) { return saved == candidate }
        UserDefaults.standard.set(candidate, forKey: key)
        return true
    }

    static func forget() { UserDefaults.standard.removeObject(forKey: key) }
}

/// Accepts other computers that want to control this one.
final class Server {
    static let port: UInt16 = 24802

    /// `onAccept` runs on the main thread with the controller's name and an open link.
    func start(size: @escaping () -> CGSize, onAccept: @escaping (String, Link) -> Void) {
        Thread.detachNewThread {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = Server.port.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, listen(fd, 4) == 0 else { Darwin.close(fd); return }

            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break }
                Thread.detachNewThread { Server.greet(client, size: size, onAccept: onAccept) }
            }
        }
    }

    private static func greet(_ fd: Int32, size: () -> CGSize, onAccept: @escaping (String, Link) -> Void) {
        configure(fd)
        setReceiveTimeout(fd, seconds: 3)
        let link = Link(fd: fd)
        let hello = (link.readLineBlocking() ?? "").split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard hello.count >= 2, hello[0] == "hi" else { link.finish(); return }
        guard Pairing.allows(String(hello[1])) else {
            link.send("deny")
            link.finishAfterSending()
            return
        }
        let screen = size()
        link.send("ok \(Int(screen.width)) \(Int(screen.height)) mac")
        setReceiveTimeout(fd, seconds: 5)   // the controller sends a "." every second
        let name = hello.count > 2 ? String(hello[2]) : "Computer"
        DispatchQueue.main.async { onAccept(name, link) }
    }
}

// MARK: - Controlling another computer

enum OpenResult {
    case failed
    case denied
    case ok(Link, CGSize)
}

final class Link {
    private let fd: Int32
    private var hungUp = false
    private var released = false
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "mBridge.link.writer")

    init(fd: Int32) { self.fd = fd }

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

        configure(fd)
        setReceiveTimeout(fd, seconds: 3)

        let link = Link(fd: fd)
        link.send(hello)
        guard let reply = link.readLineBlocking() else { link.finish(); return .failed }
        let parts = reply.split(separator: " ")
        guard parts.first == "ok", parts.count >= 3, let w = Double(parts[1]), let h = Double(parts[2]) else {
            link.finish()
            return parts.first == "deny" ? .denied : .failed
        }

        // The other computer sends a "." every second; silence for 5 seconds means it is gone.
        setReceiveTimeout(fd, seconds: 5)
        return .ok(link, CGSize(width: w, height: h))
    }

    func readLineBlocking() -> String? {
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

    /// Writes on a background queue, in order, so a slow network can never freeze the Mac's mouse and keyboard.
    /// A failed write closes the link, which the reader then reports.
    func send(_ line: String) {
        let bytes = Array((line + "\n").utf8)
        writer.async { [self] in
            guard !isHungUp else { return }
            var sent = 0
            while sent < bytes.count {
                let n = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { hangUp(); return }
                sent += n
            }
        }
    }

    /// Makes the reader stop; `finish()` then frees the socket.
    func hangUp() {
        lock.lock()
        defer { lock.unlock() }
        guard !hungUp else { return }
        hungUp = true
        shutdown(fd, SHUT_RDWR)
    }

    private var isHungUp: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hungUp
    }

    func finish() {
        hangUp()
        // close only after queued writes are done, so the socket number can't be reused under them
        writer.async { [self] in
            guard !released else { return }
            released = true
            Darwin.close(fd)
        }
    }

    /// Closes once everything already queued (like a last "deny") has been sent.
    func finishAfterSending() {
        writer.async { [self] in
            hangUp()
            guard !released else { return }
            released = true
            Darwin.close(fd)
        }
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
