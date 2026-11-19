import NearsideCore
import SwiftUI

/// One-time pairing, done from the phone's "Pair device with pairing code" screen.
struct SetupView: View {
    let engine: SyncEngine
    @State private var hostPort = ""
    @State private var code = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect your Android phone")
                        .font(.title3.weight(.semibold))
                    Text("A one-time setup. Afterwards everything syncs on its own, even after reboots.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Instruction(number: 1, text: "On your phone, open **Settings → About phone** and tap **Build number** 7 times.")
                    Instruction(number: 2, text: "Open **Settings → System → Developer options → Wireless debugging**, turn it on and allow this Wi-Fi network.")
                    Instruction(number: 3, text: "Tap **Pair device with pairing code** and type what it shows below.")
                }

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

                if !engine.setupSteps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(engine.setupSteps) { StepRow(step: $0) }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Label("Keep your phone and Mac on the same Wi-Fi.", systemImage: "wifi")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
    }
}

private struct Instruction: View {
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
