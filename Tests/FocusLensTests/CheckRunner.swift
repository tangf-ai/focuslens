import Foundation

private let checkLock = NSLock()
private var failureCount = 0
private func fail(_ message: String, file: StaticString, line: UInt) {
    checkLock.lock()
    failureCount += 1
    print("FAIL \(file):\(line) \(message)")
    checkLock.unlock()
}
func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line) {
    if lhs != rhs { fail("\(lhs) != \(rhs)", file: file, line: line) }
}
func XCTAssertEqual(_ lhs: Double, _ rhs: Double, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    if abs(lhs - rhs) > accuracy { fail("\(lhs) != \(rhs)", file: file, line: line) }
}
func XCTAssertTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { if !value { fail("expected true", file: file, line: line) } }
func XCTAssertFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { if value { fail("expected false", file: file, line: line) } }
func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { if value != nil { fail("expected nil", file: file, line: line) } }
func XCTAssertNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { if value == nil { fail("expected non-nil", file: file, line: line) } }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression(); fail("expected error", file: file, line: line) } catch { }
}
struct UnwrapError: Error { }
func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { fail("unexpected nil", file: file, line: line); throw UnwrapError() }
    return value
}

@main
struct CheckRunner {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        let tests = FocusLensTests()
        let checks: [(String, () throws -> Void)] = [
            ("暂停扣时与中断计数", tests.testPauseExcludesIdleTimeAndOnlyCountsOnce),
            ("睡眠及延迟恢复", tests.testSleepOrDelayedTickCapsElapsedAtDeadline),
            ("时钟回拨", tests.testBackwardsClockCannotCreateNegativeTime),
            ("休息不计专注中断", tests.testBreakPauseIsNotAFocusInterruption),
            ("完成率与缺失评分", tests.testStatsDoNotCountPartialAsCompletedOrMissingRatingAsZero),
            ("上海时区周界与排他结束", tests.testWeekStartsMondayAndEndIsExclusive),
            ("计时和反馈持久化", tests.testActiveAndPendingStateRoundTrip),
            ("接口地址与密钥拒绝规则", tests.testEndpointAcceptsBaseAndFullPathAndRejectsEmbeddedSecrets),
            ("AI数据范围及提示约束", tests.testAIPayloadContainsOnlySelectedEvidenceAndSafeguards),
            ("重启恢复到期记录", tests.testStoreRecoversExpiredTimerAndPersistsFeedback),
            ("提前结束及防止重叠", tests.testEarlyFinishPausedRunExcludesPauseAndPreventsOverlap),
            ("损坏文件保护", tests.testCorruptedFileIsNotOverwritten),
            ("空目标启动及到期调度", tests.testCompletionTimerOnlyArmedWhileRunning),
            ("旧版数据备份及迁移", tests.testLegacyDataMigrationBacksUpAndPreservesRecords),
            ("标签改名删除保留记录及复盘快照", tests.testCustomTagRenameDeleteKeepsHistoryAndMarksReviewStale),
            ("标签重名校验及失败不写入", tests.testTagValidationRejectsDuplicatesWithoutWriting),
            ("删除全部标签后无标签计时", tests.testDeletingAllTagsPersistsAndAllowsUntaggedFocus),
            ("专注时长下限与选择持久化", tests.testFocusDurationBoundsAndSelectionPersistence),
            ("SSE事件边界和错误解析", tests.testStreamParserSupportsSSEFraming),
            ("追问快照与未完成轮次隔离", tests.testConversationSnapshotAndIncompleteTurns),
            ("旧复盘兼容与中断恢复", tests.testReviewArchiveCompatibilityAndInterruptedRecovery),
            ("秒级采样兼容与切换应用调度", tests.testSecondSamplingCompatibilityAndCadence),
            ("自动时间段合并与离线间隔", tests.testActivityLedgerBoundariesAndRestart),
            ("自动跨日与人工修正", tests.testActivityMidnightAndCorrection),
            ("视觉分类严格解析", tests.testVisionParsingAndTextOnlyRejection),
            ("图片内存编码与图片请求", tests.testMemoryImageEncodingAndRequest),
            ("自动复盘不虚构完成率", tests.testAutomaticReviewNeverInventsCompletion),
            ("左侧竖屏与拔屏后浮窗恢复", tests.testPortraitDisplayAndRemovedDisplayRecovery),
            ("浮窗跨屏面积选择与点坐标", tests.testPanelPlacementUsesDominantDisplayAndPoints),
            ("多屏前台窗口选择与断屏过滤", tests.testCaptureSelectsFrontWindowAcrossDisplays),
            ("多屏截图过滤其他应用与覆盖窗口", tests.testCaptureSkipsUnrelatedOverlayAndHiddenWindows)
        ]
        for (name, check) in checks {
            let before = failureCount
            do { try check() } catch { fail("\(error)", file: #filePath, line: #line) }
            print("\(before == failureCount ? "PASS" : "FAIL") \(name)")
        }
        let before = failureCount
        do { try await tests.testAIParsesResponseAndSendsAuthorization() }
        catch { fail("\(error)", file: #filePath, line: #line) }
        print("\(before == failureCount ? "PASS" : "FAIL") AI模拟请求与响应")
        let beforeErrors = failureCount
        do { try await tests.testAIDeniedAndEmptyResponseAreReported() }
        catch { fail("\(error)", file: #filePath, line: #line) }
        print("\(beforeErrors == failureCount ? "PASS" : "FAIL") AI鉴权失败与空响应")
        let beforeDeadline = failureCount
        do { try await tests.testDeadlineFiresWithoutCountdownView() }
        catch { fail("\(error)", file: #filePath, line: #line) }
        print("\(beforeDeadline == failureCount ? "PASS" : "FAIL") 无界面刷新仍按期完成")
        let streamingChecks: [(String, () async throws -> Void)] = [
            ("真实HTTP流式传输和异常", tests.testRealStreamingTransportAndFailures),
            ("流式取消保留已收文字", tests.testStreamingCancellationRetainsText),
            ("多轮追问快照与保存恢复", tests.testStoreStreamingConversationPersistence),
            ("屏幕变化找回隐藏浮窗且不自动显示", tests.testScreenChangeRecoversHiddenPanelWithoutShowingIt),
            ("后台识别保留活动与等待状态区分", tests.testBackgroundRecognitionKeepsConfirmedActivity),
            ("自动记录授权与排除门槛", tests.testAutomaticConsentAndPrivacyGates),
            ("单次识别取消与截图不落盘", tests.testAutomaticSingleFlightCancellationAndMemoryOnly),
            ("自动断连与历史文件不覆盖", tests.testAutomaticFailureAndHistoricalSafety),
            ("真实HTTP视觉图片与能力检测", tests.testVisionWireCapabilityContract),
            ("图片请求不跟随重定向", tests.testVisionRedirectNeverForwardsImage)
        ]
        for (name, check) in streamingChecks {
            let before = failureCount
            do { try await check() } catch { fail("\(error)", file: #filePath, line: #line) }
            print("\(before == failureCount ? "PASS" : "FAIL") \(name)")
        }
        print("\(checks.count + 3 + streamingChecks.count) 项检查，\(failureCount) 个失败")
        if failureCount > 0 { exit(1) }
    }
}
