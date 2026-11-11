import Foundation
import MicroVMCore

#if os(macOS)
import Virtualization
#endif

public enum DoctorVirtualizationSupport {
    public static func backendCheck() -> DoctorCheck {
        #if os(macOS)
        return DoctorCheck("backend", VZVirtualMachine.isSupported ? "ok" : "error",
                           VZVirtualMachine.isSupported ? "Virtualization.framework supports this host."
                               : "Virtualization.framework is unavailable on this host.",
                           recovery: VZVirtualMachine.isSupported ? nil : "Use a Mac with Virtualization.framework support.")
        #else
        return DoctorCheck("backend", "error", "The macOS virtualization backend is unavailable.", recovery: "Run microvm on a supported Mac.")
        #endif
    }

    public static func signingCheck(executable: URL) -> DoctorCheck {
        #if os(macOS)
        if runCodesign(["--verify", "--strict", executable.path]) != nil,
           let data = runCodesign(["-d", "--entitlements", "-", "--xml", executable.path]),
           let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           values["com.apple.security.virtualization"] as? Bool == true {
            return DoctorCheck("signing", "ok", "CLI signature validates and includes the virtualization entitlement.")
        }
        return DoctorCheck("signing", "error", "CLI signature or virtualization entitlement is missing/invalid.",
                           recovery: "Run ./scripts/build-macos.sh and use its signed release CLI; re-sign after rebuilding.")
        #else
        return DoctorCheck("signing", "error", "macOS code-signing validation is unavailable.", recovery: "Build and sign the CLI on a supported Mac.")
        #endif
    }

    #if os(macOS)
    private static func runCodesign(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
    #endif
}
