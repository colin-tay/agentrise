// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import Foundation
@testable import Agentrise

struct RankBookTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rankbook-\(UUID().uuidString)").appendingPathComponent("ranks.json")
    }

    @Test func defaultsMatchTodaysMapping() {
        let b = RankBook.defaults
        #expect(b.rank(for: "claude-fable-5-1") == .seniorDirector)
        #expect(b.rank(for: "claude-opus-5-5") == .seniorExpert)
        #expect(b.rank(for: "claude-haiku-5-5") == .newGrad)
        #expect(b.rank(for: "claude-sonnet-5-5") == .seniorEngineer)
        #expect(b.rank(for: nil) == .seniorEngineer)
        #expect(b.rank(for: "gpt-5.5") == .seniorEngineer)
        #expect(b.title(.seniorEngineer) == "高级工程师")
        #expect(b.title(.seniorDirector) == "资深总监")
        #expect(b.title(.seniorExpert) == "高级专家")
        #expect(b.title(.newGrad) == "校招生")
    }

    @Test func userKeywordsAndNamesApply() {
        var b = RankBook.defaults
        b.keywords[Rank.seniorExpert.rawValue] = ["opus", "GPT-5.5-PRO"]
        b.names[Rank.seniorExpert.rawValue] = "首席"
        #expect(b.rank(for: "gpt-5.5-pro") == .seniorExpert)
        #expect(b.title(.seniorExpert) == "首席")
    }

    @Test func emptyNameFallsBackToDefault() {
        var b = RankBook.defaults
        b.names[Rank.newGrad.rawValue] = "  "
        b.names.removeValue(forKey: Rank.seniorExpert.rawValue)
        #expect(b.title(.newGrad) == "校招生")
        #expect(b.title(.seniorExpert) == "高级专家")
    }

    @Test func corruptOrMissingFileFallsBackToDefaults() throws {
        let url = tempFile()
        #expect(RankBook.load(from: url) == .defaults)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{".write(to: url, atomically: true, encoding: .utf8)
        #expect(RankBook.load(from: url) == .defaults)
    }

    @Test func fileWithOnlyOneOfNamesOrKeywordsKeepsTheOtherDefault() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"names": {"seniorExpert": "首席"}}"#.write(to: url, atomically: true, encoding: .utf8)
        var b = RankBook.load(from: url)
        #expect(b.title(.seniorExpert) == "首席")
        #expect(b.rank(for: "claude-opus-5-5") == .seniorExpert)
        try #"{"keywords": {"newGrad": ["mini"]}}"#.write(to: url, atomically: true, encoding: .utf8)
        b = RankBook.load(from: url)
        #expect(b.rank(for: "gpt-mini") == .newGrad)
        #expect(b.title(.newGrad) == "校招生")
    }

    @Test func saveThenLoadRoundTrips() throws {
        let url = tempFile()
        var b = RankBook.defaults
        b.set(.seniorExpert, name: " 首席 ", keywordText: "opus， gpt-5.5-pro,, ")
        try b.save(to: url)
        #expect(RankBook.load(from: url) == b)
        #expect(b.title(.seniorExpert) == "首席")
        #expect(b.keywords[Rank.seniorExpert.rawValue] == ["opus", "gpt-5.5-pro"])
        #expect(b.keywordText(.seniorExpert) == "opus, gpt-5.5-pro")
    }

    @Test func blankKeywordNeverMatchesEverything() {
        var b = RankBook.defaults
        b.keywords[Rank.seniorDirector.rawValue] = ["", "  "]
        #expect(b.rank(for: "claude-sonnet-5-5") == .seniorEngineer)
    }

    @Test func orderDirectorBeforeExpertBeforeNewGrad() {
        var b = RankBook.defaults
        b.keywords[Rank.newGrad.rawValue] = ["mini"]
        b.keywords[Rank.seniorExpert.rawValue] = ["mini"]
        #expect(b.rank(for: "gpt-mini") == .seniorExpert)
        b.keywords[Rank.seniorDirector.rawValue] = ["mini"]
        #expect(b.rank(for: "gpt-mini") == .seniorDirector)
    }

    /// Touches the process-wide book, so it only adds a keyword no other test uses and leaves the names alone.
    @Test func currentDrivesRankFromAndRerank() {
        let saved = RankBook.current
        defer { RankBook.current = saved }
        let model = "zz-rankbook-test-model"
        #expect(Rank.from(model: model) == .seniorEngineer)
        var b = RankBook.current
        b.keywords[Rank.seniorExpert.rawValue, default: []].append("ZZ-RankBook-Test")
        RankBook.current = b
        #expect(Rank.from(model: model) == .seniorExpert)

        // A session that remembered its model is re-ranked after the book changes; one without a model is left alone.
        RankBook.current = saved
        var store = TowerStore()
        let now = Date()
        var known = SessionContext(); known.model = model
        store.ensure("a", context: known, now: now)
        store.ensure("b", context: SessionContext(), now: now)
        #expect(store.sessions["a"]?.model == model)
        #expect(store.sessions["a"]?.rank == .seniorEngineer)
        RankBook.current = b
        store.rerank()
        #expect(store.sessions["a"]?.rank == .seniorExpert)
        #expect(store.sessions["b"]?.rank == .seniorEngineer)
        #expect(store.sessions["b"]?.model == nil)
    }
}
