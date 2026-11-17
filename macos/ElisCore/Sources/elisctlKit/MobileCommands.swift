#if os(macOS)
import ArgumentParser
import CoreImage
import CryptoKit
import Foundation
import Network
import Security
import SystemConfiguration
import ElisCore

// MARK: - mobile

/// Mobile runs the TLS and Bluetooth relay elis Mobile connects to. The phone sends the same `{cmd, target, args}` lines
/// elisctl sends, plus an `id` echoed on the answer; each line is forwarded to the control socket.
struct Mobile: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Let Elis Mobile drive this Mac over the network or Bluetooth.",
        subcommands: [Serve.self, Reset.self]
    )

    struct Serve: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Serve the pairing link and relay Elis Mobile's requests until stopped.",
            discussion: """
            Prints a QR code and the pairing links, then relays every authenticated phone's requests to the control \
            socket. Anyone with the link controls your terminals; `elisctl mobile reset` revokes it. The token, key \
            and certificate live in <state dir>/mobile; --socket changes only where requests go.
            """)
        @Option(name: .long, help: "TCP port to listen on, 1024...65535.")
        var port: UInt16 = 8765
        @Option(name: .long, help: "IP address to listen on (default: all interfaces).")
        var bind: String?
        @Option(name: .long, help: "Host name or address the phone should dial (default: this Mac's LAN addresses).")
        var host: String?
        @Flag(name: .customLong("no-qr"), help: "Print the links without the QR code.")
        var noQR = false
        @Option(name: .long, help: "Override the control socket path requests are forwarded to.")
        var socket: String?
        @Flag(inversion: .prefixedNo, help: "Offer Bluetooth (BLE L2CAP) to Elis Mobile.")
        var bluetooth = true

        func validate() throws {
            if !PhoneDesktopState.portRange.contains(Int(port)) { throw ValidationError(PhoneDesktopState.portError) }
            if let bind, IPv4Address(bind) == nil, IPv6Address(bind) == nil { throw ValidationError("--bind takes an IP address") }
        }

        func run() throws {
            let env = ProcessInfo.processInfo.environment
            let dir = MobilePairing.directory(environment: env)
            let relay: MobileRelay
            let token: String
            let fingerprint: String
            let listening: UInt16
            do {
                try MobilePairing.ensurePrivateDirectory(dir)
                token = try MobilePairing.loadToken(in: dir)
                try MobilePairing.ensureCertificate(in: dir)
                let identity: SecIdentity
                (identity, fingerprint) = try MobilePairing.identity(in: dir)
                let socketPath = socket ?? ControlResolve.socketPath(stateDir: env["ELIS_STATE_DIR"],
                                                                     appSupport: ControlResolve.defaultStateDirectory(environment: env))
                relay = MobileRelay(identity: identity, port: port, bind: bind, mobileDir: dir, socketPath: socketPath,
                                    hostName: MobilePairing.hostName())
                relay.onFailure = { Darwin.exit(1) }
                listening = try relay.start()
            } catch {
                FileHandle.standardError.write(Data("elisctl: \(error)\n".utf8))
                throw ExitCode.failure
            }

            let radio = bluetooth ? MobileBluetooth(relay: relay, token: token, status: Self.bluetoothStatus) : nil
            if radio == nil { Self.bluetoothStatus("off (disabled)") }
            let offered = radio?.start() ?? false
            var lan: [String?] = host.map { [$0] } ?? MobilePairing.lanAddresses()
            if lan.isEmpty {
                // a Bluetooth phone needs no host; without Bluetooth only this Mac can use the link
                if !offered { FileHandle.standardError.write(Data("elisctl: no LAN address; the link works on this Mac only\n".utf8)) }
                lan = [offered ? nil : "127.0.0.1"]
            }
            let name = MobilePairing.hostName()
            let links = lan.map {
                MobilePairing.pairLink(host: $0, port: listening, token: token, fingerprint: fingerprint, name: name, bluetooth: offered)
            }
            if !noQR, let matrix = try? MobilePairing.qrMatrix(links[0]) {
                MobilePairing.qrRows(matrix).forEach { print($0) }
            }
            print("\nScan the code in Elis Mobile, or paste the link:")
            links.forEach { print($0) }
            print("\nListening on \(bind ?? "*"):\(listening). Anyone with the link controls your terminals; "
                + "`elisctl mobile reset` revokes it. Ctrl+C stops.")
            fflush(stdout)

            var sources: [any DispatchSourceProtocol] = []
            for stop in [SIGINT, SIGTERM, SIGHUP] {
                signal(stop, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: stop, queue: .main)
                source.setEventHandler {
                    relay.releaseAllGrids() // a stopped relay gives grids back; a dead parent took the sessions with it
                    Darwin.exit(0)
                }
                source.resume()
                sources.append(source)
            }
            // a crashed app must not leave the port bound: its child is reparented to launchd
            let orphanable = getppid() != 1
            let watch = DispatchSource.makeTimerSource(queue: .main)
            watch.schedule(deadline: .now() + 2, repeating: 2)
            watch.setEventHandler {
                if orphanable, getppid() == 1 { Darwin.exit(0) }
                // a reset by hand leaves the printed code dead
                if case let .token(now) = MobilePairing.readToken(in: dir), !MobilePairing.sameSecret(now, token) {
                    FileHandle.standardError.write(Data("elisctl: \(PhoneRelayLine.pairingReset)\n".utf8))
                    relay.releaseAllGrids()
                    Darwin.exit(1)
                }
            }
            watch.resume()
            sources.append(watch)
            withExtendedLifetime((relay, radio, sources)) { dispatchMain() }
        }

        @Sendable static func bluetoothStatus(_ status: String) {
            FileHandle.standardError.write(Data("elisctl: bluetooth: \(status)\n".utf8))
        }
    }

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Revoke the pairing: write a new token, which disconnects every paired phone.")

        func run() throws {
            let dir = MobilePairing.directory(environment: ProcessInfo.processInfo.environment)
            do {
                try MobilePairing.ensurePrivateDirectory(dir)
                _ = try MobilePairing.loadToken(in: dir, fresh: true)
            } catch {
                FileHandle.standardError.write(Data("elisctl: \(error)\n".utf8))
                throw ExitCode.failure
            }
            print("Pairing revoked: paired phones are disconnected. Restart `elisctl mobile serve` for the new code.")
        }
    }
}

struct MobileError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - pairing

/// The pairing secret, the certificate the phone pins, and the link carrying both.
enum MobilePairing {
    static func directory(environment env: [String: String]) -> String {
        let state = env["ELIS_STATE_DIR"] ?? ControlResolve.defaultStateDirectory(environment: env)
        return (state as NSString).appendingPathComponent("mobile")
    }

    /// The directory holds the key and the token: refuse it unless only this user can enter it.
    static func ensurePrivateDirectory(_ dir: String) throws {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard chmod(dir, 0o700) == 0, stat(dir, &info) == 0, info.st_uid == getuid() else {
            throw MobileError("cannot make \(dir) private to you")
        }
    }

    /// Read on every request, so `mobile reset` cuts off phones holding the old token at once.
    static func currentToken(in dir: String) -> String? {
        if case let .token(token) = readToken(in: dir) { return token }
        return nil
    }

    enum TokenRead: Equatable {
        case token(String)
        /// Missing, unreadable or not a token: no phone holds a valid pairing.
        case absent
        /// A read error that says nothing about the file, such as running out of descriptors.
        case unavailable
    }

    static func readToken(in dir: String) -> TokenRead {
        let fd = open(dir + "/token", O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return isTransient(errno) ? .unavailable : .absent }
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = read(fd, &bytes, bytes.count)
        guard count >= 0 else { return isTransient(errno) ? .unavailable : .absent }
        let token = String(decoding: bytes[..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 32, token.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return .absent }
        return .token(token)
    }

    /// EACCES is not here: a token file nobody can read was changed on purpose, so it revokes.
    static func isTransient(_ code: Int32) -> Bool { [EMFILE, ENFILE, EINTR, EAGAIN].contains(code) }

    /// 32 random bytes, base64url without padding.
    static func loadToken(in dir: String, fresh: Bool = false) throws -> String {
        if !fresh, let token = currentToken(in: dir) { return token }
        var raw = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw) == errSecSuccess else { throw MobileError("no random bytes") }
        let token = Data(raw).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        try writePrivate(dir + "/token", Data((token + "\n").utf8))
        return token
    }

    /// Created owner-only and renamed into place, so a reader sees the old token or the new one, never a torn file.
    private static func writePrivate(_ path: String, _ data: Data) throws {
        let temporary = path + ".tmp"
        unlink(temporary)
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MobileError("cannot write \(path)") }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        close(fd)
        guard written == data.count, rename(temporary, path) == 0 else {
            unlink(temporary)
            throw MobileError("cannot write \(path)")
        }
    }

    /// A self-signed P-256 certificate; the phone pins its SHA-256 at pairing, so no CA is involved.
    static func ensureCertificate(in dir: String) throws {
        let cert = dir + "/cert.pem", key = dir + "/key.pem"
        if FileManager.default.fileExists(atPath: cert), FileManager.default.fileExists(atPath: key) { return }
        // CryptoKit makes the key: LibreSSL drops a leading zero byte of the scalar (about 1 key in 256), which
        // CryptoKit then refuses to read, and its default explicit EC parameters crash SecIdentityCreate
        try writePrivate(key, Data(P256.Signing.PrivateKey().pemRepresentation.utf8))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["req", "-x509", "-new", "-key", key, "-days", "3650", "-subj", "/CN=elis", "-out", cert]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            unlink(cert)
            unlink(key)
            throw MobileError("cannot create a certificate with openssl: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// The in-memory TLS identity and the lowercase hex SHA-256 of the certificate DER. Never touches the keychain.
    static func identity(in dir: String) throws -> (SecIdentity, String) {
        let unreadable = MobileError("the certificate in \(dir) is unreadable; delete cert.pem and key.pem to make a new one")
        guard let keyPEM = try? String(contentsOfFile: dir + "/key.pem", encoding: .utf8),
              let certPEM = try? String(contentsOfFile: dir + "/cert.pem", encoding: .utf8),
              let x963 = try? P256.Signing.PrivateKey(pemRepresentation: keyPEM).x963Representation else { throw unreadable }
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        let base64 = certPEM.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let key = SecKeyCreateWithData(x963 as CFData, attributes as CFDictionary, nil),
              let der = Data(base64Encoded: base64), let cert = SecCertificateCreateWithData(nil, der as CFData),
              // an explicit-parameter cert has no key here, and SecIdentityCreate raises an uncatchable exception on it
              SecCertificateCopyKey(cert) != nil,
              let identity = SecIdentityCreate(nil, cert, key) else { throw unreadable }
        return (identity, SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined())
    }

    static func sameSecret(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        var diff = UInt8(a.count == b.count ? 0 : 1)
        for i in 0..<max(a.count, b.count) {
            diff |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)
        }
        return diff == 0
    }

    /// `elis://pair?h=HOST&p=PORT&t=TOKEN&f=SHA256HEX&n=NAME[&b=1]`; a nil host leaves out `h` and `p`. Only unreserved
    /// characters pass unencoded: the phone decodes a bare `+` as a space.
    static func pairLink(host: String?, port: UInt16, token: String, fingerprint: String, name: String, bluetooth: Bool = false) -> String {
        var unreserved = CharacterSet.alphanumerics.intersection(.init(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        unreserved.insert(charactersIn: "-._~")
        let encode = { (value: String) in value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        let address = host.map { "h=\(encode($0))&p=\(port)&" } ?? ""
        return "elis://pair?\(address)t=\(encode(token))&f=\(encode(fingerprint))&n=\(encode(name))" + (bluetooth ? "&b=1" : "")
    }

    /// The short Bonjour name ("Nicks-MacBook"), which is what the phone lists the pairing under.
    static func hostName() -> String {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty { return name }
        let name = ProcessInfo.processInfo.hostName
        return name.hasSuffix(".local") ? String(name.dropLast(6)) : name
    }

    /// Up, non-loopback, non-link-local IPv4 addresses; the first one goes in the QR code.
    static func lanAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var found: [(name: String, address: String)] = []
        for entry in sequence(first: head, next: { $0?.pointee.ifa_next }) {
            guard let entry, entry.pointee.ifa_flags & UInt32(IFF_UP) != 0, let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            inet_ntop(AF_INET, &sin.sin_addr, &host, socklen_t(host.count))
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if address.hasPrefix("127.") || address.hasPrefix("169.254.") { continue }
            found.append((String(cString: entry.pointee.ifa_name), address))
        }
        return orderedLAN(found)
    }

    /// Container and VM bridges and VPN tunnels go after physical interfaces; duplicates keep their first place.
    static func orderedLAN(_ interfaces: [(name: String, address: String)]) -> [String] {
        let virtual = ["bridge", "vmnet", "utun", "vboxnet"]
        let isVirtual = { (name: String) in virtual.contains { name.hasPrefix($0) } }
        var seen = Set<String>()
        return (interfaces.filter { !isVirtual($0.name) } + interfaces.filter { isVirtual($0.name) })
            .map(\.address).filter { seen.insert($0).inserted }
    }

    /// The QR modules, top row first, without a quiet zone.
    static func qrMatrix(_ text: String) throws -> [[Bool]] {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw MobileError("no QR generator") }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { throw MobileError("cannot encode the link as a QR code") }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        var pixels = [UInt8](repeating: 255, count: width * height)
        CIContext(options: [.useSoftwareRenderer: true])
            .render(image, toBitmap: &pixels, rowBytes: width, bounds: extent, format: .L8, colorSpace: nil)
        let rows = (0..<height).map { y in (0..<width).map { pixels[y * width + $0] < 128 } }
        // the generator adds its own margin; the finder patterns make the first and last rows and columns dark
        let used = rows.indices.filter { rows[$0].contains(true) }
        let columns = (0..<width).filter { x in rows.contains { $0[x] } }
        guard let top = used.first, let bottom = used.last, let left = columns.first, let right = columns.last else {
            throw MobileError("empty QR code")
        }
        return rows[top...bottom].map { Array($0[left...right]) }
    }

    /// Half-block rows with explicit black and white, so the code scans on dark and light themes alike.
    static func qrRows(_ matrix: [[Bool]]) -> [String] {
        let border = 2, size = matrix.count, span = size + 2 * border
        let dark = { (x: Int, y: Int) -> Bool in
            let row = y - border, column = x - border
            return row >= 0 && row < size && column >= 0 && column < size && matrix[row][column]
        }
        return stride(from: 0, to: span, by: 2).map { y in
            (0..<span).map { x in "\u{1b}[\(dark(x, y) ? 30 : 97);\(dark(x, y + 1) ? 40 : 107)m▀" }.joined() + "\u{1b}[0m"
        }
    }
}

// MARK: - relay

/// The phones of every transport, and the TLS listener that produces one kind of them. Every mutable property
/// is touched on `queue` only.
final class MobileRelay: @unchecked Sendable {
    /// Connections still owing their token, on any transport; past it the oldest is dropped, so a flood cannot
    /// use up descriptors.
    private let maxUnauthenticated: Int

    var onFailure: (@Sendable () -> Void)?
    let queue = DispatchQueue(label: "elisctl.mobile")
    private let parameters: NWParameters
    private let port: UInt16
    private let bind: String?
    let settings: PhoneSession.Settings
    private let releaseTimeout: TimeInterval
    private var listener: NWListener?
    private var phones: [ObjectIdentifier: PhoneSession] = [:]
    private var accepted = 0

    init(identity: SecIdentity, port: UInt16, bind: String?, mobileDir: String, socketPath: String, hostName: String,
         authTimeout: TimeInterval = 10, revokeInterval: TimeInterval = 5, maxUnauthenticated: Int = 32,
         releaseTimeout: TimeInterval = 3,
         log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data("elisctl: \($0)\n".utf8)) }) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true // a phone that vanished without a FIN is dropped
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        parameters = NWParameters(tls: tls, tcp: tcp)
        self.port = port
        self.bind = bind
        settings = PhoneSession.Settings(mobileDir: mobileDir, socketPath: socketPath, hostName: hostName,
                                         authTimeout: authTimeout, revokeInterval: revokeInterval, log: log)
        self.releaseTimeout = releaseTimeout
        self.maxUnauthenticated = maxUnauthenticated
    }

    /// Listen and return the bound port once the listener is ready; a port in use throws.
    func start() throws -> UInt16 {
        let listenPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener: NWListener
        if let bind {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bind), port: listenPort)
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: parameters, on: listenPort)
        }
        let settled = DispatchSemaphore(value: 0)
        let failure = FailureBox()
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                failure.set(nil)
                settled.signal()
            case let .failed(error), let .waiting(error):
                if failure.set("cannot listen on \(self?.bind ?? "*"):\(self?.port ?? 0): \(error)") {
                    settled.signal()
                } else {
                    self?.settings.log("listener failed: \(error)")
                    self?.onFailure?()
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            accept(TLSPhoneConnection(connection, queue: queue))
        }
        queue.sync { self.listener = listener }
        listener.start(queue: queue)
        if settled.wait(timeout: .now() + 10) == .timedOut { failure.set("listener did not start") }
        if let message = failure.message {
            listener.cancel()
            throw MobileError(message)
        }
        return listener.port?.rawValue ?? port
    }

    func stop() {
        queue.sync {
            listener?.stateUpdateHandler = nil
            listener?.cancel()
            phones.values.forEach { $0.close() }
        }
    }

    /// Serves a phone from any transport. Call on `queue`; the connection delivers there too.
    func accept(_ connection: any PhoneTransportConnection) {
        // evicting the oldest, not refusing the newest, so a flood cannot lock a paired phone out
        let waiting = phones.values.filter { !$0.authenticated }
        if waiting.count >= maxUnauthenticated, let oldest = waiting.min(by: { $0.order < $1.order }) { oldest.close() }
        accepted += 1
        let phone = PhoneSession(connection, order: accepted, queue: queue, settings: settings) { [weak self] in
            self?.phones[ObjectIdentifier($0)] = nil
        }
        phones[ObjectIdentifier(phone)] = phone
        phone.start()
    }

    /// Authenticated phones whose connection `matches`. Call on `queue`.
    func authenticatedPhones(_ matches: (any PhoneTransportConnection) -> Bool) -> Int {
        phones.values.filter { $0.authenticated && matches($0.connection) }.count
    }

    /// Resets every grid every phone forced, waiting up to `releaseTimeout` for the app; for a relay told to stop.
    func releaseAllGrids() {
        let resets = queue.sync { phones.values.flatMap { $0.takeResets() } }
        let group = DispatchGroup()
        let socketPath = settings.socketPath
        for reset in resets {
            DispatchQueue.global().async(group: group) { _ = try? SocketClient(path: socketPath).sendRaw(reset) }
        }
        _ = group.wait(timeout: .now() + releaseTimeout)
    }

    /// A dual-stack listener reports IPv4 peers as `::ffff:a.b.c.d`; print the plain address without a scope.
    static func peerAddress(_ endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "\(endpoint)" }
        let text: String
        switch host {
        case let .ipv6(address): text = address.asIPv4.map { "\($0)" } ?? "\(address)"
        default: text = "\(host)"
        }
        return String(text.prefix { $0 != "%" })
    }
}

/// A TLS phone, started on the relay queue at accept so every callback lands there.
private final class TLSPhoneConnection: PhoneTransportConnection, @unchecked Sendable {
    let peerLabel: String
    var onReceive: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private let connection: NWConnection

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        peerLabel = MobileRelay.peerAddress(connection.endpoint)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.onClose?()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, let onReceive else { return }
            if let data { onReceive(data) }
            if done || error != nil { onClose?() } else if self.onReceive != nil { receive() }
        }
    }

    func send(_ data: Data, completion: @escaping () -> Void) {
        connection.send(content: data, completion: .contentProcessed { _ in completion() })
    }

    func close() { connection.cancel() }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private(set) var message: String?

    /// Records the first outcome, nil for ready; false once start has already settled.
    @discardableResult
    func set(_ message: String?) -> Bool {
        lock.withLock {
            guard !settled else { return false }
            settled = true
            self.message = message
            return true
        }
    }
}
#endif
