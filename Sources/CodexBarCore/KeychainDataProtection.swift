import Foundation

#if os(macOS)
import Security

public enum KeychainDataProtection {
    public static func apply(to query: inout [String: Any]) {
        query[kSecUseDataProtectionKeychain as String] = true
    }
}
#endif
