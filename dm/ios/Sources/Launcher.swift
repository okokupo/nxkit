// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json (an app of several programs: dm/p<N>/launcher.json), which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. All settings share one screen, grouped by section (rows: LauncherRow.swift). Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults shows the defaults, and Play then forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once with the saved choices; DM_SAVED_CHOICES=0 ignores them (and keeps them)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CoreBluetooth
import os

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }


/// Cloud saves: an iCloud Drive folder shared with the Mac app (chosen in its settings window's
/// Cloud saves too). The host brings the save in from there when the game starts and
/// sends it there after each save (dm/host/save_sync.h); the folder is a bookmark (CloudSaves.m).
private struct CloudSavesSection: View {
    @State private var folder: String = ""
    @State private var note: String = ""
    @State private var picking = false

    var body: some View {
        Section {
            HStack {
                Text("Cloud saves")
                Spacer()
                Text(folder.isEmpty ? "Off" : (folder as NSString).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Button(folder.isEmpty ? "Choose a folder in iCloud Drive…" : "Choose a different folder…") { picking = true }
                // The sheet sits on the button, not on the Section: SwiftUI hands a Section's modifiers to every row, so one tap presented a picker per row and they invalidated each other (LNPANDY/NX2Apple#315).
                .sheet(isPresented: $picking) {
                    DocumentPicker(types: [.folder]) { url in
                        picking = false
                        if dm_store_cloud_saves(url) {
                            note = "Saved. The game uses this folder when you press Play."
                            refresh()
                        } else {
                            note = "That folder could not be remembered — try a different one."
                        }
                    } onCancel: { picking = false }
                }
            if !folder.isEmpty {
                Button("Turn off cloud saves", role: .destructive) {
                    dm_clear_cloud_saves(); refresh(); note = ""
                }
            }
        } footer: {
            Text(note.isEmpty
                 ? "Choose a folder in iCloud Drive, and the same one in the Mac app's Cloud saves. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in save-backups."
                 : note)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        var stale: ObjCBool = false
        folder = dm_cloud_saves_path(&stale) ?? ""
        if stale.boolValue && folder.isEmpty {
            note = "The folder you chose before is no longer readable (the app was signed differently). Please choose it again."
        }
    }
}

/// UIDocumentPickerViewController for a folder, in the two callbacks a SwiftUI sheet wants.
private struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.folder]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .open (not .import): the folder stays where it is and the bookmark keeps pointing at it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @State private var memory = os_proc_available_memory()

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 16) {
                    if let icon = appIcon() {
                        Image(uiImage: icon).resizable().frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .accessibilityHidden(true)
                    }
                    Text((info("CFBundleDisplayName") as? String) ?? "Game")
                        .font(.title.weight(.bold)).multilineTextAlignment(.center)
                    Text("Version \((info("CFBundleShortVersionString") as? String) ?? "")")
                        .font(.callout).foregroundStyle(.secondary)
                    playButton
                }
                .padding(16)
                .frame(width: geometry.size.width / 3, height: geometry.size.height)
                List {
                    ForEach(m.sections, id: \.self) { section in
                        let rows = m.rows(in: section)
                        if !rows.isEmpty {
                            Section(section) {
                                ForEach(rows) { SettingRow(s: $0, m: m) }
                            }
                        }
                    }
                    Section {
                        Button("Reset to tested defaults") { m.reset() }
                            .disabled(!m.changed)
                    } footer: {
                        Text("Brings back all settings this game was tested with.")
                    }
                    CloudSavesSection()
                    Switch2TestSection()
                    Section {
                        HStack {
                            Text("Memory available")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .contentMargins(.horizontal, 12, for: .scrollContent)
                .frame(width: geometry.size.width * 2 / 3)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { applySw2HostEnv(); dm_switch2_ensure_started() }   // scanning runs from the launcher: a pad pairs before the game starts; the saved wake address must be in the env before the transport starts
        .task {
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder var playButton: some View {
        let button = Button(action: play) { Text("Play").font(.title3.weight(.semibold)).frame(maxWidth: 220) }.controlSize(.large)
        if #available(iOS 26.0, *) { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
    }

    private func appIcon() -> UIImage? {
        if let i = UIImage(named: "AppIcon") { return i }
        guard let icons = info("CFBundleIcons") as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last)
    }
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    // a game of several programs (main.m): the running program's settings, in its dm/p<N>
    let dir = getenv("DM_APP_DM").map { URL(fileURLWithPath: String(cString: $0)) } ?? Bundle.main.resourceURL?.appendingPathComponent("dm")
    guard let url = dir?.appendingPathComponent("launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    let model = LauncherModel(file.settings)
    gameMenuModel = model   // the in-game menu shows and saves the same choices (GameMenu.swift)
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); model.applySaved(); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    var host: UIViewController?
    let view = LauncherView(m: model) {
        guard let h = host else { return }
        host = nil
        model.apply()
        h.dismiss(animated: false) { done() }
    }
    let h = DmHostingController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}

// ---- Switch 2 controller test view (Chen's request 2026-11-12): live button/stick echo without entering the game ----
// Reads the transport through the flat C snapshot (dm_switch2_test_rows): one card per pad, every
// raw button bit highlighted while held, the back paddles GL/GR in their own row, sticks as raw counts.
// Advertises this device so an Android nRF Connect scan can read this iPad's Bluetooth address: iOS hides it from itself, but the pad's wake advert targets the address it stored, so the iPad can only hear its own wake when that address is its real one
private final class HostAdvertBox: NSObject, CBPeripheralManagerDelegate {
    static let shared = HostAdvertBox()
    private let pm = CBPeripheralManager()
    private var want = false
    private(set) var status = "未启动"
    private let uuid = CBUUID(string: "F5EA0001-5EA0-4C6E-9A1B-2B6E0A88A0F5")   // a service in the packet keeps the advert real and easy to spot in nRF
    func start() { want = true; pm.delegate = self }
    func stop() { want = false; status = "已停"; if pm.state == .poweredOn { pm.stopAdvertising() } }
    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        switch p.state {
        case .poweredOn:
            status = want ? "启动中…" : "蓝牙就绪"
            if want { p.startAdvertising([CBAdvertisementDataLocalNameKey: "DmIOS-host", CBAdvertisementDataServiceUUIDsKey: [uuid]]) }
        case .unauthorized: status = "❌ 蓝牙权限被拒（设置里给这个 App 开蓝牙）"
        case .poweredOff: status = "❌ 蓝牙关闭"
        case .unsupported: status = "❌ 此设备不支持外设广播"
        default: status = "等待蓝牙就绪…"
        }
    }
    func peripheralManager(_ p: CBPeripheralManager, didStartAdvertising error: Error?) {
        status = error == nil ? "广播中（DmIOS-host）" : "❌ 广播失败：\(error!.localizedDescription)"
    }
}

// Saved wake address → env, before the transport starts (pad_switch2_apple.m parses DM_SW2_HOST once at start; it beats the iOS sentinel)
private func applySw2HostEnv() {
    if let h = UserDefaults.standard.string(forKey: "launcher.DM_SW2_HOST"), !h.isEmpty { setenv("DM_SW2_HOST", h, 1) }
}

private struct Switch2TestView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tick = 0
    @State private var hostField = ""
    // (label, mask) in reading order; masks from switch2_proto.h, spelled as literals so no C enum import is needed
    static let keys: [(String, UInt32)] = [
        ("Y", 0x1), ("X", 0x2), ("B", 0x4), ("A", 0x8),
        ("L", 0x400000), ("R", 0x40), ("ZL", 0x800000), ("ZR", 0x80),
        ("+", 0x200), ("−", 0x100), ("LS", 0x800), ("RS", 0x400),
        ("↑", 0x20000), ("↓", 0x10000), ("←", 0x80000), ("→", 0x40000),
        ("C", 0x4000), ("HOME", 0x1000), ("截屏", 0x2000),
        ("SL·L", 0x200000), ("SR·L", 0x100000), ("SR·R", 0x10), ("SL·R", 0x20),
        ("左背键 GL", 0x2000000), ("右背键 GR", 0x1000000),
    ]

    var body: some View {
        List {
            Section("Bonding 诊断") {
                let st = tick >= 0 ? String(cString: dm_switch2_bond_status()) : ""
                Text(st.isEmpty ? "no bond attempt yet" : st).font(.caption.monospaced()).foregroundStyle(.secondary)
                let fs = tick >= 0 ? String(cString: dm_switch2_flash_status()) : ""
                Text(fs).font(.caption.monospaced()).foregroundStyle(.secondary)
                let ix = tick >= 0 ? String(cString: dm_switch2_info_status()) : ""
                Text(ix.isEmpty ? "Info 区未读" : ix).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Section(footer: Text("此页打开时本机自动广播为 DmIOS-host：用安卓 nRF Connect 扫描，抄下它的蓝牙地址填进来。iOS 隐藏本机地址，而手柄唤醒广播只发给它存的地址——填真实地址本机才能收到。应用后：按住 Sync 重配对 → 杀App重开 → 按任意键。")) {
                Text("本机广播：" + HostAdvertBox.shared.status).font(.caption.monospaced()).foregroundStyle(.secondary)
                HStack {
                    TextField("aa:bb:cc:dd:ee:ff", text: $hostField)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("应用") {
                        let a = hostField.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !a.isEmpty else { return }
                        UserDefaults.standard.set(a, forKey: "launcher.DM_SW2_HOST")
                        setenv("DM_SW2_HOST", a, 1)
                        dm_switch2_set_host(a)
                    }
                }
                Button("测试震动（先连上手柄）") { dm_switch2_rumble_test() }
            }
            if pods().isEmpty {
                Section(footer: Text("启动器已开启扫描。按住 Pro 2 顶部 Sync 键直到灯效扫动；连上后此页实时点亮。")) {
                    Text("未检测到 Switch 2 手柄").foregroundStyle(.secondary)
                }
            }
            ForEach(Array(pods().enumerated()), id: \.offset) { i, pad in
                Section("手柄 \(i + 1) · \(pad.name) · 电量 \(pad.battery)mV · 掩码 \(String(format: "0x%08x", pad.buttons))") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                        ForEach(Self.keys, id: \.0) { key in
                            let on = pad.buttons & key.1 != 0
                            Text(key.0)
                                .font(.caption.weight(.semibold)).monospacedDigit()
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(on ? AnyShapeStyle(.green.opacity(0.8)) : AnyShapeStyle(.gray.opacity(0.2)))
                                .foregroundStyle(on ? .black : .primary)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    HStack {
                        stickView("L", pad.lx, pad.ly); Spacer(); stickView("R", pad.rx, pad.ry)
                    }
                }
            }
        }
        .navigationTitle("手柄测试").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        .onAppear {
            applySw2HostEnv()
            hostField = UserDefaults.standard.string(forKey: "launcher.DM_SW2_HOST") ?? ""
            HostAdvertBox.shared.start()
            dm_switch2_ensure_started()   // opened before the transport started: start it now
        }
        .onDisappear { HostAdvertBox.shared.stop() }
        .task {
            while !Task.isCancelled { tick += 1; try? await Task.sleep(for: .milliseconds(100)) }
        }
    }

    private func stickView(_ label: String, _ x: UInt16, _ y: UInt16) -> some View {
        let dx = Double(Int(x) - 2048) / 1700, dy = Double(Int(y) - 2048) / 1700
        let cx = min(max(dx, -1), 1) * 14, cy = -min(max(dy, -1), 1) * 14
        return VStack(spacing: 4) {
            Circle().frame(width: 44, height: 44).foregroundStyle(.gray.opacity(0.15))
                .overlay { Circle().frame(width: 16, height: 16).foregroundStyle(.blue).offset(x: cx, y: cy) }
            Text("\(label) \(Int(x))·\(Int(y))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 96)
        }
    }

    // One row per pad via the C flat snapshot (dm_switch2_test_rows): Swift cannot touch the transport's structs directly
    private func pods() -> [(name: String, buttons: UInt32, lx: UInt16, ly: UInt16, rx: UInt16, ry: UInt16, battery: UInt16)] {
        guard tick >= 0 else { return [] }   // depend on tick so SwiftUI re-reads every poll
        var rows = (0..<8).map { _ in dm_s2_test_row(pid: 0, buttons: 0, lx: 0, ly: 0, rx: 0, ry: 0, battery_mv: 0) }
        let n = dm_switch2_test_rows(&rows, Int32(rows.count))
        return rows.prefix(Int(n)).map { r in (name(r.pid), r.buttons, r.lx, r.ly, r.rx, r.ry, r.battery_mv) }
    }

    private func name(_ pid: UInt32) -> String {
        switch pid {
        case 0x2069: return "Pro Controller 2"
        case 0x2066: return "Joy-Con 2 右"
        case 0x2067: return "Joy-Con 2 左"
        case 0x2073: return "NSO GameCube"
        default: return String(format: "0x%04x", pid)
        }
    }
}

private struct Switch2TestSection: View {
    @State private var testing = false
    var body: some View {
        Section {
            Button("Switch 2 手柄测试") { testing = true }
        } footer: {
            Text("免进游戏：实时点亮每个按键、摇杆和背键（GL/GR）。")
        }
        .sheet(isPresented: $testing) { NavigationStack { Switch2TestView() } }
    }
}
