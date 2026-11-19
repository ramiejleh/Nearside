import NearsideCore
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The wizard's pairing page. Scanning a QR code is the default; typing a code is the fallback.
struct PairingView: View {
    let engine: SyncEngine
    @State private var useCode = false
    @State private var hostPort = ""
    @State private var code = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Instruction(number: 1, text: useCode
                    ? "In **Wireless debugging**, tap **Pair device with pairing code** and type what it shows below."
                    : "In **Wireless debugging**, tap **Pair device with QR code** and scan this code with the scanner that opens. (The Camera app can't read it.)")

                if useCode {
                    codeForm
                } else {
                    qrCard
                }

                if !engine.setupSteps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(engine.setupSteps) { StepRow(step: $0) }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                HStack {
                    Label("Keep your phone and Mac on the same Wi-Fi.", systemImage: "wifi")
                    Spacer()
                    Button(useCode ? "Scan a QR code instead" : "Use a pairing code") {
                        withAnimation(.snappy(duration: 0.2)) { useCode.toggle() }
                    }
                    .buttonStyle(.link)
                    .disabled(engine.isPairing)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        // Listen for a scan only while this screen is up.
        .onAppear { engine.startQRPairing() }
        .onDisappear { engine.stopQRPairing() }
    }

    private var qrCard: some View {
        VStack(spacing: 10) {
            ZStack {
                if let pairing = engine.qrPairing {
                    QRCodeImage(payload: pairing.payload)
                        .opacity(engine.isPairing ? 0.15 : 1)
                        .id(pairing.payload)
                        .transition(.opacity)
                }
                if engine.isPairing {
                    ProgressView()
                }
            }
            .frame(width: 168, height: 168)
            .padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)

            HStack(spacing: 6) {
                if engine.isPairing {
                    Text("Phone found, setting up…")
                } else {
                    ProgressView().controlSize(.mini)
                    Text("Waiting for your phone to scan…")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: engine.isPairing)
    }

    @ViewBuilder private var codeForm: some View {
        VStack(spacing: 8) {
            LabeledField(label: "IP address & port", placeholder: "192.168.0.12:37123", text: $hostPort)
            LabeledField(label: "Pairing code", placeholder: "123456", text: $code)
        }
        .disabled(engine.isPairing)

        Button {
            engine.pair(hostPort: hostPort, code: code)
        } label: {
            HStack {
                if engine.isPairing { ProgressView().controlSize(.small) }
                Text(engine.isPairing ? "Setting up…" : "Pair and Set Up")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .controlSize(.large)
        .disabled(engine.isPairing || !hostPort.contains(":") || code.trimmingCharacters(in: .whitespaces).count < 6)
        .keyboardShortcut(.defaultAction)
    }
}

/// Crisp, black-on-white QR code rendered with Core Image.
private struct QRCodeImage: View {
    let payload: String

    var body: some View {
        if let image = Self.render(payload) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("Pairing QR code")
        }
    }

    private static func render(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: output.extent.size)
    }
}

struct Instruction: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.green)
                .frame(width: 20, height: 20)
                .background(Color.green.opacity(0.15), in: Circle())
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LabeledField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }
}

private struct StepRow: View {
    let step: SyncEngine.SetupStep

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch step.status {
                case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                case .running: ProgressView().controlSize(.mini)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.callout)
                    .foregroundStyle(step.status == .pending ? .secondary : .primary)
                if case .failed(let message) = step.status {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
