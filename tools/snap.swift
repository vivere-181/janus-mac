import Foundation
// Usage: swift snap.swift <what> — asks the running Android UI to snapshot itself.
DistributedNotificationCenter.default().postNotificationName(.init("local.android-ui.snapshot"), object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)
