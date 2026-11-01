#if BENCH
import AppKit
import QuartzCore
import Darwin

/// Drives a synthetic pointer sweep through the first dock panel and records
/// what it costs, so a rendering change can be judged by numbers rather than
/// by feel. Compiled only with `-DBENCH`; it never ships.
///
/// It feeds the dock through a notification instead of real mouse events, so
/// it never moves the real cursor, and a dev bundle id keeps it away from the
/// real preferences. The same input path is used for every implementation, so
/// two runs are directly comparable.
///
/// Usage:  DAWCK_BENCH=1 DAWCK_BENCH_OUT=/tmp/x.json Dawck.app/Contents/MacOS/Dawck
final class DockBenchmark: NSObject {
    static let shared = DockBenchmark()

    private struct Scenario {
        let name: String
        let duration: Double
        /// Pointer position along the row's long axis (0...1), or nil for "no pointer".
        let pointer: (Double) -> Double?
        /// An action repeated every `period` seconds (toggling the dock's visibility).
        var periodic: (period: Double, action: (DockController) -> Void)?
    }

    private var lastPeriodic = 0.0

    private var link: CADisplayLink?
    private var scenarios: [Scenario] = []
    private var current: Scenario?
    private var startTime: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var results: [[String: Any]] = []
    private var cpu0 = (thread: UInt64(0), process: 0.0)
    private var wall0: CFTimeInterval = 0
    /// One `top` per scenario, sampling WindowServer over exactly that window:
    /// compositing the blur, shadows and glow happens there, not in this process.
    private var topRuns: [(name: String, pipe: Pipe)] = []
    private lazy var windowServerPID: Int32? = {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-x", "WindowServer"]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        return Int32(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? "")
    }()

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["DAWCK_BENCH"] != nil else { return }
        // Wait for startup work to finish, so "idle" really is idle: begin once the
        // process has stayed under a few percent CPU for two consecutive seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { shared.waitUntilSettled(since: processCPU(), at: CACurrentMediaTime(), quietChecks: 0, deadline: CACurrentMediaTime() + 14) }
    }

    private func waitUntilSettled(since cpu: Double, at time: CFTimeInterval, quietChecks: Int, deadline: CFTimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let now = CACurrentMediaTime()
            let usage = (Self.processCPU() - cpu) / max(now - time, 0.001) * 100
            let quiet = usage < 6 ? quietChecks + 1 : 0
            if quiet >= 2 || now > deadline { self.begin(); return }
            self.waitUntilSettled(since: Self.processCPU(), at: now, quietChecks: quiet, deadline: deadline)
        }
    }

    private weak var controller: DockController?

    private func begin() {
        guard let first = AppDelegate.current?.benchControllers.first else {
            fputs("BENCH: no dock found\n", stderr); NSApp.terminate(nil); return
        }
        controller = first
        // The settings window is not what is being measured; keep it out of the way.
        for window in NSApp.windows where !(window is NSPanel) && window.isVisible && window.level == .normal {
            window.orderOut(nil)
        }
        scenarios = [
            Scenario(name: "idle", duration: 5) { _ in nil },
            // Two full passes per second, edge to edge: a brisk, realistic sweep.
            Scenario(name: "sweep", duration: 10) { t in 0.5 + 0.5 * sin(t * 2 * .pi * 0.9) },
            Scenario(name: "idle-after", duration: 3) { _ in nil },
            // Appear / disappear: the dock hides and returns every 1.1 s.
            Scenario(name: "appear", duration: 9, pointer: { _ in nil }, periodic: (1.1, { $0.toggleFromHotKey() })),
        ]
        // A dock that hides itself (the "hide completely" mode) is shown first, the
        // way the pointer reaching the screen edge would.
        first.benchReveal()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.next() }
    }

    private func next() {
        guard !scenarios.isEmpty else { finish(); return }
        current = scenarios.removeFirst()
        intervals.removeAll(keepingCapacity: true)
        lastTimestamp = 0
        startTime = CACurrentMediaTime()
        lastPeriodic = 0
        wall0 = startTime
        cpu0 = (Self.threadCPU(), Self.processCPU())
        if let pid = windowServerPID, let scenario = current {
            let top = Process()
            top.executableURL = URL(fileURLWithPath: "/usr/bin/top")
            top.arguments = ["-l", "2", "-s", String(Int(scenario.duration)), "-pid", String(pid), "-stats", "pid,cpu"]
            let pipe = Pipe(); top.standardOutput = pipe; top.standardError = FileHandle.nullDevice
            try? top.run()
            topRuns.append((scenario.name, pipe))
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let scenario = current else { return }
        let elapsed = CACurrentMediaTime() - startTime
        if lastTimestamp != 0 { intervals.append(link.timestamp - lastTimestamp) }
        lastTimestamp = link.timestamp

        if elapsed >= scenario.duration {
            link.invalidate()
            self.link = nil
            record(scenario)
            post(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.next() }
            return
        }
        // Only touch the dock when the scenario has a pointer (or just lost it),
        // so "idle" measures the dock at rest rather than the harness poking it.
        if let periodic = scenario.periodic, elapsed - lastPeriodic >= periodic.period, let controller {
            lastPeriodic = elapsed
            periodic.action(controller)
        }
        let fraction = scenario.pointer(elapsed)
        if fraction != nil || hadPointer { controller?.benchPointer(fraction) }
        hadPointer = fraction != nil
    }

    private var hadPointer = false

    private func post(_ point: CGPoint?) { controller?.benchPointer(nil) }

    private func record(_ scenario: Scenario) {
        let wall = CACurrentMediaTime() - wall0
        let threadMs = Double(Self.threadCPU() - cpu0.thread) / 1_000_000
        let processS = Self.processCPU() - cpu0.process
        let sorted = intervals.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] * 1000 }
        let nominal = sorted.isEmpty ? 0.0167 : sorted[sorted.count / 2]
        let dropped = intervals.filter { $0 > nominal * 1.6 }.count
        results.append([
            "scenario": scenario.name,
            "wallSeconds": (wall * 100).rounded() / 100,
            "frames": intervals.count + 1,
            "frameMs_p50": (pct(0.5) * 100).rounded() / 100,
            "frameMs_p95": (pct(0.95) * 100).rounded() / 100,
            "frameMs_max": ((sorted.last ?? 0) * 100000).rounded() / 100,
            "droppedFrames": dropped,
            "mainThreadCPU_percent": ((threadMs / 10) / wall * 100).rounded() / 100,
            "processCPU_percent": ((processS / wall) * 10000).rounded() / 100,
            "residentMB": Self.residentMB(),
        ])
    }

    private func finish() {
        // Attach WindowServer's CPU for each scenario (the last sample of its `top`).
        for (index, run) in topRuns.enumerated() where index < results.count {
            let text = String(data: run.pipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            let last = text.components(separatedBy: "\n").reversed().compactMap { line -> Double? in
                let parts = line.split(separator: " ").map(String.init)
                return parts.count == 2 && Int32(parts[0]) == windowServerPID ? Double(parts[1]) : nil
            }.first
            results[index]["windowServerCPU_percent"] = last ?? -1
        }
        let payload: [String: Any] = [
            "label": ProcessInfo.processInfo.environment["DAWCK_BENCH"] ?? "",
            "results": results,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            if let out = ProcessInfo.processInfo.environment["DAWCK_BENCH_OUT"] {
                try? data.write(to: URL(fileURLWithPath: out))
            }
            FileHandle.standardError.write(data)
        }
        NSApp.terminate(nil)
    }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? (Double(info.resident_size) / 1_048_576 * 10).rounded() / 10 : -1
    }

    private static func threadCPU() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    private static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
#endif
