// Manage only the explicitly named, project-local keychain. Never enable UI.
import Foundation
import Security
import CryptoKit
import Darwin

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == errSecSuccess else { throw NSError(domain: operation, code: Int(status)) }
}

func run() throws {
    guard CommandLine.arguments.count == 5 else { throw NSError(domain: "usage: local_signing create|open KEYCHAIN PASSWORD_FILE PKCS12_OR_DASH", code: 1) }
    let action = CommandLine.arguments[1]
    let keychainPath = CommandLine.arguments[2]
    let password = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    try check(SecKeychainSetUserInteractionAllowed(false), "disable keychain UI")
    var keychain: SecKeychain?
    if action == "create" {
        try check(password.withUnsafeBytes { bytes in
            SecKeychainCreate(keychainPath, UInt32(bytes.count), bytes.baseAddress, false, nil, &keychain)
        }, "create local keychain")
        guard chmod(keychainPath, S_IRUSR | S_IWUSR) == 0 else {
            throw NSError(domain: "restrict local keychain file", code: Int(errno))
        }
    } else if action == "open" || action == "import" {
        try check(SecKeychainOpen(keychainPath, &keychain), "open local keychain")
        try check(password.withUnsafeBytes { bytes in
            SecKeychainUnlock(keychain, UInt32(bytes.count), bytes.baseAddress, true)
        }, "unlock local keychain")
    } else {
        throw NSError(domain: "unknown action", code: 1)
    }
    var searchList: CFArray?
    try check(SecKeychainCopySearchList(&searchList), "read keychain search list")
    let listed = (searchList as? [SecKeychain] ?? []).contains { CFEqual($0, keychain!) }
    var defaultKeychain: SecKeychain?
    try check(SecKeychainCopyDefault(&defaultKeychain), "read default keychain")
    if listed || (defaultKeychain != nil && CFEqual(defaultKeychain!, keychain!)) {
        throw NSError(domain: "project keychain appeared in default or search list", code: 1)
    }
    if action == "create" || action == "import" {
        var trusted: SecTrustedApplication?
        try check(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &trusted), "trust codesign")
        guard let trusted else { throw NSError(domain: "missing codesign trust", code: 1) }
        var access: SecAccess?
        try check(SecAccessCreate("006IDC local code signing key" as CFString, [trusted] as CFArray, &access), "create codesign ACL")
        let importedData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4]))
        let passphrase = String(decoding: password, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let cfPassphrase = passphrase as CFString
        var params = SecItemImportExportKeyParameters()
        params.version = 0
        params.passphrase = Unmanaged.passUnretained(cfPassphrase)
        params.accessRef = Unmanaged.passUnretained(access!)
        var format = SecExternalFormat(rawValue: 12)!
        var itemType = SecExternalItemType(rawValue: 5)!
        var items: CFArray?
        let importStatus = withExtendedLifetime((cfPassphrase, access)) {
            SecItemImport(importedData as CFData, nil, &format, &itemType, [], &params, keychain, &items)
        }
        try check(importStatus, "import local identity")
    }
    let query: [CFString: Any] = [kSecClass: kSecClassIdentity,
                                  kSecMatchSearchList: [keychain!],
                                  kSecMatchLimit: kSecMatchLimitOne,
                                  kSecReturnRef: true]
    var result: CFTypeRef?
    try check(SecItemCopyMatching(query as CFDictionary, &result), "find local identity")
    let identity = result as! SecIdentity
    var certificate: SecCertificate?
    try check(SecIdentityCopyCertificate(identity, &certificate), "read local certificate")
    let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate!) as Data)
    print(digest.map { String(format: "%02X", $0) }.joined())
}

do { try run() } catch {
    fputs("local signing unavailable: \(error)\n", stderr)
    exit(1)
}
