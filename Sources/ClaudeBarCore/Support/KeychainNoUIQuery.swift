import Foundation

#if os(macOS)
import Darwin
import LocalAuthentication
import Security

/// Applies a "no UI under any circumstances" policy to a `SecItem` query dictionary.
///
/// This is the load-bearing primitive that guarantees background credential probes
/// never raise an Allow/Deny keychain prompt. Ported from
/// `_reference_codexbar/Sources/CodexBarCore/KeychainNoUIQuery.swift:11-19`.
///
/// It sets:
///  - `kSecUseAuthenticationContext` to an `LAContext` with `interactionNotAllowed = true`
///  - `kSecUseAuthenticationUI` to `kSecUseAuthenticationUIFail`, resolved at runtime via
///    `dlsym` to avoid referencing the deprecated constant at compile time while still
///    sending its exact value (`u_AuthUIF`).
public enum KeychainNoUIQuery {
    private static let uiFailPolicy = KeychainNoUIQuery.resolveUIFailPolicy()

    public static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        // Keep explicit UI-fail policy: on macOS, `interactionNotAllowed` alone can still
        // surface Allow/Deny prompts for legacy keychain items.
        query[kSecUseAuthenticationUI as String] = self.uiFailPolicy as CFString
    }

    public static func uiFailPolicyForTesting() -> String {
        self.uiFailPolicy
    }

    private static func resolveUIFailPolicy() -> String {
        // Resolve the Security symbol at runtime to preserve the true constant value
        // without directly referencing deprecated API at compile time.
        let securityPath = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(securityPath, RTLD_NOW) else {
            return "u_AuthUIF"
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else {
            return "u_AuthUIF"
        }
        let valuePointer = symbol.assumingMemoryBound(to: CFString?.self)
        return (valuePointer.pointee as String?) ?? "u_AuthUIF"
    }
}
#endif
