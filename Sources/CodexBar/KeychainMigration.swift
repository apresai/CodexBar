import CodexBarCore
import Foundation
import Security

/// Migrates keychain items to use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
/// to prevent permission prompts on every rebuild during development.
enum KeychainMigration {
    private static let log = CodexBarLog.logger(LogCategories.keychainMigration)
    private static let migrationKey = "KeychainMigrationV1Completed"

    struct MigrationItem: Hashable {
        let service: String
        let account: String?

        var label: String {
            let accountLabel = self.account ?? "<any>"
            return "\(self.service):\(accountLabel)"
        }
    }

    static let itemsToMigrate: [MigrationItem] = [
        MigrationItem(service: "com.steipete.CodexBar", account: "codex-cookie"),
        MigrationItem(service: "com.steipete.CodexBar", account: "claude-cookie"),
        MigrationItem(service: "com.steipete.CodexBar", account: "cursor-cookie"),
        MigrationItem(service: "com.steipete.CodexBar", account: "factory-cookie"),
        MigrationItem(service: "com.steipete.CodexBar", account: "minimax-cookie"),
        MigrationItem(service: "com.steipete.CodexBar", account: "minimax-api-token"),
        MigrationItem(service: "com.steipete.CodexBar", account: "augment-cookie"),
        MigrationItem(service: "com.steipete.CodexBar", account: "copilot-api-token"),
        MigrationItem(service: "com.steipete.CodexBar", account: "zai-api-token"),
        MigrationItem(service: "com.steipete.CodexBar", account: "synthetic-api-key"),
    ]

    /// Run migration once per installation
    static func migrateIfNeeded() {
        guard !KeychainAccessGate.isDisabled else {
            self.log.info("Keychain access disabled; skipping migration")
            return
        }

        if !UserDefaults.standard.bool(forKey: self.migrationKey) {
            self.log.info("Starting keychain migration to reduce permission prompts")

            var migratedCount = 0
            var errorCount = 0

            for item in self.itemsToMigrate {
                do {
                    if try self.migrateItem(item) {
                        migratedCount += 1
                    }
                } catch {
                    errorCount += 1
                    self.log.error("Failed to migrate \(item.label): \(String(describing: error))")
                }
            }

            self.log.info("Keychain migration complete: \(migratedCount) migrated, \(errorCount) errors")
            UserDefaults.standard.set(true, forKey: self.migrationKey)

            if migratedCount > 0 {
                self.log.info("✅ Future rebuilds will not prompt for keychain access")
            }
        } else {
            self.log.debug("Keychain migration already completed, skipping")
        }
    }

    /// Migrate a single keychain item to the new accessibility level
    /// Returns true if item was migrated, false if item didn't exist
    private static func migrateItem(_ item: MigrationItem) throws -> Bool {
        // First, try to read the existing item
        var result: CFTypeRef?
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
        ]
        if let account = item.account {
            query[kSecAttrAccount as String] = account
        }

        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            // Item doesn't exist, nothing to migrate
            return false
        }

        guard status == errSecSuccess else {
            throw KeychainMigrationError.readFailed(status)
        }

        guard let rawItem = result as? [String: Any],
              let data = rawItem[kSecValueData as String] as? Data,
              let accessible = rawItem[kSecAttrAccessible as String] as? String
        else {
            throw KeychainMigrationError.invalidItemFormat
        }

        // Check if already using the correct accessibility
        if accessible == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String) {
            self.log.debug("\(item.label) already using correct accessibility")
            return false
        }

        // Delete the old item
        var deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
        ]
        if let account = item.account {
            deleteQuery[kSecAttrAccount as String] = account
        }

        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        guard deleteStatus == errSecSuccess else {
            throw KeychainMigrationError.deleteFailed(deleteStatus)
        }

        // Add it back with the new accessibility
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if let account = item.account {
            addQuery[kSecAttrAccount as String] = account
        }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainMigrationError.addFailed(addStatus)
        }

        self.log.info("Migrated \(item.label) to new accessibility level")
        return true
    }

    /// Reset migration flag (for testing)
    static func resetMigrationFlag() {
        UserDefaults.standard.removeObject(forKey: self.migrationKey)
    }

    // MARK: - V2: Legacy → Data Protection Keychain

    private static let migrationV2Key = "KeychainMigrationV2Completed"

    static func migrateToDataProtectionKeychainIfNeeded() {
        guard !KeychainAccessGate.isDisabled else {
            self.log.info("Keychain access disabled; skipping V2 migration")
            return
        }

        guard !UserDefaults.standard.bool(forKey: self.migrationV2Key) else {
            self.log.debug("Keychain V2 migration already completed, skipping")
            return
        }

        self.log.info("Starting V2 keychain migration (legacy → data protection keychain)")

        var migratedCount = 0
        var skippedCount = 0
        var errorCount = 0

        for item in self.itemsToMigrate {
            switch self.migrateItemToDataProtection(service: item.service, account: item.account) {
            case .migrated:
                migratedCount += 1
            case .notFound, .alreadyInDataProtection:
                break
            case .skipped:
                skippedCount += 1
            case .failed:
                errorCount += 1
            }
        }

        self.migrateCacheServiceItems(
            service: KeychainCacheStore.cacheServiceName,
            migratedCount: &migratedCount,
            skippedCount: &skippedCount,
            errorCount: &errorCount)

        self.log.info(
            "V2 keychain migration complete: \(migratedCount) migrated, "
                + "\(skippedCount) skipped, \(errorCount) errors")
        if skippedCount == 0 {
            UserDefaults.standard.set(true, forKey: self.migrationV2Key)
        } else {
            self.log.info("V2 migration deferred — \(skippedCount) items skipped, will retry next launch")
        }
    }

    private enum V2MigrationResult {
        case migrated
        case notFound
        case alreadyInDataProtection
        case skipped
        case failed
    }

    private static func migrateItemToDataProtection(
        service: String,
        account: String?
    ) -> V2MigrationResult {
        let label = "\(service):\(account ?? "<any>")"

        var readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
        ]
        KeychainNoUIQuery.apply(to: &readQuery)
        if let account {
            readQuery[kSecAttrAccount as String] = account
        }

        var result: AnyObject?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)

        switch readStatus {
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed:
            self.log.debug("V2 migration skipped (interaction not allowed): \(label)")
            return .skipped
        case errSecSuccess:
            break
        default:
            self.log.error("V2 migration read failed for \(label): \(readStatus)")
            return .failed
        }

        guard let rawItem = result as? [String: Any],
              let data = rawItem[kSecValueData as String] as? Data
        else {
            self.log.error("V2 migration: invalid item format for \(label)")
            return .failed
        }

        let resolvedAccount = account ?? (rawItem[kSecAttrAccount as String] as? String)
        let itemLabel = rawItem[kSecAttrLabel as String] as? String

        return self.writeToDataProtectionAndDeleteLegacy(
            service: service, account: resolvedAccount, data: data, label: itemLabel,
            logLabel: label)
    }

    private static func writeToDataProtectionAndDeleteLegacy(
        service: String,
        account: String?,
        data: Data,
        label: String?,
        logLabel: String
    ) -> V2MigrationResult {
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        KeychainDataProtection.apply(to: &addQuery)
        if let account {
            addQuery[kSecAttrAccount as String] = account
        }
        if let label {
            addQuery[kSecAttrLabel as String] = label
        }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
            self.log.error("V2 migration add failed for \(logLabel): \(addStatus)")
            return .failed
        }

        // Delete legacy item (intentionally no data protection flag — targets the legacy keychain)
        var deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account {
            deleteQuery[kSecAttrAccount as String] = account
        }

        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            self.log.warning("V2 migration: failed to delete legacy item \(logLabel): \(deleteStatus)")
        }

        if addStatus == errSecDuplicateItem {
            self.log.debug("V2 migration: item already in data protection keychain: \(logLabel)")
            return .alreadyInDataProtection
        }

        self.log.info("V2 migrated \(logLabel) to data protection keychain")
        return .migrated
    }

    private static func migrateCacheServiceItems(
        service: String,
        migratedCount: inout Int,
        skippedCount: inout Int,
        errorCount: inout Int
    ) {
        var searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        KeychainNoUIQuery.apply(to: &searchQuery)

        var result: AnyObject?
        let status = SecItemCopyMatching(searchQuery as CFDictionary, &result)

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status == errSecInteractionNotAllowed {
                self.log.warning("V2 migration: cache items inaccessible (device locked?)")
                skippedCount += 1
            } else if status != errSecItemNotFound {
                self.log.warning("V2 migration: cache enumeration failed (status: \(status))")
            }
            return
        }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data
            else {
                continue
            }

            let itemLabel = item[kSecAttrLabel as String] as? String
            let logLabel = "\(service):\(account)"

            switch self.writeToDataProtectionAndDeleteLegacy(
                service: service, account: account, data: data, label: itemLabel,
                logLabel: logLabel)
            {
            case .migrated:
                migratedCount += 1
            case .failed:
                errorCount += 1
            case .notFound, .alreadyInDataProtection, .skipped:
                break
            }
        }
    }

    static func resetV2MigrationFlag() {
        UserDefaults.standard.removeObject(forKey: self.migrationV2Key)
    }
}

enum KeychainMigrationError: Error {
    case readFailed(OSStatus)
    case deleteFailed(OSStatus)
    case addFailed(OSStatus)
    case invalidItemFormat
}
