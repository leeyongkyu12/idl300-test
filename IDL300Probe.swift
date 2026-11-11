import SwiftUI
import CoreBluetooth
import Combine
import UniformTypeIdentifiers

@main
struct IDL300ProbeApp: App {
    var body: some Scene { WindowGroup { ProbeView() } }
}

struct Device: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
    var services: [String]
    var connectable: Bool
}

// All CoreBluetooth callbacks and published state run on the main queue.
final class BluetoothProbe: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let keyweService = CBUUID(string: "50910001-C567-11E5-8822-0002A5D5C51B")
    @Published var serviceMatch = false
    @Published var devices: [Device] = []
    @Published var status = "블루투스 준비 중"
    @Published var ready = false
    @Published var scanning = false
    @Published var activeID: UUID?
    @Published var details: [String] = []
    @Published var reportURL: URL?
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var active: CBPeripheral?
    private var scanTimer: Timer?
    private var connectionTimer: Timer?
    private var pendingServices = 0
    private var discoveryFailed = false
    private var events: [String] = []

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }
    private func log(_ message: String) {
        events.append("\(ISO8601DateFormatter().string(from: Date()))  \(message)")
        if events.count > 1000 { events.removeFirst(events.count - 1000) }
        reportURL = nil
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        ready = central.state == .poweredOn
        switch central.state {
        case .poweredOn: status = "검색할 준비가 됐어요"
        case .poweredOff: status = "아이폰 설정에서 블루투스를 켜주세요"
        case .unauthorized: status = "설정 → 개인정보 보호 및 보안 → Bluetooth에서 접근을 허용해주세요"
        case .unsupported: status = "실제 아이폰에서 실행해주세요"
        case .resetting: status = "블루투스를 다시 준비하고 있어요"
        default: status = "블루투스 상태 확인 중"
        }
        if !ready {
            stopScan()
            connectionTimer?.invalidate()
            active = nil
            activeID = nil
        }
        log(status)
    }
    func startScan() {
        guard ready, active == nil else { return }
        devices = []; peripherals = [:]; details = []; reportURL = nil
        scanning = true
        status = "주변 기기를 20초 동안 찾고 있어요"
        log("Scan started")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            self?.stopScan()
            self?.status = "검색 완료 · 기기를 선택해주세요"
        }
    }
    func stopScan() {
        scanTimer?.invalidate(); scanTimer = nil
        central.stopScan(); scanning = false
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning else { return }
        peripherals[peripheral.identifier] = peripheral
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "이름 없는 기기"
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map { $0.uuidString }
        let row = Device(id: peripheral.identifier, name: name, rssi: RSSI.intValue,
                         services: services, connectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true)
        if let index = devices.firstIndex(where: { $0.id == row.id }) { devices[index] = row }
        else { devices.append(row); log("Discovered \(row.name) \(row.id) services=\(services)") }
    }
    func connect(_ device: Device) {
        guard ready, active == nil, let peripheral = peripherals[device.id] else { return }
        stopScan(); details = []; discoveryFailed = false; serviceMatch = false
        active = peripheral; activeID = device.id; peripheral.delegate = self
        status = "\(device.name)에 연결 중"
        log("Connecting \(device.id)")
        central.connect(peripheral, options: nil)
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            guard let self = self, let target = self.active else { return }
            self.log("Connection/discovery timed out")
            self.status = "연결 또는 정보 조회 시간이 초과됐어요. 연결 해제 후 다시 시도해주세요."
            self.central.cancelPeripheralConnection(target)
        }
    }
    func disconnect() {
        connectionTimer?.invalidate()
        if let active = active {
            status = "연결 해제 중"
            central.cancelPeripheralConnection(active)
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard activeID == peripheral.identifier else { return }
        status = "연결 성공 · 제공 기능 확인 중"
        log("Connected \(peripheral.identifier)")
        peripheral.discoverServices(nil)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish(peripheral, message: "연결 실패: \(error?.localizedDescription ?? "알 수 없는 오류")")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        finish(peripheral, message: "연결 해제\(error.map { ": " + $0.localizedDescription } ?? "")")
    }
    private func finish(_ peripheral: CBPeripheral, message: String) {
        guard activeID == peripheral.identifier else { return }
        connectionTimer?.invalidate(); active = nil; activeID = nil; serviceMatch = false
        status = message; log(message)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard activeID == peripheral.identifier else { return }
        if let error = error { status = "정보 조회 실패"; log(error.localizedDescription); connectionTimer?.invalidate(); return }
        let services = peripheral.services ?? []
        serviceMatch = services.contains { $0.uuid == Self.keyweService }
        log(serviceMatch ? "KeyWe SDK service matched; ownership and authentication not verified" : "KeyWe SDK service not found")
        pendingServices = services.count
        if services.isEmpty { status = "공개된 서비스가 없어요"; connectionTimer?.invalidate() }
        for service in services {
            let line = "서비스: \(service.uuid.uuidString)"
            details.append(line); log(line)
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard activeID == peripheral.identifier else { return }
        if let error = error { discoveryFailed = true; log(error.localizedDescription) }
        for characteristic in service.characteristics ?? [] {
            let p = characteristic.properties
            var flags: [String] = []
            if p.contains(.read) { flags.append("read") }
            if p.contains(.write) { flags.append("write") }
            if p.contains(.writeWithoutResponse) { flags.append("writeWithoutResponse") }
            if p.contains(.notify) { flags.append("notify") }
            if p.contains(.indicate) { flags.append("indicate") }
            let line = "\(service.uuid.uuidString) → \(characteristic.uuid.uuidString) [\(flags.joined(separator: ", "))] properties=\(p.rawValue)"
            details.append(line); log(line)
        }
        pendingServices -= 1
        if pendingServices == 0 {
            connectionTimer?.invalidate()
            status = discoveryFailed ? "일부 정보 조회에 실패했어요 · 결과 저장 가능" : "정보 확인 완료 · 결과를 저장해주세요"
        }
    }
    func export() {
        let rows: [[String: Any]] = devices.map {
            ["identifier": $0.id.uuidString, "name": $0.name, "rssi": $0.rssi,
             "advertisedServices": $0.services, "connectable": $0.connectable]
        }
        let payload: [String: Any] = ["app": "IDL300 Probe 0.1", "createdAt": ISO8601DateFormatter().string(from: Date()),
            "note": "Diagnostic only. Device identity not verified. No unlock commands or characteristic values read/written.",
            "devices": rows, "selectedDevice": activeID?.uuidString ?? "", "details": details, "events": events]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("IDL300-\(UUID().uuidString.prefix(8)).json")
            try data.write(to: url, options: .atomic)
            reportURL = url
        } catch { status = "저장 실패: \(error.localizedDescription)" }
    }
}

struct LockProfile: Codable {
    let version: Int
    let name: String
    let qr: String
    var isValid: Bool {
        let bytes = Array(qr.utf8)
        guard version == 1, bytes.count == 30,
              bytes.allSatisfy({ $0 >= 33 && $0 <= 126 }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80 else { return false }
        let sum = bytes.prefix(22).reduce(0) { $0 + Int($1) }
        return String(format: "%04X", sum) == String(decoding: bytes[22..<26], as: UTF8.self)
    }
}

struct ProbeView: View {
    @AppStorage("localLockProfile") private var savedProfile = ""
    @State private var importingProfile = false
    @State private var profileMessage = ""
    private var lockProfile: LockProfile? {
        guard let data = savedProfile.data(using: .utf8),
              let value = try? JSONDecoder().decode(LockProfile.self, from: data),
              value.isValid else { return nil }
        return value
    }
    private func importProfile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 8192 else { profileMessage = "기기 파일이 너무 큽니다."; return }
            let data = try Data(contentsOf: url)
            guard data.count <= 8192 else { profileMessage = "기기 파일이 너무 큽니다."; return }
            let value = try JSONDecoder().decode(LockProfile.self, from: data)
            guard value.isValid else { profileMessage = "QR 형식 또는 체크섬이 맞지 않습니다."; return }
            savedProfile = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            profileMessage = "이 아이폰에 기기 정보를 저장했습니다. 도어락 인증은 아직 완료되지 않았습니다."
        } catch {
            profileMessage = "기기 파일을 가져오지 못했습니다. 파일 선택을 다시 시도해주세요."
        }
    }

    @StateObject private var probe = BluetoothProbe()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("우리집 도어락", systemImage: "door.left.hand.closed")
                        .font(.title2.bold()).padding(.vertical, 8)
                    Text("도어록 가까이에서 검색한 뒤 본인 기기를 선택해주세요. 이름만으로 IDL-300인지 확정할 수는 없어요.")
                    Text("회원가입과 로그인 없이 시작합니다.").foregroundStyle(.secondary)
                    Label("문 열기 · 아직 지원하지 않음", systemImage: "lock.fill")
                    Text("현재는 연결 확인용입니다. 새 휴대폰 등록과 자동 문 열기는 사용할 수 없습니다.").font(.caption).foregroundStyle(.secondary)
                }
                Section("내 도어락 정보") {
                    if let profile = lockProfile {
                        Text(profile.name).font(.headline)
                        Text("QR 확인됨 · " + String(profile.qr.prefix(4)) + "…" + String(profile.qr.suffix(4)))
                        Text("기기 정보 저장 완료 · 연결 대상 확인과 인증은 미완료").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("사진에서 만든 개인 기기 파일을 불러오세요.")
                    }
                    Button("기기 파일 가져오기") { importingProfile = true }
                    if !profileMessage.isEmpty { Text(profileMessage).font(.caption) }
                }
                Section("상태") {
                    Text(probe.status)
                    if probe.serviceMatch {
                        Label("KeyWe 통신 서비스 확인", systemImage: "checkmark.circle")
                        Text("우리집 도어락 여부와 인증은 아직 확인되지 않았습니다.").font(.caption)
                    }
                    if probe.scanning { ProgressView() }
                    Button(probe.scanning ? "검색 중지" : "주변 기기 검색") {
                        if probe.scanning { probe.stopScan(); probe.status = "검색을 중지했어요" }
                        else { probe.startScan() }
                    }.disabled(!probe.ready || probe.activeID != nil)
                    if probe.activeID != nil { Button("연결 해제") { probe.disconnect() } }
                }
                Section("주변 블루투스 기기 · \(probe.devices.count)개") {
                    if probe.devices.isEmpty {
                        Text("검색 결과가 여기에 표시됩니다. 이름 없는 기기도 표시하며, 검색만으로 도어락을 확정하지 않습니다.").foregroundStyle(.secondary)
                    }
                    ForEach(probe.devices.sorted { $0.rssi == 127 ? false : ($1.rssi == 127 ? true : $0.rssi > $1.rssi) }) { device in
                        Button { probe.connect(device) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(device.name).font(.headline)
                                Text(device.rssi == 127 ? "신호 세기 알 수 없음" : "신호 \(device.rssi) dBm")
                                Text(device.id.uuidString).font(.caption2).foregroundStyle(.secondary)
                                if !device.connectable { Text("현재 연결을 받지 않는 기기").font(.caption) }
                            }
                        }.disabled(probe.activeID != nil || !device.connectable || !probe.ready)
                    }
                }
                if !probe.details.isEmpty {
                    Section("연결 정보") {
                        ForEach(Array(probe.details.enumerated()), id: \.offset) { item in
                            Text(item.element).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                Section("결과 보내기") {
                    Text("주변 기기 이름·식별자와 연결 정보가 포함돼요. 파일은 직접 공유할 때만 외부로 전달됩니다.").font(.caption).foregroundStyle(.secondary)
                    Button("진단 결과 파일 만들기") { probe.export() }.disabled(probe.devices.isEmpty)
                    if let url = probe.reportURL { ShareLink("진단 결과 공유", item: url) }
                }
            }
            .navigationTitle("우리집 도어락")
            .fileImporter(isPresented: $importingProfile, allowedContentTypes: [.json], onCompletion: importProfile)
            .onChange(of: scenePhase) { phase in
                if phase != .active { probe.stopScan(); probe.disconnect() }
            }
        }
    }
}
