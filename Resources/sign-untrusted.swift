#!/usr/bin/env -S swift -suppress-warnings
// Signs an app with a signing identity this Mac doesn't trust, through the signing API codesign itself uses.
// codesign only signs with certificates trusted for code signing, and macOS won't let a script trust one without
// someone at the keyboard. So on GitHub's Macs, build.sh signs with this instead. The result is the same signature and
// the same designated requirement as codesign's.
//
// Usage: sign-untrusted.swift IDENTITY APP [KEYCHAIN]. Replaces any existing signature, like codesign --force.

import Foundation
import Security

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("Usage: sign-untrusted.swift IDENTITY APP [KEYCHAIN]")
    exit(2)
}
let (name, app) = (arguments[1], arguments[2])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sign-untrusted: \(message)\n".utf8))
    exit(1)
}

// Fail rather than show a dialog nobody could answer
SecKeychainSetUserInteractionAllowed(false)

var query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll]
if arguments.count > 3 {
    var keychain: SecKeychain?
    guard SecKeychainOpen(arguments[3], &keychain) == errSecSuccess, let keychain else { fail("can't open \(arguments[3])") }
    query[kSecMatchSearchList] = [keychain]
}
var found: CFTypeRef?
guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let found else { fail("no signing identities") }
let identity = (found as! [SecIdentity]).first { identity in
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return false }
    return SecCertificateCopySubjectSummary(certificate) as String? == name
}
guard let identity else { fail("no \"\(name)\" identity") }

// SecCodeSigner isn't in the public headers, but it's what codesign calls
let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW)
guard let createSymbol = dlsym(security, "SecCodeSignerCreate"), let addSymbol = dlsym(security, "SecCodeSignerAddSignature"),
      let identityKey = dlsym(security, "kSecCodeSignerIdentity")?.load(as: CFString.self) else {
    fail("this macOS has no SecCodeSigner")
}
typealias Create = @convention(c) (CFDictionary, UInt32, UnsafeMutablePointer<CFTypeRef?>) -> OSStatus
typealias Add = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> OSStatus

var code: SecStaticCode?
guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: app) as CFURL, [], &code) == errSecSuccess, let code else {
    fail("can't read \(app)")
}
var signer: CFTypeRef?
let created = unsafeBitCast(createSymbol, to: Create.self)([identityKey: identity] as CFDictionary, 0, &signer)
guard created == errSecSuccess, let signer else { fail("can't set up signing (\(created))") }
let signed = unsafeBitCast(addSymbol, to: Add.self)(signer, code, 0)
guard signed == errSecSuccess else { fail("signing failed (\(signed))") }
