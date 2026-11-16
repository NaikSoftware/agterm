#if os(macOS)
import ArgumentParser
import agtermCore
import Foundation

/// `agtermctl phone`: the app's Connect a Phone relay over the socket. macOS-only beside `mobile`, whose QR it prints.
struct Phone: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Turn the app's phone relay on or off, set its port and address, revoke paired phones, or print the link.",
        subcommands: [Status.self, Enable.self, Off.self, Toggle.self, Port.self, Host.self, Revoke.self, Link.self]
    )

    struct Status: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Show whether the relay is on and listening, its port, address and last event.")
        @OptionGroup var options: BasicOptions
        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .phoneStatus) }
    }

    struct Enable: RequestCommand {
        static let configuration = CommandConfiguration(commandName: "on", abstract: "Start the relay; answers once it listens or fails.")
        @OptionGroup var options: BasicOptions
        func makeRequest() throws -> ControlRequest { enable("on") }
    }

    struct Off: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the relay.")
        @OptionGroup var options: BasicOptions
        func makeRequest() throws -> ControlRequest { enable("off") }
    }

    struct Toggle: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Turn the relay on when off, off when on.")
        @OptionGroup var options: BasicOptions
        func makeRequest() throws -> ControlRequest { enable("toggle") }
    }

    struct Port: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Set the port the relay listens on (default 8765); restarts it when on.")
        @Argument(help: "The port, 1...65535.") var port: Int
        @OptionGroup var options: BasicOptions

        func validate() throws {
            guard (1...65535).contains(port) else { throw ValidationError("port must be 1...65535") }
        }

        func makeRequest() throws -> ControlRequest {
            var args = ControlArgs()
            args.port = port
            return ControlRequest(cmd: .phonePort, args: args)
        }
    }

    struct Host: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set the address the link names, or --auto to follow the relay's best address.")
        @Argument(help: "An address the phone reaches this Mac at.") var host: String?
        @Flag(name: .long, help: "Follow the relay's best address.") var auto = false
        @OptionGroup var options: BasicOptions

        func validate() throws {
            guard (host == nil) == auto else { throw ValidationError("provide a host or --auto") }
        }

        func makeRequest() throws -> ControlRequest {
            var args = ControlArgs()
            if auto { args.auto = true } else { args.host = host }
            return ControlRequest(cmd: .phoneHost, args: args)
        }
    }

    struct Revoke: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Cut every paired phone off with a new pairing code; restarts the relay when on.")
        @OptionGroup var options: BasicOptions
        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .phoneRevoke) }
    }

    struct Link: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the pairing link, or with --qr its code above it. Anyone with the link controls your terminals.")
        @Flag(name: .long, help: "Print the code to scan above the link.") var qr = false
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .phoneStatus) }

        func run() throws {
            if options.json { return try defaultRun() }
            let reply = try SocketClient(path: options.socketPath()).send(makeRequest())
            guard reply.response.ok, let status = reply.response.result?.phone else {
                SocketClient.printResponse(reply, json: false)
                throw ExitCode.failure
            }
            do {
                print(try Self.render(status, qr: qr))
            } catch {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                throw ExitCode.failure
            }
        }

        static func render(_ status: ControlPhoneStatus, qr: Bool) throws -> String {
            guard let link = status.link else {
                throw MobileError(status.on ? status.error ?? "the relay is not listening yet" : "phone access is off")
            }
            guard qr else { return link }
            return (MobilePairing.qrRows(try MobilePairing.qrMatrix(link)) + [link]).joined(separator: "\n")
        }
    }
}

private func enable(_ mode: String) -> ControlRequest {
    var args = ControlArgs()
    args.mode = mode
    return ControlRequest(cmd: .phoneEnable, args: args)
}
#endif
