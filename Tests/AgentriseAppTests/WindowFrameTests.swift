// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import AppKit
@testable import AgentriseApp

/// The main window's saved and `--frame` positions (they lived in `TowerSceneInteractionTests`).
@MainActor
@Suite struct WindowFrameTests {
    @Test func savedFramePrefersOwnKeyAndMigratesAutosave() {
        let d = UserDefaults(suiteName: "agentrise.tests.\(UUID().uuidString)")!
        #expect(AppDelegate.savedFrame(d) == nil)
        d.set("-1512 -147 1512 944 -1512 -147 1512 944 ", forKey: "NSWindow Frame AgentriseMain")
        #expect(AppDelegate.savedFrame(d) == NSRect(x: -1512, y: -147, width: 1512, height: 944))
        d.set(NSStringFromRect(NSRect(x: 1920, y: -776, width: 1080, height: 1895)), forKey: AppDelegate.frameKey)
        #expect(AppDelegate.savedFrame(d) == NSRect(x: 1920, y: -776, width: 1080, height: 1895))
        d.set("garbage", forKey: AppDelegate.frameKey)
        #expect(AppDelegate.savedFrame(d) == nil)
    }

    @Test func savedFrameMustStillLieOnAScreen() {
        let screens = [NSRect(x: 0, y: 0, width: 1920, height: 1080), NSRect(x: -1512, y: -147, width: 1512, height: 982)]
        #expect(AppDelegate.isOnScreen(NSRect(x: -1512, y: -147, width: 1512, height: 944), screens: screens))
        #expect(!AppDelegate.isOnScreen(NSRect(x: 1920, y: -776, width: 1080, height: 1895), screens: screens))  // portrait unplugged
        #expect(!AppDelegate.isOnScreen(NSRect(x: 1880, y: 0, width: 800, height: 600), screens: screens))      // only a 40 pt sliver
    }

    @Test func devFrameNeedsFourNumbersAndAPositiveSize() {
        #expect(AppDelegate.devFrame(["x", "--frame", "-1500,-130,1000,900"]) == NSRect(x: -1500, y: -130, width: 1000, height: 900))
        #expect(AppDelegate.devFrame(["x", "--frame", " 1, 2 ,3,4"]) == NSRect(x: 1, y: 2, width: 3, height: 4))
        for bad in ["1,2,3", "1,2,3,4,5", "1,,3,4", "1,2,0,4", "1,2,3,-4", "a,2,3,4"] {
            #expect(AppDelegate.devFrame(["x", "--frame", bad]) == nil, "\(bad)")
        }
        #expect(AppDelegate.devFrame(["x", "--frame"]) == nil)
        #expect(AppDelegate.devFrame(["x"]) == nil)
    }
}
