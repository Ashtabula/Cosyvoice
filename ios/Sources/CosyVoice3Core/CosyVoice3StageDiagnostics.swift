// CosyVoice3StageDiagnostics.swift
// Requirement: validation-only actual-request stage repetition and Instruments intervals; never infer residency from requested placement.
import Foundation
import os
import Darwin

@available(iOS 18.0, macOS 15.0, *)
enum CosyVoice3StageDiagnostics {
    static let log = OSLog(subsystem: "com.actacomes.cosyvoice3.stages", category: .pointsOfInterest)
    static func count(_ stage: String) -> Int {
        CommandLine.arguments.contains("--validation-isolated-stage=\(stage)") ? 12 : 1
    }
    static func begin(_ stage: String) -> OSSignpostID {
        guard CommandLine.arguments.contains("--validation-stage-profiling") || CommandLine.arguments.contains(where: { $0.hasPrefix("--validation-isolated-stage=") }) else { return .invalid }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "CosyStage", signpostID: id, "%{public}@", stage)
        return id
    }
    static func end(_ id: OSSignpostID, _ stage: String) {
        guard id != .invalid else { return }
        os_signpost(.end, log: log, name: "CosyStage", signpostID: id, "%{public}@", stage)
    }
    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
    static func cpu() -> Double {
        var value = rusage(); guard getrusage(RUSAGE_SELF, &value) == 0 else { return -1 }
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)*1000 + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec)/1000
    }
    static func footprint() -> UInt64 {
        var value = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &value) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? value.phys_footprint : 0
    }
    static func gate(_ stage: String) async throws {
        guard count(stage) > 1 else { return }
        let started = Date()
        while ProcessInfo.processInfo.thermalState != .nominal && Date().timeIntervalSince(started) < 300 {
            try await Task.sleep(for: .seconds(5))
        }
        guard ProcessInfo.processInfo.thermalState == .nominal else {
            throw NSError(domain: "CosyStageDiagnostic", code: 1, userInfo: [NSLocalizedDescriptionKey:"nominal start gate failed for \(stage)"])
        }
    }
    static func row(_ iteration: Int, since started: UInt64, cpuBefore: Double, thermalBefore: String) -> [String: Any] {
        ["iteration":iteration,"startUptimeNanoseconds":started, "wallMilliseconds":Double(DispatchTime.now().uptimeNanoseconds-started)/1_000_000,
         "CPUTimeMilliseconds":cpu()-cpuBefore,"thermalStart":thermalBefore,"thermalEnd":thermal(),"physicalFootprintBytes":footprint(),
         "actualResidency":"UNKNOWN_RESIDENCY"]
    }
    static func save(_ stage: String, rows: [[String: Any]], equal: Bool) throws {
        guard count(stage) > 1 else { return }
        let root = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let nominal = rows.first?["thermalStart"] as? String == "nominal"
        let receipt: [String: Any] = ["schemaVersion":1,"stage":stage,"status":!nominal ? "INVALID_NOMINAL_START" : (equal ? "PASS_REPEAT_OUTPUT_EQUAL" : "FAIL_REPEAT_OUTPUT_CHANGED"),
          "processID":ProcessInfo.processInfo.processIdentifier,"iterations":rows,"noInterIterationDelay":true,
          "noFileIOInsideLoop":true,"scope":"isolated stage from actual public request; diagnostic expanded request is not a production RTF",
          "memoryMeaning":"boundary footprint samples, not authoritative peak","CPUTimeMeaning":"process self CPU only; no accelerator residency or power inference"]
        try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("isolated-\(stage)-receipt.json"),options:.atomic)
        print("[COSY-ISOLATED-COMPLETE] stage=\(stage) equal=\(equal) iterations=\(rows.count)")
    }
}
// Purpose: exact native stage repeats, boundary metrics and trace correlation. Upstream native Engine/Flow/HiFT; Swift6/CoreML iOS18+/macOS15+. Generated 2026-10-05 America/New_York. New validation helper; graph, weights and production iteration counts unchanged.
