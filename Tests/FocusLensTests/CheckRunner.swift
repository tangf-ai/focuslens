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
            ("空目标启动及到期调度", tests.testCompletionTimerOnlyArmedWhileRunning)
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
        print("\(checks.count + 3) 项检查，\(failureCount) 个失败")
        if failureCount > 0 { exit(1) }
    }
}
