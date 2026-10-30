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
            ("损坏文件保护", tests.testCorruptedFileIsNotOverwritten),
            ("旧版数据备份及迁移", tests.testLegacyDataMigrationBacksUpAndPreservesRecords),
            ("SSE事件边界和错误解析", tests.testStreamParserSupportsSSEFraming),
            ("追问快照与未完成轮次隔离", tests.testConversationSnapshotAndIncompleteTurns),
            ("旧复盘兼容与中断恢复", tests.testReviewArchiveCompatibilityAndInterruptedRecovery),
            ("秒级采样兼容与切换应用调度", tests.testSecondSamplingCompatibilityAndCadence),
            ("个人活动说明兼容持久化与图片请求", tests.testPersonalGuidanceCompatibilityAndRequest),
            ("活动说明独立自动保存、恢复默认与写入失败", tests.testGuidanceAutosaveWithoutModelAndSettingsIsolation),
            ("无操作设置兼容与原生空闲计数", tests.testInactivityDefaultsCompatibilityAndNativeCounter),
            ("自动时间段合并与离线间隔", tests.testActivityLedgerBoundariesAndRestart),
            ("旧分类兼容与活动跨日", tests.testActivityMidnightAndCorrection),
            ("视觉分类严格解析", tests.testVisionParsingAndTextOnlyRejection),
            ("未识别原因兼容、分布守恒及小结隔离", tests.testUnknownReasonCompatibilityAndHonestDistribution),
            ("短等待吸收边界与历史不回填", tests.testShortWaitResolutionIsBoundedAndNeverRewritesHistory),
            ("失败重试退避及诊断脱敏", tests.testRecognitionRetryAndSanitizedErrorCodes),
            ("图片内存编码与图片请求", tests.testMemoryImageEncodingAndRequest),
            ("自动复盘不虚构完成率", tests.testAutomaticReviewNeverInventsCompletion),
            ("左侧竖屏与拔屏后浮窗恢复", tests.testPortraitDisplayAndRemovedDisplayRecovery),
            ("浮窗跨屏面积选择与点坐标", tests.testPanelPlacementUsesDominantDisplayAndPoints),
            ("多屏前台窗口选择与断屏过滤", tests.testCaptureSelectsFrontWindowAcrossDisplays),
            ("多屏截图过滤其他应用与覆盖窗口", tests.testCaptureSkipsUnrelatedOverlayAndHiddenWindows),
            ("外观默认值持久化与配置隔离", tests.testAppearanceDefaultsPersistenceAndIsolation),
            ("外观损坏保护与主题观察更新", tests.testAppearanceCorruptionAndObservation),
            ("动画节能策略与主题文字对比度", tests.testDecorativeMotionPolicyAndThemeContrast),
            ("轻量浮窗各主题布局", tests.testFloatingAppearanceLayoutsAndFrozenMotion),
            ("自动版迁移停止旧轮次并完整备份", tests.testAutomaticOnlyMigrationFreezesAndArchivesWithoutInventingFeedback),
            ("未来数据版本保护与导出拒绝", tests.testFutureSchemaIsProtectedAndExportFailsClosed),
            ("仅自动记录的旧安装也完整备份", tests.testMigrationAlsoBacksUpAutomaticOnlyInstallations),
            ("同类相邻片段合并且不跨空白", tests.testActivityDisplayMergesOnlyContinuousSameApplicationAndCategory),
            ("自动周统计未来留空与跨日拆分", tests.testAutomaticWeeklyTotalsExcludeFutureAndSplitMidnight),
            ("小结时段上限与错过调度不补发", tests.testSummaryPolicyCapsSlotsAndSkipsMissedSchedules),
            ("统一导出历史文件与清除前备份", tests.testUnifiedExportIncludesOldFilesAndClearBacksUpWithoutDeletingLegacy)
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
        let streamingChecks: [(String, () async throws -> Void)] = [
            ("真实HTTP流式传输和异常", tests.testRealStreamingTransportAndFailures),
            ("流式取消保留已收文字", tests.testStreamingCancellationRetainsText),
            ("屏幕变化找回隐藏浮窗且不自动显示", tests.testScreenChangeRecoversHiddenPanelWithoutShowingIt),
            ("后台识别保留活动与等待状态区分", tests.testBackgroundRecognitionKeepsConfirmedActivity),
            ("说明保存后相同画面重识别与旧结果取消", tests.testGuidanceSaveInvalidatesImageCacheAndCancelsOldResult),
            ("空闲边界暂停恢复且不再补记", tests.testInactivityPausesAtBoundaryResumesAndConfirmsOnce),
            ("静态阅读视频豁免与主动暂停优先", tests.testInactivityReadingVideoExemptionAndManualPause),
            ("阅读较长等待与进程挂起不补记", tests.testInactivityReadingUsesLongerDefaultAndNoOfflineFill),
            ("空闲丢弃迟到响应与锁屏不补记", tests.testInactivityLateResultLockAndAwayDecision),
            ("空闲确认跨日崩溃恢复与损坏保护", tests.testInactivityCrashRecoveryMidnightAndCorruptJournal),
            ("自动记录授权与排除门槛", tests.testAutomaticConsentAndPrivacyGates),
            ("单次识别取消与截图不落盘", tests.testAutomaticSingleFlightCancellationAndMemoryOnly),
            ("自动断连与历史文件不覆盖", tests.testAutomaticFailureAndHistoricalSafety),
            ("同窗口短等待吸收且不丢时长", tests.testSameWindowShortWaitIsAbsorbedWithoutLosingTime),
            ("不同窗口及长等待不回填", tests.testChangedWindowAndLongWaitAreNotBackfilled),
            ("异常恢复保留原片段并区分证据不足", tests.testFailureRecoveryPreservesFailureAndSeparatesModelUncertainty),
            ("取消不串应用且诊断不含敏感内容", tests.testCancelledAttemptNeverClassifiesAnotherAppOrLeaksContent),
            ("诊断上限、损坏保护及备份清理", tests.testDiagnosticRetentionAndCorruptionDoNotDamageActivities),
            ("真实HTTP视觉图片与能力检测", tests.testVisionWireCapabilityContract),
            ("图片请求不跟随重定向", tests.testVisionRedirectNeverForwardsImage),
            ("小结独立授权、证据去重和每天三次", tests.testSummaryNeedsIndependentConsentAndChangedEvidence),
            ("小结失败保留旧结果及重启预算", tests.testSummaryFailureKeepsOldReportAndBudgetSurvivesRestart),
            ("小结取消、换服务与迟到结果隔离", tests.testSummaryCancellationAndServiceChangeNeverAcceptLateResults),
            ("小结损坏和写入失败不发送", tests.testSummaryCorruptAndUnwritableFilesNeverSend),
            ("小结真实HTTP文字契约与禁止重定向", tests.testSummaryRealHTTPUsesOnlyTextAndRejectsRedirects),
            ("暂停记录取消小结且保留次数", tests.testPausingRecordingCancelsSummaryAndDoesNotResetBudget)
        ]
        for (name, check) in streamingChecks {
            let before = failureCount
            do { try await check() } catch { fail("\(error)", file: #filePath, line: #line) }
            print("\(before == failureCount ? "PASS" : "FAIL") \(name)")
        }
        print("\(checks.count + 2 + streamingChecks.count) 项检查，\(failureCount) 个失败")
        if failureCount > 0 { exit(1) }
    }
}
