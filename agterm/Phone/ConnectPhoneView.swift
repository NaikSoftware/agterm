import agtermCore
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// App ▸ Connect a Phone…: switches the relay on and shows its pairing code.
struct ConnectPhoneView: View {
    let relay: PhoneRelay
    @State private var hostField = ""
    @State private var portField = ""
    @State private var confirmRevoke = false
    @FocusState private var portFocused: Bool

    private var listening: Bool { relay.link != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Let agterm Mobile connect to this Mac", isOn: Binding(get: { relay.state.on }, set: relay.setOn))
                .toggleStyle(.switch)
            code
                .frame(maxWidth: .infinity)
            Form {
                HStack {
                    TextField("Address", text: $hostField, prompt: Text(relay.offeredHosts.first ?? "Best guess"))
                        .onChange(of: hostField) { _, host in relay.setHost(host) }
                    Menu {
                        ForEach(relay.offeredHosts, id: \.self) { host in
                            Button(host) { hostField = host }
                        }
                    } label: { Image(systemName: "network") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(relay.offeredHosts.isEmpty)
                        .help("Addresses this Mac has; type a VPN name such as a Tailscale host instead")
                }
                TextField("Port", text: $portField)
                    .focused($portFocused)
                    .onSubmit { commitPort() }
                    .onChange(of: portFocused) { _, focused in if !focused { commitPort() } }
                    .frame(width: 160)
            }
            HStack {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(relay.error == nil ? Color.secondary : Color.red)
                    .textSelection(.enabled)
                Spacer()
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(relay.link ?? "", forType: .string)
                }
                .disabled(!listening)
            }
            if let notice = relay.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Anyone with this code controls this Mac's terminals until you revoke it.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Revoke Paired Phones…") { confirmRevoke = true }
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            hostField = relay.state.host
            portField = String(relay.state.port)
        }
        .onChange(of: relay.state.port) { _, port in portField = String(port) }
        .confirmationDialog("Revoke paired phones?", isPresented: $confirmRevoke) {
            Button("Revoke", role: .destructive) { Task { await relay.revoke() } }
        } message: {
            Text("Every paired phone is disconnected and must scan the new code.")
        }
        .background(NonRestorableWindow())
    }

    @ViewBuilder private var code: some View {
        if let link = relay.link, let image = Self.qrImage(link) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 240, height: 240)
                .padding(16) // the quiet zone scanners need, white in either appearance
                .background(Color.white)
                .accessibilityLabel("Pairing code")
        } else {
            Text(relay.state.on ? (relay.error == nil ? "Starting…" : "Not listening") : "Phone access is off.")
                .foregroundStyle(.secondary)
                .frame(width: 272, height: 272)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        }
    }

    private var status: String {
        if let error = relay.error { return "Not listening: \(error)" }
        let last = relay.lastEvent.map { "Last: \($0)." } ?? ""
        return listening ? "Listening on port \(relay.state.port). " + last : last
    }

    private func commitPort() {
        guard let port = Int(portField.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(port) else {
            portField = String(relay.state.port)
            return
        }
        relay.setPort(port)
    }

    /// Black modules on white, scaled up here with nearest-neighbour sampling: SwiftUI's scaling blurs the edges.
    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage?.samplingNearest().transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: output.extent.size)
    }
}
