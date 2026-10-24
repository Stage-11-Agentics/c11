// C11-317: split out of CLI/c11.swift by scripts/split-cli.py.
import Foundation
import CryptoKit
import Darwin
import SQLite3
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

struct WindowInfo {
    let index: Int
    let id: String
    let key: Bool
    let selectedWorkspaceId: String?
    let workspaceCount: Int
}

struct NotificationInfo {
    let id: String
    let workspaceId: String
    let surfaceId: String?
    let isRead: Bool
    let title: String
    let subtitle: String
    let body: String
}
