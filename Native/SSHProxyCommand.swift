import Foundation
import Darwin

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("SelectiveRemote proxy: \(message)\n").utf8))
    exit(1)
}

func connectTCP(host: String, port: Int) -> Int32 {
    var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, String(port), &hints, &result)
    guard status == 0, let first = result else { die("cannot resolve proxy \(host):\(port)") }
    defer { freeaddrinfo(first) }
    var item: UnsafeMutablePointer<addrinfo>? = first
    while let current = item {
        let info = current.pointee
        let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
        if fd >= 0 {
            if connect(fd, info.ai_addr, info.ai_addrlen) == 0 { return fd }
            close(fd)
        }
        item = info.ai_next
    }
    die("cannot connect to proxy \(host):\(port)")
}

func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if n <= 0 { die("proxy write failed") }
            offset += n
        }
    }
}

func readExact(_ fd: Int32, count: Int) -> Data {
    var data = Data(count: count)
    let got = data.withUnsafeMutableBytes { raw -> Int in
        var offset = 0
        while offset < count {
            let n = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
            if n <= 0 { return offset }
            offset += n
        }
        return offset
    }
    guard got == count else { die("unexpected EOF from proxy") }
    return data
}

func readUntilHeaders(_ fd: Int32) -> Data {
    var out = Data()
    var byte: UInt8 = 0
    while out.count < 64 * 1024 {
        let n = Darwin.read(fd, &byte, 1)
        if n <= 0 { break }
        out.append(byte)
        if out.count >= 4 && out.suffix(4) == Data([13,10,13,10]) { return out }
    }
    die("invalid HTTP proxy response")
}

func socksAddress(_ host: String) -> Data {
    if var v4 = in_addr(), inet_pton(AF_INET, host, &v4) == 1 {
        return Data([0x01]) + Data(bytes: &v4, count: MemoryLayout<in_addr>.size)
    }
    if var v6 = in6_addr(), inet_pton(AF_INET6, host, &v6) == 1 {
        return Data([0x04]) + Data(bytes: &v6, count: MemoryLayout<in6_addr>.size)
    }
    let bytes = Array(host.utf8)
    guard bytes.count <= 255 else { die("target hostname is too long") }
    return Data([0x03, UInt8(bytes.count)]) + Data(bytes)
}

func bridge(_ socketFD: Int32) -> Never {
    var fds = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0), pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)]
    var buffer = [UInt8](repeating: 0, count: 32 * 1024)
    while true {
        let result = fds.withUnsafeMutableBufferPointer { buffer in
            poll(buffer.baseAddress, nfds_t(buffer.count), -1)
        }
        if result < 0 { if errno == EINTR { continue }; exit(0) }
        if (fds[0].revents & Int16(POLLIN)) != 0 {
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(STDIN_FILENO, raw.baseAddress, raw.count)
            }
            if n <= 0 { shutdown(socketFD, SHUT_WR); fds[0].fd = -1 }
            else { writeAll(socketFD, Data(buffer[0..<Int(n)])) }
        }
        if (fds[1].revents & Int16(POLLIN)) != 0 {
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(socketFD, raw.baseAddress, raw.count)
            }
            if n <= 0 { exit(0) }
            writeAll(STDOUT_FILENO, Data(buffer[0..<Int(n)]))
        }
        if (fds[1].revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 { exit(0) }
    }
}

@main
struct SSHProxyCommandMain {
    static func main() {
        let args = CommandLine.arguments
        // mode proxyHost proxyPort targetHost targetPort username secretFile
        if args.count != 8 { die("invalid arguments") }
        let mode = args[1]
        let proxyHost = args[2]
        guard let proxyPort = Int(args[3]), let targetPort = Int(args[5]) else { die("invalid port") }
        let targetHost = args[4]
        let username = args[6]
        let secretFile = args[7]
        let password: String = {
            guard !secretFile.isEmpty, let data = FileManager.default.contents(atPath: secretFile) else { return "" }
            defer { try? FileManager.default.removeItem(atPath: secretFile) }
            return String(data: data, encoding: .utf8) ?? ""
        }()

        let fd = connectTCP(host: proxyHost, port: proxyPort)

        if mode == "http" {
            var request = "CONNECT \(targetHost):\(targetPort) HTTP/1.1\r\nHost: \(targetHost):\(targetPort)\r\nProxy-Connection: Keep-Alive\r\n"
            if !username.isEmpty {
                let token = Data("\(username):\(password)".utf8).base64EncodedString()
                request += "Proxy-Authorization: Basic \(token)\r\n"
            }
            request += "\r\n"
            writeAll(fd, Data(request.utf8))
            let response = String(data: readUntilHeaders(fd), encoding: .utf8) ?? ""
            guard let first = response.components(separatedBy: "\r\n").first,
                  first.contains(" 200 ") || first.hasSuffix(" 200") else {
                die("HTTP CONNECT rejected: \(response.components(separatedBy: "\r\n").first ?? "unknown response")")
            }
        } else if mode == "socks5" {
            let methods: [UInt8] = username.isEmpty ? [0x00] : [0x00, 0x02]
            writeAll(fd, Data([0x05, UInt8(methods.count)] + methods))
            let hello = [UInt8](readExact(fd, count: 2))
            guard hello[0] == 0x05, hello[1] != 0xff else { die("SOCKS5 authentication method rejected") }
            if hello[1] == 0x02 {
                let u = Array(username.utf8), p = Array(password.utf8)
                guard u.count <= 255, p.count <= 255 else { die("SOCKS5 credentials are too long") }
                writeAll(fd, Data([0x01, UInt8(u.count)] + u + [UInt8(p.count)] + p))
                let auth = [UInt8](readExact(fd, count: 2))
                guard auth[1] == 0x00 else { die("SOCKS5 username/password rejected") }
            }
            var request = Data([0x05, 0x01, 0x00])
            request.append(socksAddress(targetHost))
            request.append(UInt8((targetPort >> 8) & 0xff)); request.append(UInt8(targetPort & 0xff))
            writeAll(fd, request)
            let head = [UInt8](readExact(fd, count: 4))
            guard head[1] == 0x00 else { die("SOCKS5 CONNECT rejected with code \(head[1])") }
            switch head[3] {
            case 0x01: _ = readExact(fd, count: 4 + 2)
            case 0x04: _ = readExact(fd, count: 16 + 2)
            case 0x03:
                let len = Int([UInt8](readExact(fd, count: 1))[0]); _ = readExact(fd, count: len + 2)
            default: die("invalid SOCKS5 response")
            }
        } else { die("unknown proxy mode") }

        bridge(fd)
    }
}
