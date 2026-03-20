import Foundation

#if os(macOS)
import LocalAuthentication
import Security

public enum KeychainNoUIQuery {
    public static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
    }
}
#endif
