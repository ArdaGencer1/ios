import Foundation
public typealias OSStatus = Int32
public let errSecSuccess: OSStatus = 0
public typealias CFTypeRef = AnyObject
public protocol _CFDictionaryLike {}
extension Dictionary: _CFDictionaryLike {}
public typealias CFDictionary = any _CFDictionaryLike
public let kSecClass = "class", kSecClassGenericPassword = "genp", kSecAttrAccount = "acct"
public let kSecAttrAccessible = "pdmn", kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly = "cku"
public let kSecReturnData = "r_Data", kSecMatchLimit = "m_Limit", kSecMatchLimitOne = "m_LimitOne", kSecValueData = "v_Data"
@discardableResult public func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { 0 }
@discardableResult public func SecItemDelete(_ query: CFDictionary) -> OSStatus { 0 }
@discardableResult public func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { 0 }
