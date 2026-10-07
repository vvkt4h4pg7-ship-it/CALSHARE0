import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        TabView {
            PhoneView()
                .tabItem { Label("CALL", systemImage: "phone.fill") }

            DiagnosticsView()
                .tabItem { Label("LOG", systemImage: "waveform.path.ecg") }

            SettingsView()
                .tabItem { Label("SETTINGS", systemImage: "gearshape") }
        }
        .tint(.green)
        .onAppear { app.start() }
    }
}

struct PhoneView: View {
    @EnvironmentObject var app: AppModel

    private let keys = ["1","2","3","4","5","6","7","8","9","*","0","#"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    connectionCard
                    callCard
                    numberField
                    keypad
                    actions
                }
                .padding()
            }
            .navigationTitle("CALLSHARE")
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(app.bleStatus, systemImage: app.bleStatus == "Connected" || app.bleStatus == "GATT Ready"
                      ? "dot.radiowaves.left.and.right"
                      : "antenna.radiowaves.left.and.right")
                Spacer()
                Text(app.deviceName)
                    .foregroundStyle(.secondary)
            }
            Button("Disconnect / Rescan") {
                app.restartBLE()
            }
            .font(.footnote)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var callCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CALL").bold()
                Spacer()
                Text(app.callStatus)
            }
            HStack {
                Text("VOICE").bold()
                Spacer()
                Text(app.voiceStatus)
                    .foregroundStyle(.secondary)
            }
            if !app.callerName.isEmpty {
                HStack {
                    Text("Caller").bold()
                    Spacer()
                    Text(app.callerName)
                }
            }
            if !app.number.isEmpty {
                HStack {
                    Text("Number").bold()
                    Spacer()
                    Text(app.number)
                        .font(.footnote)
                }
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var numberField: some View {
        HStack {
            Text(app.dialString.isEmpty ? "Enter number" : app.dialString)
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
            if !app.dialString.isEmpty && app.callStatus == "IDLE" {
                Button {
                    app.backspace()
                } label: {
                    Image(systemName: "delete.left")
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private var keypad: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            ForEach(keys, id: \.self) { key in
                Button(key) { app.tap(key) }
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(.thinMaterial, in: Circle())
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 18) {
            if app.callStatus == "IDLE" {
                Button {
                    app.makeCall()
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.title2)
                        .frame(width: 76, height: 58)
                }
                .buttonStyle(.borderedProminent)
                .disabled(app.dialString.isEmpty || app.bleStatus == "Disconnected")
            } else {
                Button(role: .destructive) {
                    app.endCall()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.title2)
                        .frame(width: 76, height: 58)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(app.logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Diagnostics")
            .toolbar {
                Button("Clear") { app.clearLog() }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("GATT") {
                    LabeledContent("Service", value: K7Protocol.service.uuidString)
                    LabeledContent("RX", value: K7Protocol.rx.uuidString)
                    LabeledContent("FLOW", value: K7Protocol.flow.uuidString)
                    LabeledContent("TX", value: K7Protocol.tx.uuidString)
                }

                Section("Call") {
                    Picker("SIM slot", selection: $app.simSlot) {
                        Text("SIM 1").tag(0)
                        Text("SIM 2").tag(1)
                    }
                }

                Section("Audio") {
                    Toggle("Speaker default", isOn: $app.speakerDefault)
                        .onChange(of: app.speakerDefault) { newValue in
                            app.audio.setSpeakerDefault(newValue)
                        }
                    Text("Audio TX stays blocked until the K7 VOICE_OPEN (0F) event arrives.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Protocol") {
                    Text("Control channel: 0x12")
                    Text("Audio channel: 0x03")
                    Text("VOICE_OPEN: 0x0F")
                    Text("VOICE_CLOSE: 0x10")
                    Text("AMR-NB: 8 kHz / mono / 160 PCM samples")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
