import SwiftUI
import Darwin

struct Traffic: Equatable {
    var down: Int64 = 0
    var up: Int64 = 0

    init() {}

    init(_ d: UserDefaults, _ prefix: String) {
        down = Int64(d.integer(forKey: prefix + "down"))
        up = Int64(d.integer(forKey: prefix + "up"))
    }

    func save(_ d: UserDefaults, _ prefix: String) {
        d.set(Int(down), forKey: prefix + "down")
        d.set(Int(up), forKey: prefix + "up")
    }
}

final class Stats: ObservableObject {
    @Published private(set) var total: Traffic
    @Published private(set) var today: Traffic
    // средняя скорость за последние 10 с, байт/с
    @Published private(set) var speedDown = 0.0
    @Published private(set) var speedUp = 0.0

    // последние значения счётчиков системы по интерфейсам
    private var last: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var lastTime = Date()
    private var samples: [(time: Date, dt: Double, rx: UInt64, tx: UInt64)] = []
    private var day: String
    private var ticks = 0
    private let defaults = UserDefaults.standard

    init() {
        total = Traffic(defaults, "")
        day = Stats.dayKey()
        today = defaults.string(forKey: "today.day") == day ? Traffic(defaults, "today.") : Traffic()
        last = Stats.readCounters()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
    }

    private func poll() {
        let now = Stats.readCounters()
        var rx: UInt64 = 0, tx: UInt64 = 0
        for (name, c) in now {
            // новый интерфейс: только запоминаем, считаем со следующего раза
            guard let p = last[name] else { continue }
            // счётчик сбросился (интерфейс переподключили) — берём как есть
            rx += c.rx >= p.rx ? c.rx - p.rx : c.rx
            tx += c.tx >= p.tx ? c.tx - p.tx : c.tx
        }
        last = now
        updateSpeed(rx, tx)

        let d = Stats.dayKey()
        if d != day { day = d; today = Traffic() }
        if rx > 0 || tx > 0 {
            total.down += Int64(rx)
            total.up += Int64(tx)
            today.down += Int64(rx)
            today.up += Int64(tx)
        }
        ticks += 1
        if ticks % 5 == 0 { save() }
    }

    // реальное время между опросами, таймер может опаздывать (например, после сна)
    private func updateSpeed(_ rx: UInt64, _ tx: UInt64) {
        let t = Date()
        let dt = t.timeIntervalSince(lastTime)
        lastTime = t
        // после сна долгий интервал занизил бы скорость
        if dt > 10 { samples.removeAll(); return }
        samples.append((t, dt, rx, tx))
        samples.removeAll { t.timeIntervalSince($0.time) > 10 }
        let span = samples.reduce(0) { $0 + $1.dt }
        guard span > 0 else { return }
        let down = Double(samples.reduce(0) { $0 + $1.rx }) / span
        let up = Double(samples.reduce(0) { $0 + $1.tx }) / span
        if down != speedDown { speedDown = down }
        if up != speedUp { speedUp = up }
    }

    func save() {
        total.save(defaults, "")
        today.save(defaults, "today.")
        defaults.set(day, forKey: "today.day")
    }

    private static func dayKey() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }

    // только физические интерфейсы: Wi-Fi и Ethernet (en*), сотовая связь (pdp_ip*).
    // utun (VPN) не считаем, его трафик и так идёт через физический интерфейс
    private static func counted(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }

    // 64-битные счётчики через NET_RT_IFLIST2; у getifaddrs они 32-битные и переполняются на 4 ГБ
    static func readCounters() -> [String: (rx: UInt64, tx: UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }

        var result: [String: (rx: UInt64, tx: UInt64)] = [:]
        buf.withUnsafeBytes { p in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let h = p.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                if h.ifm_msglen == 0 { break }
                if Int32(h.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let m = p.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(m.ifm_index), &name) != nil {
                        let n = String(cString: name)
                        if counted(n) {
                            result[n] = (m.ifm_data.ifi_ibytes, m.ifm_data.ifi_obytes)
                        }
                    }
                }
                off += Int(h.ifm_msglen)
            }
        }
        return result
    }
}

@main
struct NetMeterApp: App {
    @StateObject private var stats = Stats()

    var body: some Scene {
        MenuBarExtra("NetMeter", systemImage: "arrow.up.arrow.down") {
            StatsView(stats: stats)
        }
        .menuBarExtraStyle(.window)
    }
}

struct StatsView: View {
    @ObservedObject var stats: Stats

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1).gridColumnAlignment(.leading)
                    Text("Today")
                    Text("Total")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                row("arrow.down", stats.today.down, stats.total.down)
                row("arrow.up", stats.today.up, stats.total.up)
            }
            .monospacedDigit()

            Divider()

            HStack {
                speed("arrow.down", stats.speedDown)
                Spacer()
                speed("arrow.up", stats.speedUp)
            }
            .monospacedDigit()

            Divider()

            HStack(spacing: 14) {
                Button("About") { showAbout() }
                Spacer()
                Button("Quit") { stats.save(); NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 250)
    }

    private func row(_ icon: String, _ today: Int64, _ total: Int64) -> some View {
        GridRow {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
            Text(today.formatted(.byteCount(style: .file)))
            Text(total.formatted(.byteCount(style: .file)))
        }
    }

    private func speed(_ icon: String, _ bytes: Double) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text("\(Int64(bytes).formatted(.byteCount(style: .file)))/s")
        }
    }
}

private func showAbout() {
    let center = NSMutableParagraphStyle()
    center.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: center,
        .link: URL(string: "https://github.com/cheeselover419")!,
    ]
    let credits = NSAttributedString(string: "github.com/cheeselover419", attributes: attrs)
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
}
