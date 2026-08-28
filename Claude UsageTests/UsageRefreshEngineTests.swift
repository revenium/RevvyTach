import Combine
import Foundation
import UsageCore
import XCTest
@testable import Claude_Usage

@MainActor
final class UsageRefreshEngineTests: HostedAppTestCase {
    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func withValue<Result>(
            _ body: (inout Value) -> Result
        ) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }

        func snapshot() -> Value {
            withValue { $0 }
        }
    }

    private final class ManualGate<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations:
            [CheckedContinuation<Value, Never>] = []
        private var value: Value?
        private let starts = Locked(0)

        func wait() async -> Value {
            starts.withValue { $0 += 1 }
            return await withCheckedContinuation { continuation in
                lock.lock()
                if let value {
                    lock.unlock()
                    continuation.resume(returning: value)
                } else {
                    continuations.append(continuation)
                    lock.unlock()
                }
            }
        }

        func resolve(_ value: Value) {
            lock.lock()
            guard self.value == nil else {
                lock.unlock()
                return
            }
            self.value = value
            let continuations = self.continuations
            self.continuations.removeAll()
            lock.unlock()
            for continuation in continuations {
                continuation.resume(returning: value)
            }
        }

        var startCount: Int {
            starts.snapshot()
        }
    }

    private final class CancellationGate<Value>: @unchecked Sendable {
        private enum GateError: Error {
            case cancelled
        }

        private let lock = NSLock()
        private var continuation:
            CheckedContinuation<Value, Error>?
        private var result: Result<Value, Error>?
        private let starts = Locked(0)
        private let onExit: @Sendable () -> Void

        init(
            onExit: @escaping @Sendable () -> Void = {}
        ) {
            self.onExit = onExit
        }

        func wait() async throws -> Value {
            starts.withValue { $0 += 1 }
            defer { onExit() }
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation {
                    continuation in
                    lock.lock()
                    if let result {
                        lock.unlock()
                        continuation.resume(with: result)
                    } else {
                        self.continuation = continuation
                        lock.unlock()
                    }
                }
            } onCancel: {
                self.finish(.failure(GateError.cancelled))
            }
        }

        func resolve(_ value: Value) {
            finish(.success(value))
        }

        private func finish(_ result: Result<Value, Error>) {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }

        var startCount: Int {
            starts.snapshot()
        }
    }

    private final class BatchRecorder: @unchecked Sendable {
        private let results = Locked<[UsageRefreshBatchResult]>([])

        func append(_ result: UsageRefreshBatchResult) {
            results.withValue { $0.append(result) }
        }

        var snapshot: [UsageRefreshBatchResult] {
            results.snapshot()
        }
    }

    /// A test-controlled clock so backoff-window math can be exercised
    /// without real sleeps: the engine's `now` closure reads this instead
    /// of the wall clock, and tests advance it explicitly.
    private final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date

        init(_ date: Date) {
            self.date = date
        }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return date
        }

        func advance(by interval: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            date = date.addingTimeInterval(interval)
        }
    }

    @MainActor
    private final class FakeCommitter: UsageRefreshCommitting {
        private let ledger: UsageRefreshInputLedger
        private var identities: [UUID: ProviderRefreshIdentity] = [:]
        private var usageByProfile: [UUID: ProfileCurrentUsage] = [:]

        var commitGate: ManualGate<Void>?
        var providerCommitGate: ManualGate<Void>?
        var apiCommitGate: ManualGate<Void>?
        var postCommitGate: ManualGate<Void>?
        var failureGate: ManualGate<Void>?
        var presentationGate: ManualGate<Void>?
        var forcedCommitError: UsageRefreshCommitError?
        private(set) var commitAttempts: [UsageRefreshCommitCandidate] = []
        private(set) var durableCommits:
            [(UsageRefreshCommitCandidate, UsageRefreshCommitReceipt)] = []
        private(set) var acceptedPublications:
            [(UsageRefreshCommitCandidate, UsageRefreshCommitReceipt)] = []
        private(set) var presentedPublications:
            [(UsageRefreshCommitCandidate, UsageRefreshCommitReceipt)] = []
        private(set) var failurePublications:
            [UsageRefreshFailureCandidate] = []

        init(ledger: UsageRefreshInputLedger) {
            self.ledger = ledger
        }

        func register(
            _ identity: ProviderRefreshIdentity,
            usage: ProfileCurrentUsage? = nil
        ) {
            identities[identity.profileID] = identity
            if let usage {
                usageByProfile[identity.profileID] = usage
            }
            ledger.register(profileIDs: [identity.profileID])
        }

        func replaceIdentity(_ identity: ProviderRefreshIdentity) {
            identities[identity.profileID] = identity
        }

        func cachedUsage(for profileID: UUID) -> ProfileCurrentUsage? {
            usageByProfile[profileID]
        }

        func loadCurrentUsage(
            for identity: ProviderRefreshIdentity
        ) throws -> ProfileCurrentUsage? {
            try validate(identity)
            return usageByProfile[identity.profileID]
        }

        func currentInputGeneration(for profileID: UUID) -> UInt64 {
            ledger.generation(for: profileID)
        }

        func commit(
            _ candidate: UsageRefreshCommitCandidate
        ) async throws -> UsageRefreshCommitReceipt {
            commitAttempts.append(candidate)
            if let commitGate {
                _ = await commitGate.wait()
            }
            if candidate.acceptedComponents == [.providerUsage],
               let providerCommitGate {
                _ = await providerCommitGate.wait()
            }
            if candidate.acceptedComponents == [.claudeAPI],
               let apiCommitGate {
                _ = await apiCommitGate.wait()
            }
            if let forcedCommitError {
                throw forcedCommitError
            }
            try validate(candidate.identity)
            guard ledger.generation(
                for: candidate.identity.profileID
            ) == candidate.inputGeneration else {
                throw UsageRefreshCommitError.inputInvalidated
            }
            let invocationOrder = ledger.invocationOrder(
                for: candidate.identity.profileID
            )
            guard invocationOrder == 0
                    || invocationOrder
                        == candidate.invocationOrder else {
                throw UsageRefreshCommitError.inputInvalidated
            }

            let previous = usageByProfile[candidate.identity.profileID]
            var current = previous ?? ProfileCurrentUsage(
                providerID: candidate.identity.providerID,
                providerRevision: candidate.identity.providerRevision
            )
            current.providerID = candidate.identity.providerID
            current.providerRevision = candidate.identity.providerRevision
            if candidate.acceptedComponents.contains(.providerUsage),
               let result = candidate.providerResult {
                current.report = result.report
                current.claudeUsage = result.claudeUsage
                if candidate.identity.providerID != .claude {
                    current.apiUsage = nil
                }
            }
            if candidate.acceptedComponents.contains(.claudeAPI) {
                current.apiUsage = candidate.apiUsage
            }

            let acceptedEvent = AcceptedUsageRefreshEvent(
                sequence: UInt64(acceptedPublications.count + 1),
                identity: candidate.identity,
                inputGeneration: candidate.inputGeneration,
                invocationOrder: candidate.invocationOrder,
                profileName: candidate.profileName,
                notificationSettings:
                    candidate.notificationSettings,
                trigger: candidate.trigger,
                presentationContext:
                    candidate.presentationContext,
                capabilities: candidate.capabilities,
                previousUsage: previous,
                currentUsage: current,
                acceptedComponents:
                    candidate.acceptedComponents,
                committedAt: TestValues.now
            )
            let receipt = UsageRefreshCommitReceipt(
                previousUsage: previous,
                currentUsage: current,
                committedAt: TestValues.now,
                acceptedEvent: acceptedEvent
            )
            usageByProfile[candidate.identity.profileID] = current
            durableCommits.append((candidate, receipt))
            // Model the live committer's one non-suspending MainActor turn:
            // verified persistence and accepted-event publication are one
            // atomic operation after the optional pre-commit suspension.
            acceptedPublications.append((candidate, receipt))
            if let postCommitGate {
                _ = await postCommitGate.wait()
            }
            return receipt
        }

        func publishFailure(
            _ candidate: UsageRefreshFailureCandidate,
            snapshot: PresentationSnapshot,
            presentationStore: UsagePresentationStore
        ) async -> Bool {
            if let failureGate {
                _ = await failureGate.wait()
            }
            guard ledger.generation(
                for: candidate.identity.profileID
            ) == candidate.inputGeneration else {
                return false
            }
            let invocationOrder = ledger.invocationOrder(
                for: candidate.identity.profileID
            )
            guard invocationOrder == 0
                    || invocationOrder
                        == candidate.invocationOrder else {
                return false
            }
            guard presentationStore.publish(
                snapshot,
                expected: candidate.presentationContext,
                invocationOrder: candidate.invocationOrder
            ) else {
                return false
            }
            guard ledger.generation(
                for: candidate.identity.profileID
            ) == candidate.inputGeneration else {
                return false
            }
            let publishedInvocationOrder = ledger.invocationOrder(
                for: candidate.identity.profileID
            )
            guard publishedInvocationOrder == 0
                    || publishedInvocationOrder
                        == candidate.invocationOrder else {
                return false
            }
            failurePublications.append(candidate)
            return true
        }

        func publishCommittedPresentation(
            _ candidate: UsageRefreshCommitCandidate,
            receipt: UsageRefreshCommitReceipt,
            snapshot: PresentationSnapshot,
            presentationStore: UsagePresentationStore
        ) async -> Bool {
            if let presentationGate {
                _ = await presentationGate.wait()
            }
            guard ledger.generation(
                for: candidate.identity.profileID
            ) == candidate.inputGeneration else {
                return false
            }
            let invocationOrder = ledger.invocationOrder(
                for: candidate.identity.profileID
            )
            guard invocationOrder == 0
                    || invocationOrder
                        == candidate.invocationOrder else {
                return false
            }
            guard presentationStore.publish(
                snapshot,
                expected: candidate.presentationContext,
                invocationOrder: candidate.invocationOrder
            ) else {
                return false
            }
            guard ledger.generation(
                for: candidate.identity.profileID
            ) == candidate.inputGeneration else {
                return false
            }
            let postPresentationOrder = ledger.invocationOrder(
                for: candidate.identity.profileID
            )
            guard postPresentationOrder == 0
                    || postPresentationOrder
                        == candidate.invocationOrder else {
                return false
            }
            presentedPublications.append((candidate, receipt))
            return true
        }

        private func validate(
            _ identity: ProviderRefreshIdentity
        ) throws {
            guard let current = identities[identity.profileID] else {
                throw UsageRefreshCommitError.profileUnavailable
            }
            guard current.providerID == identity.providerID else {
                throw UsageRefreshCommitError.providerMismatch
            }
            guard current.providerRevision
                    == identity.providerRevision else {
                throw UsageRefreshCommitError.providerRevisionMismatch
            }
        }
    }

    private struct Harness {
        let ledger: UsageRefreshInputLedger
        let committer: FakeCommitter
        let store: UsagePresentationStore
        let batches: BatchRecorder
        let engine: UsageRefreshEngine
    }

    private enum TestFailure: Error {
        case core
        case api
    }

    private enum OutcomeTag: Equatable {
        case accepted
        case failed
        case superseded
        case unavailable
        case backoffSkipped
    }

    private enum TestValues {
        static let now = Date(timeIntervalSinceReferenceDate: 90_000)
        static let requestDate =
            Date(timeIntervalSinceReferenceDate: 89_999)
    }

    func testRetryTriggerRawValueRoundTrips() throws {
        XCTAssertEqual(UsageRefreshTrigger.retry.rawValue, "retry")
        let data = try JSONEncoder().encode(UsageRefreshTrigger.retry)
        XCTAssertEqual(
            try JSONDecoder().decode(
                UsageRefreshTrigger.self,
                from: data
            ),
            .retry
        )
    }

    func testManualTriggerIsUserInitiatedButRetryIsNot() {
        XCTAssertTrue(UsageRefreshTrigger.manual.isUserInitiated)
        XCTAssertFalse(UsageRefreshTrigger.retry.isUserInitiated)
    }

    func testInvalidateAllMaterializesAuthoritativeProfiles() {
        let ledger = retain(UsageRefreshInputLedger())
        let first = UUID()
        let second = UUID()

        ledger.invalidateAll(authoritativeProfileIDs: [first, second])

        XCTAssertEqual(ledger.generation(for: first), 1)
        XCTAssertEqual(ledger.generation(for: second), 1)
    }

    func testInvalidateAllAlsoInvalidatesPreviouslyRegisteredProfiles() {
        let ledger = retain(UsageRefreshInputLedger())
        let first = UUID()
        let second = UUID()
        ledger.register(profileIDs: [first])

        ledger.invalidateAll(authoritativeProfileIDs: [second])

        XCTAssertEqual(ledger.generation(for: first), 1)
        XCTAssertEqual(ledger.generation(for: second), 1)
    }

    func testDeletionLifecycleRetainsTerminalTombstoneGeneration() {
        let ledger = retain(UsageRefreshInputLedger())
        let profileID = UUID()
        XCTAssertEqual(ledger.generation(for: profileID), 0)

        ledger.beginDeletion(profileID: profileID)
        XCTAssertTrue(ledger.isDeleting(profileID))
        XCTAssertEqual(ledger.generation(for: profileID), 1)

        ledger.completeDeletion(profileID: profileID)
        XCTAssertTrue(ledger.isDeleting(profileID))
        XCTAssertEqual(ledger.generation(for: profileID), 2)
    }

    func testSelfRemovingEventObserverIsSafe() throws {
        let hub = retain(UsageRefreshEventHub())
        var selfToken: UUID?
        var selfCalls = 0
        var persistentCalls = 0
        selfToken = hub.observe { _ in
            selfCalls += 1
            if let selfToken {
                hub.removeObserver(selfToken)
            }
        }
        _ = hub.observe { _ in
            persistentCalls += 1
        }

        let identity = makeIdentity()
        let usage = ProfileCurrentUsage(
            providerID: .codex,
            providerRevision: 0,
            report: try makeReport(providerID: .codex)
        )
        for _ in 0..<2 {
            _ = hub.publish(
                identity: identity,
                inputGeneration: 0,
                invocationOrder: 1,
                profileName: "Profile",
                notificationSettings: NotificationSettings(),
                trigger: .manual,
                presentationContext: makeContext(
                    visible: [identity.profileID]
                ),
                capabilities: ProviderCapabilities(),
                previousUsage: nil,
                currentUsage: usage,
                acceptedComponents: [.providerUsage],
                committedAt: TestValues.now
            )
        }

        XCTAssertEqual(selfCalls, 1)
        XCTAssertEqual(persistentCalls, 2)
    }

    func testEventSequenceIsStrictlyOrdered() throws {
        let hub = retain(UsageRefreshEventHub())
        let identity = makeIdentity()
        let usage = ProfileCurrentUsage(
            providerID: .codex,
            report: try makeReport(providerID: .codex)
        )

        let first = hub.publish(
            identity: identity,
            inputGeneration: 0,
            invocationOrder: 1,
            profileName: "Profile",
            notificationSettings: NotificationSettings(),
            trigger: .manual,
            presentationContext: makeContext(
                visible: [identity.profileID]
            ),
            capabilities: ProviderCapabilities(),
            previousUsage: nil,
            currentUsage: usage,
            acceptedComponents: [.providerUsage],
            committedAt: TestValues.now
        )
        let second = hub.publish(
            identity: identity,
            inputGeneration: 0,
            invocationOrder: 2,
            profileName: "Profile",
            notificationSettings: NotificationSettings(),
            trigger: .retry,
            presentationContext: makeContext(
                visible: [identity.profileID]
            ),
            capabilities: ProviderCapabilities(),
            previousUsage: usage,
            currentUsage: usage,
            acceptedComponents: [.providerUsage],
            committedAt: TestValues.now
        )

        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(second.sequence, 2)
    }

    func testAcceptedAndFailureObserversReceiveOnlyTheirEventOnce()
        throws
    {
        let hub = retain(UsageRefreshEventHub())
        let identity = makeIdentity()
        let usage = ProfileCurrentUsage(
            providerID: .codex,
            report: try makeReport(providerID: .codex)
        )
        var acceptedEvents: [AcceptedUsageRefreshEvent] = []
        var presentedEvents: [AcceptedUsageRefreshEvent] = []
        var failureEvents: [UsageRefreshFailureEvent] = []
        var batchEvents: [UsageRefreshBatchResult] = []
        _ = hub.observe { acceptedEvents.append($0) }
        _ = hub.observePresented { presentedEvents.append($0) }
        _ = hub.observeFailures { failureEvents.append($0) }
        _ = hub.observeBatches { batchEvents.append($0) }

        let accepted = hub.publish(
            identity: identity,
            inputGeneration: 0,
            invocationOrder: 1,
            profileName: "Profile",
            notificationSettings: NotificationSettings(),
            trigger: .manual,
            presentationContext: makeContext(
                visible: [identity.profileID]
            ),
            capabilities: ProviderCapabilities(),
            previousUsage: nil,
            currentUsage: usage,
            acceptedComponents: [.providerUsage],
            committedAt: TestValues.now
        )
        let failed = hub.publishFailure(
            UsageRefreshFailureCandidate(
                identity: identity,
                profileName: "Profile",
                inputGeneration: 4,
                invocationOrder: 1,
                trigger: .retry,
                presentationContext: makeContext(
                    visible: [identity.profileID]
                ),
                component: .providerUsage,
                failure: ProviderRefreshFailure(
                    kind: .transport,
                    occurredAt: TestValues.now,
                    isRecoverable: true,
                    consecutiveCount: 1
                )
            )
        )
        hub.publishPresented(accepted)
        let batchID = UUID()
        hub.publishBatch(
            UsageRefreshBatchResult(
                batchID: batchID,
                invocationOrder: 1,
                outcomes: [identity.profileID: .accepted],
                trigger: .manual,
                presentationContext: makeContext(
                    visible: [identity.profileID]
                ),
                isLatestBatch: true
            )
        )

        XCTAssertEqual(acceptedEvents.count, 1)
        XCTAssertEqual(presentedEvents.count, 1)
        XCTAssertEqual(failureEvents.count, 1)
        XCTAssertEqual(batchEvents.count, 1)
        XCTAssertEqual(failed.inputGeneration, 4)
        XCTAssertEqual(failureEvents.first?.inputGeneration, 4)
        XCTAssertTrue(batchEvents[0].isLatestBatch)
        XCTAssertEqual(
            acceptedEvents.first?.sequence,
            accepted.sequence
        )
        XCTAssertEqual(
            presentedEvents.first?.sequence,
            accepted.sequence
        )
        XCTAssertEqual(
            failureEvents.first?.sequence,
            failed.sequence
        )
        XCTAssertEqual(accepted.sequence, 1)
        XCTAssertEqual(failed.sequence, 2)
        XCTAssertEqual(batchEvents.first?.batchID, batchID)
        XCTAssertEqual(batchEvents.first?.invocationOrder, 1)
        XCTAssertEqual(
            batchEvents.first?.presentationContext.mode,
            .single
        )
    }

    func testSelfRemovingFailureObserverIsSafe() {
        let hub = retain(UsageRefreshEventHub())
        let identity = makeIdentity()
        var selfToken: UUID?
        var selfCalls = 0
        var persistentCalls = 0
        selfToken = hub.observeFailures { _ in
            selfCalls += 1
            if let selfToken {
                hub.removeObserver(selfToken)
            }
        }
        _ = hub.observeFailures { _ in
            persistentCalls += 1
        }
        let candidate = UsageRefreshFailureCandidate(
            identity: identity,
            profileName: "Profile",
            inputGeneration: 0,
            invocationOrder: 1,
            trigger: .manual,
            presentationContext: makeContext(
                visible: [identity.profileID]
            ),
            component: .providerUsage,
            failure: ProviderRefreshFailure(
                kind: .transport,
                occurredAt: TestValues.now,
                isRecoverable: true,
                consecutiveCount: 1
            )
        )

        _ = hub.publishFailure(candidate)
        _ = hub.publishFailure(candidate)

        XCTAssertEqual(selfCalls, 1)
        XCTAssertEqual(persistentCalls, 2)
    }

    func testPresentationStoreRejectsStaleContext() throws {
        let store = retain(UsagePresentationStore())
        let identity = makeIdentity()
        let current = makeContext(
            epoch: 2,
            visible: [identity.profileID]
        )
        store.activate(current)

        let accepted = store.publish(
            makeSnapshot(
                identity: identity,
                epoch: 1,
                report: try makeReport(providerID: .codex)
            ),
            expected: makeContext(
                epoch: 1,
                visible: [identity.profileID]
            )
        )

        XCTAssertFalse(accepted)
        XCTAssertNil(store.snapshot(for: identity.profileID))
    }

    func testPresentationStoreFiltersHydrationByVisibilityAndEpoch()
        throws
    {
        let visible = makeIdentity()
        let hidden = makeIdentity()
        let context = makeContext(
            epoch: 4,
            visible: [visible.profileID]
        )
        let store = retain(UsagePresentationStore())

        store.activate(
            context,
            hydrated: [
                visible.profileID: makeSnapshot(
                    identity: visible,
                    epoch: 4,
                    report: try makeReport(providerID: .codex)
                ),
                hidden.profileID: makeSnapshot(
                    identity: hidden,
                    epoch: 4,
                    report: try makeReport(providerID: .codex)
                )
            ]
        )

        XCTAssertNotNil(store.snapshot(for: visible.profileID))
        XCTAssertNil(store.snapshot(for: hidden.profileID))
    }

    func testCompletedActivityRejectsLateSameRequestRefreshingPublication()
        throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let requestID = UUID()
        let invocationOrder: UInt64 = 7
        let store = retain(UsagePresentationStore())
        store.activate(
            context,
            hydrated: [
                identity.profileID: makeSnapshot(
                    identity: identity,
                    epoch: context.epoch,
                    report: try makeReport(providerID: .codex)
                )
            ]
        )
        store.registerActivityInvocation(
            invocationOrder,
            profileIDs: [identity.profileID]
        )
        let refreshing = makeSnapshot(
            identity: identity,
            epoch: context.epoch,
            report: try makeReport(providerID: .codex),
            activity: .refreshing(
                requestID: requestID,
                trigger: .manual,
                startedAt: TestValues.now
            )
        )

        XCTAssertTrue(
            store.publish(
                refreshing,
                expected: context,
                invocationOrder: invocationOrder
            )
        )
        store.completeRefreshActivity(
            profileID: identity.profileID,
            requestID: requestID,
            invocationOrder: invocationOrder,
            replacement: .idle,
            replacementInvocationOrder: nil,
            expected: context
        )

        XCTAssertFalse(
            store.publish(
                refreshing,
                expected: context,
                invocationOrder: invocationOrder
            )
        )
        XCTAssertEqual(
            store.snapshot(for: identity.profileID)?.activity,
            .idle
        )
    }

    func testCompletedStatusRejectsLateSameOrderBegin() {
        let identity = makeIdentity(providerID: .claude)
        let context = makeContext(visible: [identity.profileID])
        let invocationOrder: UInt64 = 9
        let terminalStatus = ClaudeStatus(
            indicator: .minor,
            description: "Terminal"
        )
        let store = retain(UsagePresentationStore())
        store.activate(context)
        store.registerClaudeStatusInvocation(invocationOrder)

        XCTAssertTrue(
            store.publishClaudeStatus(
                terminalStatus,
                expected: context,
                invocationOrder: invocationOrder
            )
        )
        XCTAssertFalse(
            store.beginClaudeStatus(
                expected: context,
                invocationOrder: invocationOrder
            )
        )
        XCTAssertEqual(store.claudeStatus.status, terminalStatus)
        XCTAssertFalse(store.claudeStatus.isRefreshing)
    }

    func testContextActivationDoesNotDropInFlightStatusFetch()
        throws
    {
        // Claude service status is a single global value (one endpoint for
        // the whole service). Context churn during the network round trip
        // (profile switch, popover routing, display-mode/credential
        // changes, etc.) must not cause a completed fetch to be silently
        // dropped -- that was the root cause of the header getting stuck
        // on "Status Unknown" forever.
        let identity = makeIdentity(providerID: .claude)
        let oldContext = makeContext(
            epoch: 1,
            visible: [identity.profileID]
        )
        let newContext = makeContext(
            epoch: 2,
            visible: [identity.profileID]
        )
        let invocationOrder: UInt64 = 10
        let store = retain(UsagePresentationStore())
        store.activate(
            oldContext,
            hydrated: [
                identity.profileID: makeSnapshot(
                    identity: identity,
                    epoch: oldContext.epoch,
                    report: try makeReport(providerID: .claude)
                )
            ]
        )
        store.registerClaudeStatusInvocation(invocationOrder)
        XCTAssertTrue(
            store.beginClaudeStatus(
                expected: oldContext,
                invocationOrder: invocationOrder
            )
        )
        XCTAssertTrue(store.claudeStatus.isRefreshing)

        store.activate(
            newContext,
            hydrated: [
                identity.profileID: makeSnapshot(
                    identity: identity,
                    epoch: newContext.epoch,
                    report: try makeReport(providerID: .claude)
                )
            ]
        )

        XCTAssertEqual(
            store.claudeStatus.presentationEpoch,
            newContext.epoch
        )
        XCTAssertFalse(store.claudeStatus.isRefreshing)

        // The fetch that started under the old context completes after the
        // context churn. It must still be accepted (order still matches),
        // and the published presentation must carry the store's *current*
        // epoch rather than the stale context's epoch.
        XCTAssertTrue(
            store.publishClaudeStatus(
                .operational,
                expected: oldContext,
                invocationOrder: invocationOrder
            )
        )
        XCTAssertEqual(store.claudeStatus.status, .operational)
        XCTAssertEqual(
            store.claudeStatus.presentationEpoch,
            newContext.epoch
        )
        XCTAssertFalse(store.claudeStatus.isRefreshing)
    }

    func testStaleStatusFetchRejectedAfterNewerInvocationRegistered()
        throws
    {
        let identity = makeIdentity(providerID: .claude)
        let context = makeContext(visible: [identity.profileID])
        let store = retain(UsagePresentationStore())
        store.activate(
            context,
            hydrated: [
                identity.profileID: makeSnapshot(
                    identity: identity,
                    epoch: context.epoch,
                    report: try makeReport(providerID: .claude)
                )
            ]
        )

        // Invocation 1 begins but never completes before invocation 2 is
        // registered (e.g. a rapid refresh supersedes it).
        store.registerClaudeStatusInvocation(1)
        XCTAssertTrue(
            store.beginClaudeStatus(expected: context, invocationOrder: 1)
        )
        store.registerClaudeStatusInvocation(2)
        XCTAssertTrue(
            store.beginClaudeStatus(expected: context, invocationOrder: 2)
        )

        // The stale invocation-1 fetch completing afterward must not
        // publish over the newer, still in-flight invocation-2 fetch.
        XCTAssertFalse(
            store.publishClaudeStatus(
                .operational,
                expected: context,
                invocationOrder: 1
            )
        )
        XCTAssertTrue(store.claudeStatus.isRefreshing)

        XCTAssertTrue(
            store.publishClaudeStatus(
                .operational,
                expected: context,
                invocationOrder: 2
            )
        )
        XCTAssertFalse(store.claudeStatus.isRefreshing)
    }

    func testEmptyBatchCompletesImmediately() async {
        let context = makeContext()
        let harness = makeHarness(context: context)

        _ = await harness.engine.enqueue(
            [],
            trigger: .manual,
            presentationContext: context,
            inputGenerations: [:]
        )

        XCTAssertEqual(harness.batches.snapshot.count, 1)
        XCTAssertTrue(harness.batches.snapshot[0].outcomes.isEmpty)
    }

    func testUnavailableOnlyBatchCompletesImmediately() async {
        let profileID = UUID()
        let context = makeContext(visible: [profileID])
        let harness = makeHarness(context: context)

        _ = await harness.engine.enqueue(
            [],
            trigger: .manual,
            presentationContext: context,
            inputGenerations: [:],
            unavailableProfileIDs: [profileID]
        )

        XCTAssertEqual(harness.batches.snapshot.count, 1)
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0].outcomes[profileID]
            ),
            .unavailable
        )
    }

    func testSupersededOnlyBatchCompletesImmediately() async {
        let profileID = UUID()
        let context = makeContext(visible: [profileID])
        let harness = makeHarness(context: context)

        _ = await harness.engine.enqueue(
            [],
            trigger: .manual,
            presentationContext: context,
            inputGenerations: [:],
            supersededProfileIDs: [profileID]
        )

        XCTAssertEqual(harness.batches.snapshot.count, 1)
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0].outcomes[profileID]
            ),
            .superseded
        )
    }

    func testMixedUnavailableAndSuccessfulMembersCompleteOneBatch()
        async throws
    {
        let accepted = makeIdentity()
        let unavailable = UUID()
        let context = makeContext(
            visible: [accepted.profileID, unavailable]
        )
        let harness = makeHarness(
            identities: [accepted],
            context: context
        )
        let job = makeImmediateJob(
            identity: accepted,
            result: ProviderFetchResult(
                report: try makeReport(providerID: .codex)
            )
        )

        _ = await harness.engine.enqueue(
            [job],
            trigger: .manual,
            presentationContext: context,
            inputGenerations: [accepted.profileID: 0],
            unavailableProfileIDs: [unavailable]
        )
        let completed = await eventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertTrue(completed)
        let outcomes = harness.batches.snapshot[0].outcomes
        XCTAssertEqual(outcome(outcomes[accepted.profileID]), .accepted)
        XCTAssertEqual(outcome(outcomes[unavailable]), .unavailable)
    }

    func testSameProfileKeepsOnlyLatestPendingRequest()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let firstGate = ManualGate<ProviderFetchResult>()
        let latestGate = ManualGate<ProviderFetchResult>()
        let middleStarts = Locked(0)

        _ = await enqueue(
            makeGatedJob(identity: identity, gate: firstGate),
            on: harness,
            context: context
        )
        let firstStarted = await waitForStarts(firstGate, count: 1)
        XCTAssertTrue(firstStarted)

        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: {
                    middleStarts.withValue { $0 += 1 }
                    return ProviderFetchResult(
                        report: try Self.makeReport(
                            providerID: .codex,
                            marker: 2
                        )
                    )
                }
            ),
            on: harness,
            context: context
        )
        _ = await enqueue(
            makeGatedJob(identity: identity, gate: latestGate),
            on: harness,
            context: context
        )

        firstGate.resolve(
            ProviderFetchResult(
                report: try makeReport(
                    providerID: .codex,
                    marker: 1
                )
            )
        )
        let latestStarted = await waitForStarts(latestGate, count: 1)
        XCTAssertTrue(latestStarted)
        latestGate.resolve(
            ProviderFetchResult(
                report: try makeReport(
                    providerID: .codex,
                    marker: 3
                )
            )
        )
        await assertEventually {
            harness.batches.snapshot.count == 3
        }

        XCTAssertEqual(middleStarts.snapshot(), 0)
        XCTAssertEqual(harness.committer.durableCommits.count, 1)
        XCTAssertEqual(
            harness.committer.cachedUsage(
                for: identity.profileID
            )?.report?.usageSummary?.metrics.first?.value,
            3
        )
        let tags = harness.batches.snapshot.compactMap {
            outcome($0.outcomes[identity.profileID])
        }
        XCTAssertEqual(
            tags.filter { $0 == .superseded }.count,
            2
        )
        XCTAssertEqual(tags.filter { $0 == .accepted }.count, 1)
    }

    func testOverlappingTimerRefreshesKeepOnlyLatestPendingRequest()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let firstGate = ManualGate<ProviderFetchResult>()
        let latestGate = ManualGate<ProviderFetchResult>()

        _ = await enqueue(
            makeGatedJob(
                identity: identity,
                gate: firstGate,
                trigger: .timer
            ),
            on: harness,
            context: context
        )
        let firstStarted = await waitForStarts(firstGate, count: 1)
        XCTAssertTrue(firstStarted)

        _ = await enqueue(
            makeGatedJob(
                identity: identity,
                gate: latestGate,
                trigger: .timer
            ),
            on: harness,
            context: context
        )

        firstGate.resolve(
            ProviderFetchResult(
                report: try makeReport(
                    providerID: .codex,
                    marker: 1
                )
            )
        )
        let latestStarted = await waitForStarts(latestGate, count: 1)
        XCTAssertTrue(latestStarted)
        latestGate.resolve(
            ProviderFetchResult(
                report: try makeReport(
                    providerID: .codex,
                    marker: 2
                )
            )
        )
        await assertEventually {
            harness.batches.snapshot.count == 2
        }

        XCTAssertEqual(harness.committer.durableCommits.count, 1)
        XCTAssertEqual(
            harness.committer.cachedUsage(
                for: identity.profileID
            )?.report?.usageSummary?.metrics.first?.value,
            2
        )
        XCTAssertTrue(
            harness.batches.snapshot.allSatisfy {
                $0.trigger == .timer
            }
        )
        let outcomes = harness.batches.snapshot.compactMap {
            outcome($0.outcomes[identity.profileID])
        }
        XCTAssertEqual(outcomes.filter { $0 == .superseded }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .accepted }.count, 1)
    }

    func testDifferentProfilesFetchConcurrently() async throws {
        let first = makeIdentity()
        let second = makeIdentity()
        let context = makeContext(
            visible: [first.profileID, second.profileID]
        )
        // This test asserts the engine's underlying slot state machine can
        // run two profiles' fetches truly concurrently; it is orthogonal to
        // the fan-out stagger policy (covered separately), so disable it
        // here rather than couple this assertion to a specific delay.
        let harness = makeHarness(
            identities: [first, second],
            context: context,
            staggerPolicy: IndexedRefreshStaggerPolicy(step: 0)
        )
        let firstGate = ManualGate<ProviderFetchResult>()
        let secondGate = ManualGate<ProviderFetchResult>()

        _ = await harness.engine.enqueue(
            [
                makeGatedJob(identity: first, gate: firstGate),
                makeGatedJob(identity: second, gate: secondGate)
            ],
            trigger: .timer,
            presentationContext: context,
            inputGenerations: [
                first.profileID: 0,
                second.profileID: 0
            ]
        )

        let firstStarted = await waitForStarts(firstGate, count: 1)
        let secondStarted = await waitForStarts(secondGate, count: 1)
        XCTAssertTrue(firstStarted)
        XCTAssertTrue(secondStarted)
        firstGate.resolve(
            ProviderFetchResult(
                report: try makeReport(providerID: .codex)
            )
        )
        secondGate.resolve(
            ProviderFetchResult(
                report: try makeReport(providerID: .codex)
            )
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }
        XCTAssertEqual(harness.committer.durableCommits.count, 2)
    }

    func testInvocationOrderSurvivesEngineArrivalInversion()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let newerFetch = ManualGate<ProviderFetchResult>()
        let olderFetches = Locked(0)
        harness.ledger.registerInvocation(
            2,
            profileIDs: [identity.profileID]
        )

        _ = await harness.engine.enqueue(
            [
                makeGatedJob(
                    identity: identity,
                    gate: newerFetch
                )
            ],
            trigger: .retry,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 2
        )
        let newerStarted = await waitForStarts(
            newerFetch,
            count: 1
        )
        XCTAssertTrue(newerStarted)

        harness.ledger.registerInvocation(
            1,
            profileIDs: [identity.profileID]
        )
        _ = await harness.engine.enqueue(
            [
                makeJob(
                    identity: identity,
                    trigger: .manual,
                    coreFetch: {
                        olderFetches.withValue { $0 += 1 }
                        return ProviderFetchResult(
                            report: try Self.makeReport(
                                providerID: .codex,
                                marker: 1
                            )
                        )
                    }
                )
            ],
            trigger: .manual,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 1
        )
        await assertEventually {
            harness.batches.snapshot.contains {
                $0.invocationOrder == 1
            }
        }
        XCTAssertEqual(olderFetches.snapshot(), 0)

        newerFetch.resolve(
            ProviderFetchResult(
                report: try makeReport(
                    providerID: .codex,
                    marker: 2
                )
            )
        )
        await assertEventually {
            harness.batches.snapshot.count == 2
        }

        let olderBatch = harness.batches.snapshot.first {
            $0.invocationOrder == 1
        }
        let newerBatch = harness.batches.snapshot.first {
            $0.invocationOrder == 2
        }
        XCTAssertEqual(
            outcome(olderBatch?.outcomes[identity.profileID]),
            .superseded
        )
        XCTAssertEqual(
            outcome(newerBatch?.outcomes[identity.profileID]),
            .accepted
        )
        XCTAssertFalse(olderBatch?.isLatestBatch == true)
        XCTAssertTrue(newerBatch?.isLatestBatch == true)
        XCTAssertEqual(
            harness.committer.cachedUsage(
                for: identity.profileID
            )?.report?.usageSummary?.metrics.first?.value,
            2
        )
    }

    func testOlderTwoProfileBatchCannotReplaceNewerSlots()
        async throws
    {
        let first = makeIdentity()
        let second = makeIdentity()
        let context = makeContext(
            visible: [first.profileID, second.profileID]
        )
        // See testDifferentProfilesFetchConcurrently: this test's slot
        // invalidation/supersession assertions are independent of the
        // fan-out stagger policy.
        let harness = makeHarness(
            identities: [first, second],
            context: context,
            staggerPolicy: IndexedRefreshStaggerPolicy(step: 0)
        )
        let newerFirst = ManualGate<ProviderFetchResult>()
        let newerSecond = ManualGate<ProviderFetchResult>()
        let olderFetches = Locked<[UUID]>([])
        harness.ledger.registerInvocation(
            2,
            profileIDs: [first.profileID, second.profileID]
        )

        _ = await harness.engine.enqueue(
            [
                makeGatedJob(
                    identity: first,
                    gate: newerFirst
                ),
                makeGatedJob(
                    identity: second,
                    gate: newerSecond
                )
            ],
            trigger: .retry,
            presentationContext: context,
            inputGenerations: [
                first.profileID: 0,
                second.profileID: 0
            ],
            invocationOrder: 2
        )
        let newerFirstStarted = await waitForStarts(
            newerFirst,
            count: 1
        )
        let newerSecondStarted = await waitForStarts(
            newerSecond,
            count: 1
        )
        XCTAssertTrue(newerFirstStarted)
        XCTAssertTrue(newerSecondStarted)

        harness.ledger.registerInvocation(
            1,
            profileIDs: [first.profileID, second.profileID]
        )
        _ = await harness.engine.enqueue(
            [
                makeJob(
                    identity: first,
                    coreFetch: {
                        olderFetches.withValue {
                            $0.append(first.profileID)
                        }
                        return ProviderFetchResult(
                            report: try Self.makeReport(
                                providerID: .codex,
                                marker: 11
                            )
                        )
                    }
                ),
                makeJob(
                    identity: second,
                    coreFetch: {
                        olderFetches.withValue {
                            $0.append(second.profileID)
                        }
                        return ProviderFetchResult(
                            report: try Self.makeReport(
                                providerID: .codex,
                                marker: 12
                            )
                        )
                    }
                )
            ],
            trigger: .manual,
            presentationContext: context,
            inputGenerations: [
                first.profileID: 0,
                second.profileID: 0
            ],
            invocationOrder: 1
        )
        await assertEventually {
            harness.batches.snapshot.contains {
                $0.invocationOrder == 1
            }
        }
        XCTAssertTrue(olderFetches.snapshot().isEmpty)

        newerFirst.resolve(
            ProviderFetchResult(
                report: try makeReport(
                    providerID: .codex,
                    marker: 21
                )
            )
        )
        newerSecond.resolve(
            ProviderFetchResult(
                report: try makeReport(
                    providerID: .codex,
                    marker: 22
                )
            )
        )
        await assertEventually {
            harness.batches.snapshot.count == 2
        }

        let olderBatch = harness.batches.snapshot.first {
            $0.invocationOrder == 1
        }
        let newerBatch = harness.batches.snapshot.first {
            $0.invocationOrder == 2
        }
        XCTAssertEqual(
            outcome(olderBatch?.outcomes[first.profileID]),
            .superseded
        )
        XCTAssertEqual(
            outcome(olderBatch?.outcomes[second.profileID]),
            .superseded
        )
        XCTAssertEqual(
            outcome(newerBatch?.outcomes[first.profileID]),
            .accepted
        )
        XCTAssertEqual(
            outcome(newerBatch?.outcomes[second.profileID]),
            .accepted
        )
        XCTAssertEqual(harness.committer.durableCommits.count, 2)
    }

    func testEnqueueDuringSuspendedCommitPreservesFirstCommit()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let commitGate = ManualGate<Void>()
        harness.committer.commitGate = commitGate
        let secondGate = ManualGate<ProviderFetchResult>()

        _ = await enqueue(
            makeImmediateJob(
                identity: identity,
                result: ProviderFetchResult(
                    report: try makeReport(
                        providerID: .codex,
                        marker: 1
                    )
                )
            ),
            on: harness,
            context: context
        )
        let commitStarted = await waitForStarts(commitGate, count: 1)
        XCTAssertTrue(commitStarted)

        _ = await enqueue(
            makeGatedJob(identity: identity, gate: secondGate),
            on: harness,
            context: context
        )
        commitGate.resolve(())
        harness.committer.commitGate = nil
        let secondStarted = await waitForStarts(secondGate, count: 1)
        XCTAssertTrue(secondStarted)
        secondGate.resolve(
            ProviderFetchResult(
                report: try makeReport(
                    providerID: .codex,
                    marker: 2
                )
            )
        )
        await assertEventually {
            harness.batches.snapshot.count == 2
        }

        XCTAssertEqual(harness.committer.durableCommits.count, 2)
        XCTAssertEqual(harness.committer.acceptedPublications.count, 2)
        XCTAssertEqual(
            harness.committer.durableCommits[0]
                .1.currentUsage.report?.usageSummary?.metrics.first?.value,
            1
        )
        XCTAssertEqual(
            harness.committer.durableCommits[1]
                .1.currentUsage.report?.usageSummary?.metrics.first?.value,
            2
        )
    }

    func testFetchInvalidationCancelsAndSuppressesResult()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let gate = CancellationGate<ProviderFetchResult>()
        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: {
                    try await gate.wait()
                }
            ),
            on: harness,
            context: context
        )
        let fetchStarted = await waitForStarts(gate, count: 1)
        XCTAssertTrue(fetchStarted)

        let invalidatedGeneration = harness.ledger.invalidate(
            profileID: identity.profileID
        )
        await harness.engine.invalidate(
            profileID: identity.profileID,
            beforeInputGeneration: invalidatedGeneration
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(harness.committer.durableCommits.count, 0)
        XCTAssertEqual(harness.committer.acceptedPublications.count, 0)
        XCTAssertEqual(harness.committer.presentedPublications.count, 0)
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .superseded
        )
    }

    func testInvalidationBeforeEnqueuePreventsStaleFetchLaunch()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let fetchCalls = Locked(0)
        let minimumValidGeneration = harness.ledger.invalidate(
            profileID: identity.profileID
        )
        await harness.engine.invalidate(
            profileID: identity.profileID,
            beforeInputGeneration: minimumValidGeneration
        )

        _ = await harness.engine.enqueue(
            [
                makeJob(
                    identity: identity,
                    coreFetch: {
                        fetchCalls.withValue { $0 += 1 }
                        return ProviderFetchResult(
                            report: try Self.makeReport(
                                providerID: .codex,
                                marker: 1
                            )
                        )
                    }
                )
            ],
            trigger: .manual,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 1
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(fetchCalls.snapshot(), 0)
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .superseded
        )

        _ = await harness.engine.enqueue(
            [
                makeJob(
                    identity: identity,
                    coreFetch: {
                        fetchCalls.withValue { $0 += 1 }
                        return ProviderFetchResult(
                            report: try Self.makeReport(
                                providerID: .codex,
                                marker: 2
                            )
                        )
                    }
                )
            ],
            trigger: .retry,
            presentationContext: context,
            inputGenerations: [
                identity.profileID: minimumValidGeneration
            ],
            invocationOrder: 2
        )
        await assertEventually {
            harness.batches.snapshot.count == 2
        }

        XCTAssertEqual(fetchCalls.snapshot(), 1)
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot.first {
                    $0.invocationOrder == 2
                }?.outcomes[identity.profileID]
            ),
            .accepted
        )
    }

    func testStaleEnqueueBeforeActorInvalidationDoesNotLaunchFetch()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let fetchCalls = Locked(0)
        let minimumValidGeneration = harness.ledger.invalidate(
            profileID: identity.profileID
        )

        _ = await harness.engine.enqueue(
            [
                makeJob(
                    identity: identity,
                    coreFetch: {
                        fetchCalls.withValue { $0 += 1 }
                        return ProviderFetchResult(
                            report: try Self.makeReport(
                                providerID: .codex,
                                marker: 1
                            )
                        )
                    }
                )
            ],
            trigger: .manual,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 1
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(fetchCalls.snapshot(), 0)
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .superseded
        )

        await harness.engine.invalidate(
            profileID: identity.profileID,
            beforeInputGeneration: minimumValidGeneration
        )
        _ = await harness.engine.enqueue(
            [
                makeJob(
                    identity: identity,
                    coreFetch: {
                        fetchCalls.withValue { $0 += 1 }
                        return ProviderFetchResult(
                            report: try Self.makeReport(
                                providerID: .codex,
                                marker: 2
                            )
                        )
                    }
                )
            ],
            trigger: .retry,
            presentationContext: context,
            inputGenerations: [
                identity.profileID: minimumValidGeneration
            ],
            invocationOrder: 2
        )
        await assertEventually {
            harness.batches.snapshot.count == 2
        }

        XCTAssertEqual(fetchCalls.snapshot(), 1)
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot.first {
                    $0.invocationOrder == 2
                }?.outcomes[identity.profileID]
            ),
            .accepted
        )
    }

    func testDelayedInvalidationPreservesNewGenerationRequest()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let gate = ManualGate<ProviderFetchResult>()
        let generation = harness.ledger.invalidate(
            profileID: identity.profileID
        )
        _ = await harness.engine.enqueue(
            [makeGatedJob(identity: identity, gate: gate)],
            trigger: .manual,
            presentationContext: context,
            inputGenerations: [
                identity.profileID: generation
            ],
            invocationOrder: 1
        )
        let started = await waitForStarts(gate, count: 1)
        XCTAssertTrue(started)

        await harness.engine.invalidate(
            profileID: identity.profileID,
            beforeInputGeneration: generation
        )
        gate.resolve(
            ProviderFetchResult(
                report: try makeReport(providerID: .codex)
            )
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(harness.committer.durableCommits.count, 1)
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .accepted
        )
    }

    func testDelayedInvalidationPreservesNewPendingGeneration()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let oldGate = CancellationGate<ProviderFetchResult>()
        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: { try await oldGate.wait() }
            ),
            on: harness,
            context: context
        )
        let oldStarted = await waitForStarts(oldGate, count: 1)
        XCTAssertTrue(oldStarted)

        let generation = harness.ledger.invalidate(
            profileID: identity.profileID
        )
        let replacementGate = ManualGate<ProviderFetchResult>()
        _ = await harness.engine.enqueue(
            [
                makeGatedJob(
                    identity: identity,
                    gate: replacementGate
                )
            ],
            trigger: .retry,
            presentationContext: context,
            inputGenerations: [
                identity.profileID: generation
            ],
            invocationOrder: 2
        )
        await harness.engine.invalidate(
            profileID: identity.profileID,
            beforeInputGeneration: generation
        )

        let replacementStarted = await waitForStarts(
            replacementGate,
            count: 1
        )
        XCTAssertTrue(replacementStarted)
        replacementGate.resolve(
            ProviderFetchResult(
                report: try makeReport(
                    providerID: .codex,
                    marker: 2
                )
            )
        )
        await assertEventually {
            harness.batches.snapshot.count == 2
        }

        XCTAssertEqual(
            outcome(
                harness.batches.snapshot.first {
                    $0.invocationOrder == 1
                }?.outcomes[identity.profileID]
            ),
            .superseded
        )
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot.first {
                    $0.invocationOrder == 2
                }?.outcomes[identity.profileID]
            ),
            .accepted
        )
    }

    func testPendingRequestRevalidatesInputsBeforeFetchLaunch()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let oldGate = ManualGate<ProviderFetchResult>()
        _ = await enqueue(
            makeGatedJob(identity: identity, gate: oldGate),
            on: harness,
            context: context
        )
        let oldStarted = await waitForStarts(oldGate, count: 1)
        XCTAssertTrue(oldStarted)
        let replacementFetches = Locked(0)
        _ = await harness.engine.enqueue(
            [
                makeJob(
                    identity: identity,
                    coreFetch: {
                        replacementFetches.withValue { $0 += 1 }
                        return ProviderFetchResult(
                            report: try Self.makeReport(
                                providerID: .codex,
                                marker: 2
                            )
                        )
                    }
                )
            ],
            trigger: .retry,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 2
        )

        _ = harness.ledger.invalidate(
            profileID: identity.profileID
        )
        oldGate.resolve(
            ProviderFetchResult(
                report: try makeReport(
                    providerID: .codex,
                    marker: 1
                )
            )
        )
        await assertEventually {
            harness.batches.snapshot.count == 2
        }

        XCTAssertEqual(replacementFetches.snapshot(), 0)
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot.first {
                    $0.invocationOrder == 2
                }?.outcomes[identity.profileID]
            ),
            .superseded
        )
    }

    func testNewerRegistrationAfterDurableCommitSupersedesOldBatch()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let postCommitGate = ManualGate<Void>()
        harness.committer.postCommitGate = postCommitGate
        _ = await harness.engine.enqueue(
            [
                makeImmediateJob(
                    identity: identity,
                    result: ProviderFetchResult(
                        report: try makeReport(
                            providerID: .codex,
                            marker: 1
                        )
                    )
                )
            ],
            trigger: .manual,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 1
        )
        let commitReturnedToEngine = await waitForStarts(
            postCommitGate,
            count: 1
        )
        XCTAssertTrue(commitReturnedToEngine)
        XCTAssertEqual(harness.committer.durableCommits.count, 1)

        _ = await harness.engine.enqueue(
            [
                makeImmediateJob(
                    identity: identity,
                    result: ProviderFetchResult(
                        report: try makeReport(
                            providerID: .codex,
                            marker: 2
                        )
                    )
                )
            ],
            trigger: .retry,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 2
        )
        postCommitGate.resolve(())
        await assertEventually {
            harness.batches.snapshot.count == 2
        }

        XCTAssertEqual(
            outcome(
                harness.batches.snapshot.first {
                    $0.invocationOrder == 1
                }?.outcomes[identity.profileID]
            ),
            .superseded
        )
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot.first {
                    $0.invocationOrder == 2
                }?.outcomes[identity.profileID]
            ),
            .accepted
        )
        XCTAssertEqual(
            harness.store.snapshot(
                for: identity.profileID
            )?.report?.usageSummary?.metrics.first?.value,
            2
        )
    }

    func testCommitInvalidationBeforeActorInvalidationSuppressesAcceptance()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let commitGate = ManualGate<Void>()
        harness.committer.commitGate = commitGate
        _ = await enqueue(
            makeImmediateJob(
                identity: identity,
                result: ProviderFetchResult(
                    report: try makeReport(providerID: .codex)
                )
            ),
            on: harness,
            context: context
        )
        let commitStarted = await waitForStarts(commitGate, count: 1)
        XCTAssertTrue(commitStarted)
        let refreshingSnapshot = harness.store.snapshot(
            for: identity.profileID
        )
        let invalidatedGeneration = harness.ledger.invalidate(
            profileID: identity.profileID
        )
        commitGate.resolve(())
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(harness.committer.durableCommits.count, 0)
        XCTAssertEqual(harness.committer.acceptedPublications.count, 0)
        XCTAssertEqual(
            harness.store.snapshot(
                for: identity.profileID
            )?.activity,
            .idle
        )
        XCTAssertEqual(
            harness.store.snapshot(
                for: identity.profileID
            )?.report,
            refreshingSnapshot?.report
        )
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .superseded
        )
        await harness.engine.invalidate(
            profileID: identity.profileID,
            beforeInputGeneration: invalidatedGeneration
        )
    }

    func testCommitAndAcceptedPublicationRemainAtomic()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let commitGate = ManualGate<Void>()
        harness.committer.commitGate = commitGate
        _ = await enqueue(
            makeImmediateJob(
                identity: identity,
                result: ProviderFetchResult(
                    report: try makeReport(providerID: .codex)
                )
            ),
            on: harness,
            context: context
        )
        let commitStarted = await waitForStarts(commitGate, count: 1)
        XCTAssertTrue(commitStarted)
        XCTAssertEqual(harness.committer.durableCommits.count, 0)
        XCTAssertEqual(harness.committer.acceptedPublications.count, 0)

        commitGate.resolve(())
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(harness.committer.durableCommits.count, 1)
        XCTAssertEqual(harness.committer.acceptedPublications.count, 1)
        XCTAssertEqual(harness.committer.presentedPublications.count, 1)
        XCTAssertNotNil(harness.store.snapshot(for: identity.profileID))
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .accepted
        )
    }

    func testLedgerInvalidationBeforeSuccessPresentationSuppressesSnapshot()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let presentationGate = ManualGate<Void>()
        harness.committer.presentationGate = presentationGate

        _ = await enqueue(
            makeImmediateJob(
                identity: identity,
                result: ProviderFetchResult(
                    report: try makeReport(providerID: .codex)
                )
            ),
            on: harness,
            context: context
        )
        let presentationStarted = await waitForStarts(
            presentationGate,
            count: 1
        )
        XCTAssertTrue(presentationStarted)
        XCTAssertEqual(harness.committer.durableCommits.count, 1)
        XCTAssertEqual(
            harness.committer.acceptedPublications.count,
            1
        )
        XCTAssertEqual(harness.batches.snapshot.count, 0)
        let refreshingSnapshot = harness.store.snapshot(
            for: identity.profileID
        )

        let invalidatedGeneration = harness.ledger.invalidate(
            profileID: identity.profileID
        )
        presentationGate.resolve(())
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(
            harness.store.snapshot(
                for: identity.profileID
            )?.activity,
            .idle
        )
        XCTAssertEqual(
            harness.store.snapshot(
                for: identity.profileID
            )?.report,
            refreshingSnapshot?.report
        )
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .superseded
        )
        await harness.engine.invalidate(
            profileID: identity.profileID,
            beforeInputGeneration: invalidatedGeneration
        )
    }

    func testProviderRevisionMismatchSuppressesCommit() async throws {
        let oldIdentity = makeIdentity(revision: 1)
        let currentIdentity = ProviderRefreshIdentity(
            profileID: oldIdentity.profileID,
            providerID: .codex,
            providerRevision: 2
        )
        let context = makeContext(visible: [oldIdentity.profileID])
        let harness = makeHarness(
            identities: [currentIdentity],
            context: context
        )

        _ = await enqueue(
            makeImmediateJob(
                identity: oldIdentity,
                result: ProviderFetchResult(
                    report: try makeReport(providerID: .codex)
                )
            ),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(harness.committer.durableCommits.count, 0)
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[oldIdentity.profileID]
            ),
            .superseded
        )
    }

    func testDeletionDuringRunningAndPendingCompletesBothBatches()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let running = ManualGate<ProviderFetchResult>()
        let pending = ManualGate<ProviderFetchResult>()

        _ = await enqueue(
            makeGatedJob(identity: identity, gate: running),
            on: harness,
            context: context
        )
        let runningStarted = await waitForStarts(running, count: 1)
        XCTAssertTrue(runningStarted)
        _ = await enqueue(
            makeGatedJob(identity: identity, gate: pending),
            on: harness,
            context: context
        )

        harness.ledger.beginDeletion(profileID: identity.profileID)
        await harness.engine.remove(profileID: identity.profileID)
        await assertEventually {
            harness.batches.snapshot.count == 2
        }

        XCTAssertTrue(
            harness.batches.snapshot.allSatisfy {
                outcome($0.outcomes[identity.profileID])
                    == .superseded
            }
        )
        XCTAssertNil(harness.store.snapshot(for: identity.profileID))
        XCTAssertEqual(harness.committer.durableCommits.count, 0)
        running.resolve(
            ProviderFetchResult(
                report: try makeReport(providerID: .codex)
            )
        )
        pending.resolve(
            ProviderFetchResult(
                report: try makeReport(providerID: .codex)
            )
        )
    }

    func testDeletionStartRetainsCachedSnapshotAsDeleting()
        throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let report = try makeReport(
            providerID: .codex,
            marker: 41
        )
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        harness.store.activate(
            context,
            hydrated: [
                identity.profileID: makeSnapshot(
                    identity: identity,
                    epoch: context.epoch,
                    report: report
                )
            ]
        )

        harness.ledger.beginDeletion(profileID: identity.profileID)
        harness.store.markDeleting(profileID: identity.profileID)

        let retained = harness.store.snapshot(
            for: identity.profileID
        )
        XCTAssertEqual(retained?.configurationState, .deleting)
        XCTAssertEqual(retained?.report, report)
        XCTAssertTrue(harness.ledger.isDeleting(identity.profileID))
    }

    func testVerifiedDeletionCompletionPurgesBeforeDelayedResult()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let report = try makeReport(
            providerID: .codex,
            marker: 42
        )
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        harness.store.activate(
            context,
            hydrated: [
                identity.profileID: makeSnapshot(
                    identity: identity,
                    epoch: context.epoch,
                    report: report
                )
            ]
        )
        let gate = ManualGate<ProviderFetchResult>()
        _ = await enqueue(
            makeGatedJob(identity: identity, gate: gate),
            on: harness,
            context: context
        )
        let fetchStarted = await waitForStarts(gate, count: 1)
        XCTAssertTrue(fetchStarted)

        harness.ledger.beginDeletion(profileID: identity.profileID)
        harness.store.markDeleting(profileID: identity.profileID)
        await harness.engine.invalidate(
            profileID: identity.profileID,
            beforeInputGeneration: harness.ledger.generation(
                for: identity.profileID
            )
        )
        XCTAssertEqual(
            harness.store.snapshot(
                for: identity.profileID
            )?.configurationState,
            .deleting
        )

        await harness.engine.remove(profileID: identity.profileID)
        harness.ledger.completeDeletion(profileID: identity.profileID)
        XCTAssertNil(harness.store.snapshot(for: identity.profileID))
        XCTAssertTrue(harness.ledger.isDeleting(identity.profileID))
        XCTAssertEqual(harness.ledger.generation(for: identity.profileID), 2)
        await assertEventually {
            harness.batches.snapshot.count == 1
        }
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .superseded
        )

        gate.resolve(
            ProviderFetchResult(
                report: try makeReport(
                    providerID: .codex,
                    marker: 99
                )
            )
        )
        await Task.yield()
        XCTAssertEqual(harness.committer.durableCommits.count, 0)
        XCTAssertEqual(
            harness.committer.acceptedPublications.count,
            0
        )
        XCTAssertNil(harness.store.snapshot(for: identity.profileID))
    }

    func testDeletionTombstoneRejectsDelayedCommittedPresentation()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let presentationGate = ManualGate<Void>()
        harness.committer.presentationGate = presentationGate
        _ = await enqueue(
            makeImmediateJob(
                identity: identity,
                result: ProviderFetchResult(
                    report: try makeReport(providerID: .codex)
                )
            ),
            on: harness,
            context: context
        )
        let presentationStarted = await waitForStarts(
            presentationGate,
            count: 1
        )
        XCTAssertTrue(presentationStarted)
        XCTAssertEqual(harness.committer.durableCommits.count, 1)
        XCTAssertEqual(
            harness.committer.acceptedPublications.count,
            1
        )

        harness.ledger.beginDeletion(profileID: identity.profileID)
        harness.store.markDeleting(profileID: identity.profileID)
        await harness.engine.invalidate(
            profileID: identity.profileID,
            beforeInputGeneration: harness.ledger.generation(
                for: identity.profileID
            )
        )
        await harness.engine.remove(profileID: identity.profileID)
        harness.ledger.completeDeletion(profileID: identity.profileID)
        XCTAssertNil(harness.store.snapshot(for: identity.profileID))
        XCTAssertEqual(harness.ledger.generation(for: identity.profileID), 2)
        XCTAssertTrue(harness.ledger.isDeleting(identity.profileID))
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        presentationGate.resolve(())
        await Task.yield()
        XCTAssertNil(harness.store.snapshot(for: identity.profileID))
        XCTAssertTrue(
            harness.committer.failurePublications.isEmpty
        )
        XCTAssertEqual(
            harness.committer.acceptedPublications.count,
            1
        )
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .superseded
        )
    }

    func testMarkDeletingRejectsSuspendedActivityCompletion()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let retainedReport = try makeReport(
            providerID: .codex,
            marker: 43
        )
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        harness.store.activate(
            context,
            hydrated: [
                identity.profileID: makeSnapshot(
                    identity: identity,
                    epoch: context.epoch,
                    report: retainedReport
                )
            ]
        )
        let presentationGate = ManualGate<Void>()
        harness.committer.presentationGate = presentationGate

        _ = await enqueue(
            makeImmediateJob(
                identity: identity,
                result: ProviderFetchResult(
                    report: try makeReport(
                        providerID: .codex,
                        marker: 44
                    )
                )
            ),
            on: harness,
            context: context
        )
        let presentationStarted = await waitForStarts(
            presentationGate,
            count: 1
        )
        XCTAssertTrue(presentationStarted)

        harness.ledger.beginDeletion(profileID: identity.profileID)
        harness.store.markDeleting(profileID: identity.profileID)
        XCTAssertEqual(
            harness.store.snapshot(
                for: identity.profileID
            )?.configurationState,
            .deleting
        )
        XCTAssertEqual(
            harness.store.snapshot(
                for: identity.profileID
            )?.activity,
            .idle
        )

        presentationGate.resolve(())
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        let terminal = harness.store.snapshot(
            for: identity.profileID
        )
        XCTAssertEqual(terminal?.configurationState, .deleting)
        XCTAssertEqual(terminal?.activity, .idle)
        XCTAssertEqual(terminal?.report, retainedReport)
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .superseded
        )
    }

    func testShutdownSuppressesLateFetchPublication() async throws {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let exited = Locked(false)
        let gate = CancellationGate<ProviderFetchResult> {
            exited.withValue { $0 = true }
        }
        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: {
                    try await gate.wait()
                }
            ),
            on: harness,
            context: context
        )
        let fetchStarted = await waitForStarts(gate, count: 1)
        XCTAssertTrue(fetchStarted)

        await harness.engine.shutdown()

        XCTAssertTrue(exited.snapshot())
        XCTAssertEqual(harness.committer.commitAttempts.count, 0)
        XCTAssertEqual(harness.committer.acceptedPublications.count, 0)
        XCTAssertTrue(harness.store.snapshots.isEmpty)
    }

    func testShutdownPreventsLaterBatchMembersAndStatusFromStarting()
        async throws
    {
        let claude = makeIdentity(providerID: .claude)
        let codex = makeIdentity(providerID: .codex)
        let context = makeContext(
            visible: [claude.profileID, codex.profileID]
        )
        let secondMemberGate = ManualGate<Void>()
        let statusFetches = Locked(0)
        let harness = makeHarness(
            identities: [claude, codex],
            context: context,
            statusFetch: {
                statusFetches.withValue { $0 += 1 }
                return .operational
            },
            memberEnqueueObserver: { _, index in
                if index == 1 {
                    await secondMemberGate.wait()
                }
            }
        )
        let firstExited = Locked(false)
        let firstFetch = CancellationGate<ProviderFetchResult> {
            firstExited.withValue { $0 = true }
        }
        let secondFetches = Locked(0)

        let enqueueTask = Task {
            await harness.engine.enqueue(
                [
                    makeJob(
                        identity: claude,
                        coreFetch: {
                            try await firstFetch.wait()
                        }
                    ),
                    makeJob(
                        identity: codex,
                        coreFetch: {
                            secondFetches.withValue { $0 += 1 }
                            return ProviderFetchResult(
                                report: try Self.makeReport(
                                    providerID: .codex
                                )
                            )
                        }
                    )
                ],
                trigger: .manual,
                presentationContext: context,
                inputGenerations: [
                    claude.profileID: 0,
                    codex.profileID: 0
                ],
                invocationOrder: 1,
                requestsClaudeStatus: true
            )
        }
        let firstStarted = await waitForStarts(
            firstFetch,
            count: 1
        )
        XCTAssertTrue(firstStarted)
        let secondMemberReached = await waitForStarts(
            secondMemberGate,
            count: 1
        )
        XCTAssertTrue(secondMemberReached)

        await harness.engine.shutdown()
        secondMemberGate.resolve(())
        _ = await enqueueTask.value

        XCTAssertTrue(firstExited.snapshot())
        XCTAssertEqual(secondFetches.snapshot(), 0)
        XCTAssertEqual(statusFetches.snapshot(), 0)
        XCTAssertTrue(harness.store.snapshots.isEmpty)
    }

    func testEnqueueAfterEngineShutdownIsTerminallySuperseded()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let fetches = Locked(0)
        await harness.engine.shutdown()

        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: {
                    fetches.withValue { $0 += 1 }
                    return ProviderFetchResult(
                        report: try Self.makeReport(
                            providerID: .codex
                        )
                    )
                }
            ),
            on: harness,
            context: context
        )

        XCTAssertEqual(fetches.snapshot(), 0)
        XCTAssertEqual(harness.committer.commitAttempts.count, 0)
        XCTAssertEqual(harness.batches.snapshot.count, 1)
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .superseded
        )
        XCTAssertTrue(harness.store.snapshots.isEmpty)
    }

    func testAPIOnlyClaudeSuccessCommitsAndReportsCoreFailure()
        async throws
    {
        let identity = makeIdentity(providerID: .claude)
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let api = makeAPIUsage(spend: 42)
        let job = makeJob(
            identity: identity,
            coreFetch: { throw TestFailure.core },
            apiFetch: { api }
        )

        _ = await enqueue(job, on: harness, context: context)
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(harness.committer.durableCommits.count, 1)
        XCTAssertEqual(
            harness.committer.cachedUsage(
                for: identity.profileID
            )?.apiUsage,
            api
        )
        XCTAssertEqual(
            harness.committer.acceptedPublications[0]
                .0.acceptedComponents,
            [.claudeAPI]
        )
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .failed
        )
    }

    func testCoreFailurePublishesBeforeDelayedAPISuccessAndRemainsTerminal()
        async
    {
        let identity = makeIdentity(providerID: .claude)
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let apiGate = ManualGate<APIUsage>()
        let apiUsage = makeAPIUsage(spend: 43)

        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: { throw TestFailure.core },
                apiFetch: { await apiGate.wait() }
            ),
            on: harness,
            context: context
        )
        let apiStarted = await waitForStarts(apiGate, count: 1)
        XCTAssertTrue(apiStarted)
        await assertEventually {
            harness.committer.failurePublications.count == 1
                && harness.store.snapshot(
                    for: identity.profileID
                )?.currentFailure != nil
        }

        let inFlightSnapshot = harness.store.snapshot(
            for: identity.profileID
        )
        XCTAssertEqual(
            harness.committer.failurePublications[0].component,
            .providerUsage
        )
        XCTAssertTrue(inFlightSnapshot?.activity.isInFlight == true)
        XCTAssertNotNil(inFlightSnapshot?.currentFailure)
        XCTAssertEqual(harness.committer.durableCommits.count, 0)
        XCTAssertEqual(harness.batches.snapshot.count, 0)

        apiGate.resolve(apiUsage)
        await assertEventually {
            harness.batches.snapshot.count == 1
                && harness.committer.durableCommits.count == 1
                && harness.store.snapshot(
                    for: identity.profileID
                )?.activity == .idle
        }

        let terminalSnapshot = harness.store.snapshot(
            for: identity.profileID
        )
        XCTAssertEqual(
            harness.committer.durableCommits[0]
                .0.acceptedComponents,
            [.claudeAPI]
        )
        XCTAssertEqual(terminalSnapshot?.claudeAPIUsage, apiUsage)
        XCTAssertEqual(
            terminalSnapshot?.currentFailure?.kind,
            inFlightSnapshot?.currentFailure?.kind
        )
        XCTAssertEqual(
            terminalSnapshot?.currentFailure?.consecutiveCount,
            inFlightSnapshot?.currentFailure?.consecutiveCount
        )
        XCTAssertFalse(terminalSnapshot?.activity.isInFlight == true)
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .failed
        )
    }

    func testCoreCommitsBeforeDelayedAPIAndBatchWaitsForBoth()
        async throws
    {
        let identity = makeIdentity(providerID: .claude)
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let apiGate = ManualGate<APIUsage>()
        let coreResult = ProviderFetchResult(
            report: try makeReport(
                providerID: .claude,
                marker: 11
            ),
            claudeUsage: makeClaudeUsage(marker: 11)
        )
        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: { coreResult },
                apiFetch: { await apiGate.wait() }
            ),
            on: harness,
            context: context
        )
        let apiStarted = await waitForStarts(apiGate, count: 1)
        XCTAssertTrue(apiStarted)
        await assertEventually {
            harness.committer.durableCommits.count == 1
                && harness.store.snapshot(
                    for: identity.profileID
                )?.report?.usageSummary?.metrics.first?.value
                    == 11
        }

        XCTAssertEqual(
            harness.committer.durableCommits.first?
                .0.acceptedComponents,
            [.providerUsage]
        )
        XCTAssertEqual(
            harness.committer.acceptedPublications.count,
            1
        )
        XCTAssertEqual(harness.batches.snapshot.count, 0)
        XCTAssertEqual(
            harness.store.snapshot(
                for: identity.profileID
            )?.report?.usageSummary?.metrics.first?.value,
            11
        )

        apiGate.resolve(makeAPIUsage(spend: 12))
        await assertEventually {
            harness.batches.snapshot.count == 1
                && harness.committer.durableCommits.count == 2
        }

        XCTAssertEqual(
            harness.committer.durableCommits.last?
                .0.acceptedComponents,
            [.claudeAPI]
        )
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .accepted
        )
    }

    func testAPICommitsBeforeDelayedCoreAndBatchWaitsForBoth()
        async throws
    {
        let identity = makeIdentity(providerID: .claude)
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let coreGate = ManualGate<ProviderFetchResult>()
        let apiUsage = makeAPIUsage(spend: 13)
        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: { await coreGate.wait() },
                apiFetch: { apiUsage }
            ),
            on: harness,
            context: context
        )
        let coreStarted = await waitForStarts(coreGate, count: 1)
        XCTAssertTrue(coreStarted)
        await assertEventually {
            harness.committer.durableCommits.count == 1
                && harness.store.snapshot(
                    for: identity.profileID
                )?.claudeAPIUsage == apiUsage
        }

        XCTAssertEqual(
            harness.committer.durableCommits.first?
                .0.acceptedComponents,
            [.claudeAPI]
        )
        XCTAssertEqual(harness.batches.snapshot.count, 0)
        XCTAssertEqual(
            harness.committer.cachedUsage(
                for: identity.profileID
            )?.apiUsage,
            apiUsage
        )
        XCTAssertEqual(
            harness.store.snapshot(
                for: identity.profileID
            )?.claudeAPIUsage,
            apiUsage
        )

        coreGate.resolve(
            ProviderFetchResult(
                report: try makeReport(
                    providerID: .claude,
                    marker: 14
                ),
                claudeUsage: makeClaudeUsage(marker: 14)
            )
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
                && harness.committer.durableCommits.count == 2
        }

        XCTAssertEqual(
            harness.committer.durableCommits.last?
                .0.acceptedComponents,
            [.providerUsage]
        )
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .accepted
        )
    }

    func testSplitProviderAndAPICommitsPreserveBothInEitherOrder()
        async throws
    {
        for apiCommitsFirst in [true, false] {
            let identity = makeIdentity(providerID: .claude)
            let context = makeContext(visible: [identity.profileID])
            let harness = makeHarness(
                identities: [identity],
                context: context
            )
            let providerCommitGate = ManualGate<Void>()
            let apiCommitGate = ManualGate<Void>()
            let providerFetchGate =
                ManualGate<ProviderFetchResult>()
            let apiFetchGate = ManualGate<APIUsage>()
            harness.committer.providerCommitGate =
                providerCommitGate
            harness.committer.apiCommitGate = apiCommitGate
            let providerResult = ProviderFetchResult(
                report: try makeReport(
                    providerID: .claude,
                    marker: apiCommitsFirst ? 61 : 62
                ),
                claudeUsage: makeClaudeUsage(
                    marker: apiCommitsFirst ? 61 : 62
                )
            )
            let apiUsage = makeAPIUsage(
                spend: apiCommitsFirst ? 63 : 64
            )

            _ = await enqueue(
                makeJob(
                    identity: identity,
                    coreFetch: {
                        await providerFetchGate.wait()
                    },
                    apiFetch: {
                        await apiFetchGate.wait()
                    }
                ),
                on: harness,
                context: context
            )
            let providerFetchStarted = await waitForStarts(
                providerFetchGate,
                count: 1
            )
            let apiFetchStarted = await waitForStarts(
                apiFetchGate,
                count: 1
            )
            XCTAssertTrue(providerFetchStarted)
            XCTAssertTrue(apiFetchStarted)

            if apiCommitsFirst {
                apiFetchGate.resolve(apiUsage)
            } else {
                providerFetchGate.resolve(providerResult)
            }
            let firstCommitStarted = await waitForStarts(
                apiCommitsFirst
                    ? apiCommitGate
                    : providerCommitGate,
                count: 1
            )
            XCTAssertTrue(firstCommitStarted)
            XCTAssertEqual(
                apiCommitsFirst
                    ? providerCommitGate.startCount
                    : apiCommitGate.startCount,
                0
            )
            if apiCommitsFirst {
                apiCommitGate.resolve(())
            } else {
                providerCommitGate.resolve(())
            }
            await assertEventually {
                harness.committer.durableCommits.count == 1
            }
            XCTAssertEqual(
                harness.committer.durableCommits[0]
                    .0.acceptedComponents,
                apiCommitsFirst
                    ? [.claudeAPI]
                    : [.providerUsage]
            )
            XCTAssertEqual(harness.batches.snapshot.count, 0)

            if apiCommitsFirst {
                providerFetchGate.resolve(providerResult)
                let providerCommitStarted = await waitForStarts(
                    providerCommitGate,
                    count: 1
                )
                XCTAssertTrue(providerCommitStarted)
                providerCommitGate.resolve(())
            } else {
                apiFetchGate.resolve(apiUsage)
                let apiCommitStarted = await waitForStarts(
                    apiCommitGate,
                    count: 1
                )
                XCTAssertTrue(apiCommitStarted)
                apiCommitGate.resolve(())
            }
            await assertEventually {
                harness.committer.durableCommits.count == 2
                    && harness.batches.snapshot.count == 1
            }

            let terminalSnapshot = harness.store.snapshot(
                for: identity.profileID
            )
            XCTAssertEqual(
                terminalSnapshot?.report?.usageSummary?
                    .metrics.first?.value,
                apiCommitsFirst ? 61 : 62
            )
            XCTAssertEqual(
                terminalSnapshot?.claudeAPIUsage,
                apiUsage
            )
            XCTAssertEqual(terminalSnapshot?.activity, .idle)
            XCTAssertEqual(
                outcome(
                    harness.batches.snapshot[0]
                        .outcomes[identity.profileID]
                ),
                .accepted
            )
        }
    }

    func testLatestRequestCancelsUnresolvedAPIWithoutUndoingAcceptedCore()
        async throws
    {
        let identity = makeIdentity(providerID: .claude)
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let firstAPI = CancellationGate<APIUsage>()
        let firstCore = ProviderFetchResult(
            report: try makeReport(
                providerID: .claude,
                marker: 21
            ),
            claudeUsage: makeClaudeUsage(marker: 21)
        )
        _ = await enqueue(
            makeJob(
                identity: identity,
                trigger: .manual,
                coreFetch: { firstCore },
                apiFetch: { try await firstAPI.wait() }
            ),
            on: harness,
            context: context
        )
        let apiStarted = await waitForStarts(firstAPI, count: 1)
        XCTAssertTrue(apiStarted)
        await assertEventually {
            harness.committer.durableCommits.count == 1
                && harness.store.snapshot(
                    for: identity.profileID
                )?.report?.usageSummary?.metrics.first?.value
                    == 21
        }
        XCTAssertEqual(
            harness.committer.cachedUsage(
                for: identity.profileID
            )?.report?.usageSummary?.metrics.first?.value,
            21
        )

        let latestCore = ProviderFetchResult(
            report: try makeReport(
                providerID: .claude,
                marker: 22
            ),
            claudeUsage: makeClaudeUsage(marker: 22)
        )
        _ = await enqueue(
            makeJob(
                identity: identity,
                trigger: .retry,
                coreFetch: { latestCore }
            ),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 2
                && harness.committer.durableCommits.count == 2
        }

        XCTAssertEqual(
            harness.committer.cachedUsage(
                for: identity.profileID
            )?.report?.usageSummary?.metrics.first?.value,
            22
        )
        XCTAssertTrue(
            harness.committer.failurePublications.isEmpty
        )
        let manualBatch = harness.batches.snapshot.first {
            $0.trigger == .manual
        }
        let retryBatch = harness.batches.snapshot.first {
            $0.trigger == .retry
        }
        XCTAssertEqual(
            outcome(manualBatch?.outcomes[identity.profileID]),
            .accepted
        )
        XCTAssertEqual(
            outcome(retryBatch?.outcomes[identity.profileID]),
            .accepted
        )
    }

    func testLatestDuringCoreCommitWaitsForCancelledAPIToExit()
        async throws
    {
        let identity = makeIdentity(providerID: .claude)
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let lifecycle = Locked<[String]>([])
        let firstCoreCommit = ManualGate<Void>()
        harness.committer.providerCommitGate = firstCoreCommit
        let firstAPI = CancellationGate<APIUsage>(
            onExit: {
                lifecycle.withValue { $0.append("api-exited") }
            }
        )
        let firstCore = ProviderFetchResult(
            report: try makeReport(
                providerID: .claude,
                marker: 71
            ),
            claudeUsage: makeClaudeUsage(marker: 71)
        )
        let latestCore = ProviderFetchResult(
            report: try makeReport(
                providerID: .claude,
                marker: 72
            ),
            claudeUsage: makeClaudeUsage(marker: 72)
        )

        _ = await enqueue(
            makeJob(
                identity: identity,
                trigger: .manual,
                coreFetch: { firstCore },
                apiFetch: { try await firstAPI.wait() }
            ),
            on: harness,
            context: context
        )
        let apiStarted = await waitForStarts(firstAPI, count: 1)
        let commitStarted = await waitForStarts(
            firstCoreCommit,
            count: 1
        )
        XCTAssertTrue(apiStarted)
        XCTAssertTrue(commitStarted)

        _ = await enqueue(
            makeJob(
                identity: identity,
                trigger: .retry,
                coreFetch: {
                    lifecycle.withValue {
                        $0.append("latest-started")
                    }
                    return latestCore
                }
            ),
            on: harness,
            context: context
        )
        XCTAssertTrue(lifecycle.snapshot().isEmpty)

        firstCoreCommit.resolve(())
        harness.committer.providerCommitGate = nil
        await assertEventually {
            harness.batches.snapshot.count == 2
                && lifecycle.snapshot().count == 2
        }

        XCTAssertEqual(
            lifecycle.snapshot(),
            ["api-exited", "latest-started"]
        )
        XCTAssertEqual(
            harness.committer.cachedUsage(
                for: identity.profileID
            )?.report?.usageSummary?.metrics.first?.value,
            72
        )
        XCTAssertTrue(
            harness.committer.failurePublications.isEmpty
        )
    }

    func testCoreAndAPIFailureDoNotCommit() async {
        let identity = makeIdentity(providerID: .claude)
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let job = makeJob(
            identity: identity,
            coreFetch: { throw TestFailure.core },
            apiFetch: { throw TestFailure.api }
        )

        _ = await enqueue(job, on: harness, context: context)
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(harness.committer.durableCommits.count, 0)
        XCTAssertEqual(harness.committer.acceptedPublications.count, 0)
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .failed
        )
    }

    func testCoreSuccessAndAPIFailureAcceptsProviderUsage()
        async throws
    {
        let identity = makeIdentity(providerID: .claude)
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let coreResult = ProviderFetchResult(
            report: try makeReport(providerID: .claude),
            claudeUsage: makeClaudeUsage(marker: 5)
        )
        let job = makeJob(
            identity: identity,
            coreFetch: { coreResult },
            apiFetch: { throw TestFailure.api }
        )

        _ = await enqueue(job, on: harness, context: context)
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(
            harness.committer.acceptedPublications[0]
                .0.acceptedComponents,
            [.providerUsage]
        )
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .accepted
        )
    }

    func testAPICommitFailurePublishesTypedPersistenceFailure()
        async throws
    {
        let identity = makeIdentity(providerID: .claude)
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let apiGate = ManualGate<APIUsage>()
        let coreResult = ProviderFetchResult(
            report: try makeReport(providerID: .claude),
            claudeUsage: makeClaudeUsage(marker: 5)
        )
        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: { coreResult },
                apiFetch: {
                    await apiGate.wait()
                }
            ),
            on: harness,
            context: context
        )
        let apiStarted = await waitForStarts(apiGate, count: 1)
        XCTAssertTrue(apiStarted)
        await assertEventually {
            harness.committer.durableCommits.count == 1
        }
        harness.committer.forcedCommitError =
            .persistenceRejected
        apiGate.resolve(makeAPIUsage(spend: 6))
        await assertEventually {
            harness.batches.snapshot.count == 1
                && harness.committer.failurePublications.count == 1
        }

        XCTAssertEqual(
            harness.committer.failurePublications[0].component,
            .persistence
        )
        XCTAssertEqual(
            harness.committer.failurePublications[0].failure.kind,
            .persistence
        )
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .accepted
        )
    }

    func testProviderIdentityMismatchPublishesProtocolFailure()
        async
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: {
                    throw UsageProviderFetchError
                        .providerIdentityMismatch(
                            expected: .codex,
                            received: .claude
                        )
                }
            ),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(
            harness.committer.failurePublications.first?
                .failure.kind,
            .protocolMismatch
        )
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .failed
        )
    }

    func testUnrelatedAppErrorCodeDoesNotCrossRefreshBoundary()
        async
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: {
                    throw AppError(
                        code: .githubGenericError,
                        message: "Safe fixture",
                        isRecoverable: true
                    )
                }
            ),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(
            harness.committer.failurePublications.first?
                .failure.kind,
            .transport
        )
        XCTAssertNil(
            harness.committer.failurePublications.first?
                .failure.legacyErrorCode
        )
    }

    func testUnclassifiedURLErrorDoesNotBypassLegacyAllowlist()
        async
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: {
                    throw URLError(.badURL)
                }
            ),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        let failure = harness.committer.failurePublications.first?
            .failure
        XCTAssertEqual(failure?.kind, .transport)
        XCTAssertNil(failure?.legacyErrorCode)
        let appError = failure.map {
            MenuBarManager.appError(for: $0)
        }
        XCTAssertEqual(
            appError?.code,
            .apiGenericError
        )
    }

    func testHTTPStatusAppErrorPublishesSanitizedDetail() async {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: {
                    throw AppError(
                        code: .apiRateLimited,
                        message: "Rate limited by Claude API",
                        isRecoverable: true,
                        statusCode: 429
                    )
                }
            ),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        let failure = harness.committer.failurePublications.first?
            .failure
        XCTAssertEqual(
            failure?.detail,
            "HTTP 429 — Rate limited by Claude API"
        )
    }

    func testURLErrorPublishesSanitizedDetail() async {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let urlError = URLError(.cannotConnectToHost)
        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: {
                    throw urlError
                }
            ),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        let failure = harness.committer.failurePublications.first?
            .failure
        XCTAssertNotNil(failure?.detail)
        XCTAssertTrue(
            failure?.detail?.contains("NSURLErrorDomain") ?? false
        )
        XCTAssertTrue(
            failure?.detail?.contains("\(urlError.errorCode)") ?? false
        )
    }

    func testAPISuccessPreservesCachedClaudeReport() async throws {
        let identity = makeIdentity(providerID: .claude)
        let cachedReport = try makeReport(
            providerID: .claude,
            marker: 7
        )
        let cached = ProfileCurrentUsage(
            providerID: .claude,
            providerRevision: identity.providerRevision,
            report: cachedReport,
            claudeUsage: makeClaudeUsage(marker: 7)
        )
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context,
            cached: [identity.profileID: cached]
        )

        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: { throw TestFailure.core },
                apiFetch: { Self.makeAPIUsage(spend: 8) }
            ),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(
            harness.committer.cachedUsage(
                for: identity.profileID
            )?.report,
            cachedReport
        )
    }

    func testClaudeCoreSuccessPreservesCachedAPIWhenAPIFails()
        async throws
    {
        let identity = makeIdentity(providerID: .claude)
        let cachedAPI = makeAPIUsage(spend: 9)
        let cached = ProfileCurrentUsage(
            providerID: .claude,
            providerRevision: identity.providerRevision,
            apiUsage: cachedAPI
        )
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context,
            cached: [identity.profileID: cached]
        )
        let coreResult = ProviderFetchResult(
            report: try makeReport(providerID: .claude),
            claudeUsage: makeClaudeUsage(marker: 10)
        )

        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: { coreResult },
                apiFetch: { throw TestFailure.api }
            ),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(
            harness.committer.cachedUsage(
                for: identity.profileID
            )?.apiUsage,
            cachedAPI
        )
    }

    func testCodexCoreSuccessClearsIncompatibleCachedAPI()
        async throws
    {
        let identity = makeIdentity()
        let cached = ProfileCurrentUsage(
            providerID: .codex,
            providerRevision: identity.providerRevision,
            apiUsage: makeAPIUsage(spend: 9)
        )
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context,
            cached: [identity.profileID: cached]
        )

        _ = await enqueue(
            makeImmediateJob(
                identity: identity,
                result: ProviderFetchResult(
                    report: try makeReport(providerID: .codex)
                )
            ),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertNil(
            harness.committer.cachedUsage(
                for: identity.profileID
            )?.apiUsage
        )
    }

    func testFirstFailureHasConsecutiveCountOne() async {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )

        _ = await enqueue(
            makeFailingJob(identity: identity),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(
            harness.store.snapshot(
                for: identity.profileID
            )?.currentFailure?.consecutiveCount,
            1
        )
    }

    func testConsecutiveFailuresIncrementCount() async {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )

        for count in 1...2 {
            _ = await enqueue(
                makeFailingJob(identity: identity),
                on: harness,
                context: context
            )
            await assertEventually {
                harness.batches.snapshot.count == count
            }
        }

        XCTAssertEqual(
            harness.store.snapshot(
                for: identity.profileID
            )?.currentFailure?.consecutiveCount,
            2
        )
    }

    func testLedgerFirstInvalidationSuppressesDelayedFailureEvent()
        async
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let failureGate = ManualGate<Void>()
        harness.committer.failureGate = failureGate

        _ = await enqueue(
            makeFailingJob(identity: identity),
            on: harness,
            context: context
        )
        let failureStarted = await waitForStarts(
            failureGate,
            count: 1
        )
        XCTAssertTrue(failureStarted)
        XCTAssertEqual(harness.batches.snapshot.count, 0)
        XCTAssertTrue(
            harness.committer.failurePublications.isEmpty
        )

        let invalidatedGeneration = harness.ledger.invalidate(
            profileID: identity.profileID
        )
        failureGate.resolve(())
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertTrue(
            harness.committer.failurePublications.isEmpty
        )
        XCTAssertEqual(
            harness.store.snapshot(
                for: identity.profileID
            )?.activity,
            .idle
        )
        XCTAssertNil(
            harness.store.snapshot(
                for: identity.profileID
            )?.currentFailure
        )
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .superseded
        )
        await harness.engine.invalidate(
            profileID: identity.profileID,
            beforeInputGeneration: invalidatedGeneration
        )
    }

    func testSnapshotSubscriberInvalidationSuppressesFailureEvent()
        async
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        var invalidatedGeneration: UInt64?
        let observation = harness.store.$snapshots.sink {
            snapshots in
            guard invalidatedGeneration == nil,
                  snapshots[identity.profileID]?
                    .currentFailure != nil else {
                return
            }
            invalidatedGeneration = harness.ledger.invalidate(
                profileID: identity.profileID
            )
        }

        _ = await enqueue(
            makeFailingJob(identity: identity),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertNotNil(invalidatedGeneration)
        XCTAssertTrue(
            harness.committer.failurePublications.isEmpty
        )
        XCTAssertNotNil(
            harness.store.snapshot(
                for: identity.profileID
            )?.currentFailure
        )
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .superseded
        )
        if let invalidatedGeneration {
            await harness.engine.invalidate(
                profileID: identity.profileID,
                beforeInputGeneration: invalidatedGeneration
            )
        }
        withExtendedLifetime(observation) {}
    }

    func testSuccessResetsSubsequentFailureCount() async throws {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )

        _ = await enqueue(
            makeFailingJob(identity: identity),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }
        _ = await enqueue(
            makeImmediateJob(
                identity: identity,
                result: ProviderFetchResult(
                    report: try makeReport(providerID: .codex)
                )
            ),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 2
        }
        _ = await enqueue(
            makeFailingJob(identity: identity),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 3
        }

        XCTAssertEqual(
            harness.store.snapshot(
                for: identity.profileID
            )?.currentFailure?.consecutiveCount,
            1
        )
    }

    /// Reproduces the exact scenario Greptile flagged on PR #94: a
    /// transport failure followed by a single credential rejection must
    /// NOT raise `MenuBarAttentionSignal`'s credential marker — the streak
    /// it reads (`sameKindConsecutiveCount`) has to reset when the failure
    /// kind changes, even though the kind-agnostic `consecutiveCount` kept
    /// climbing. Two consecutive credential rejections must still raise it.
    func testMixedKindFailuresDoNotAdvanceTheSameKindStreak() async {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )

        // 1) A non-credential (transport) failure.
        _ = await enqueue(
            makeFailingJob(identity: identity),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        // 2) A single credential (unauthenticated) rejection immediately
        // after. Overall consecutiveCount is now 2, but the kind changed.
        _ = await enqueue(
            Self.makeJob(
                identity: identity,
                coreFetch: { throw UsageProviderError.unauthenticated }
            ),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 2
        }

        let afterFirstCredentialFailure = harness.store.snapshot(
            for: identity.profileID
        )?.currentFailure
        XCTAssertEqual(
            afterFirstCredentialFailure?.consecutiveCount,
            2
        )
        XCTAssertEqual(
            afterFirstCredentialFailure?.sameKindConsecutiveCount,
            1,
            "A single credential rejection right after an unrelated " +
                "transport failure must not inherit that failure's count."
        )

        // 3) A second credential rejection in a row — the same-kind streak
        // must now advance to 2, which is the threshold that raises the
        // marker.
        _ = await enqueue(
            Self.makeJob(
                identity: identity,
                coreFetch: { throw UsageProviderError.unauthenticated }
            ),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 3
        }

        let afterSecondCredentialFailure = harness.store.snapshot(
            for: identity.profileID
        )?.currentFailure
        XCTAssertEqual(
            afterSecondCredentialFailure?.consecutiveCount,
            3
        )
        XCTAssertEqual(
            afterSecondCredentialFailure?.sameKindConsecutiveCount,
            2,
            "Two consecutive credential rejections must advance the " +
                "same-kind streak to the threshold."
        )
    }

    func testFailureRetainsCachedUsageInPresentation() async throws {
        let identity = makeIdentity()
        let report = try makeReport(
            providerID: .codex,
            marker: 33
        )
        let cached = ProfileCurrentUsage(
            providerID: .codex,
            providerRevision: identity.providerRevision,
            report: report
        )
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context,
            cached: [identity.profileID: cached]
        )

        _ = await enqueue(
            makeFailingJob(identity: identity),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(
            harness.store.snapshot(
                for: identity.profileID
            )?.report,
            report
        )
        XCTAssertNotNil(
            harness.store.snapshot(
                for: identity.profileID
            )?.currentFailure
        )
    }

    func testFiniteRefreshIntervalAssignsDoubleIntervalFreshness()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let report = try makeReport(providerID: .codex)

        _ = await enqueue(
            makeImmediateJob(
                identity: identity,
                refreshInterval: 400,
                result: ProviderFetchResult(report: report)
            ),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(
            harness.committer.cachedUsage(
                for: identity.profileID
            )?.report?.staleAt,
            report.fetchedAt.addingTimeInterval(800)
        )
    }

    func testInvalidRefreshIntervalAssignsFiveMinuteFreshness()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let report = try makeReport(providerID: .codex)

        _ = await enqueue(
            makeImmediateJob(
                identity: identity,
                refreshInterval: .infinity,
                result: ProviderFetchResult(report: report)
            ),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(
            harness.committer.cachedUsage(
                for: identity.profileID
            )?.report?.staleAt,
            report.fetchedAt.addingTimeInterval(300)
        )
    }

    func testStalePresentationContextSuppressesSnapshotButNotCommit()
        async throws
    {
        let identity = makeIdentity()
        let oldContext = makeContext(
            epoch: 1,
            visible: [identity.profileID]
        )
        let harness = makeHarness(
            identities: [identity],
            context: oldContext
        )
        let gate = ManualGate<ProviderFetchResult>()
        _ = await enqueue(
            makeGatedJob(identity: identity, gate: gate),
            on: harness,
            context: oldContext
        )
        let fetchStarted = await waitForStarts(gate, count: 1)
        XCTAssertTrue(fetchStarted)

        let newContext = makeContext(
            epoch: 2,
            visible: [identity.profileID]
        )
        harness.store.activate(newContext)
        gate.resolve(
            ProviderFetchResult(
                report: try makeReport(providerID: .codex)
            )
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(harness.committer.durableCommits.count, 1)
        XCTAssertEqual(harness.committer.acceptedPublications.count, 1)
        XCTAssertEqual(harness.committer.presentedPublications.count, 0)
        XCTAssertNil(harness.store.snapshot(for: identity.profileID))
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .superseded
        )
    }

    func testSnapshotSubscriberCanStaleProjectionButNotPresentedStage()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        var advanced = false
        let observation = harness.store.$snapshots.sink {
            snapshots in
            guard !advanced,
                  snapshots[identity.profileID]?.report != nil else {
                return
            }
            advanced = true
            harness.ledger.registerInvocation(
                2,
                profileIDs: [identity.profileID]
            )
        }

        _ = await enqueue(
            makeImmediateJob(
                identity: identity,
                result: ProviderFetchResult(
                    report: try makeReport(
                        providerID: .codex
                    )
                )
            ),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertTrue(advanced)
        XCTAssertEqual(harness.committer.durableCommits.count, 1)
        XCTAssertEqual(
            harness.committer.acceptedPublications.count,
            1
        )
        XCTAssertEqual(
            harness.committer.presentedPublications.count,
            0
        )
        XCTAssertNotNil(
            harness.store.snapshot(
                for: identity.profileID
            )?.report
        )
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .superseded
        )
        withExtendedLifetime(observation) {}
    }

    func testStalePresentationContextSuppressesFailurePublication()
        async
    {
        let identity = makeIdentity()
        let oldContext = makeContext(
            epoch: 1,
            visible: [identity.profileID]
        )
        let harness = makeHarness(
            identities: [identity],
            context: oldContext
        )
        let gate = ManualGate<Void>()
        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: {
                    await gate.wait()
                    throw TestFailure.core
                }
            ),
            on: harness,
            context: oldContext
        )
        let started = await waitForStarts(gate, count: 1)
        XCTAssertTrue(started)

        let newContext = makeContext(
            epoch: 2,
            visible: [identity.profileID]
        )
        harness.store.activate(newContext)
        gate.resolve(())
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertTrue(
            harness.committer.failurePublications.isEmpty
        )
        XCTAssertNil(harness.store.snapshot(for: identity.profileID))
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .superseded
        )
    }

    func testSingleToMultiContextChangeRejectsOldPresentation()
        async throws
    {
        let first = makeIdentity()
        let second = makeIdentity()
        let singleContext = UsagePresentationContext(
            epoch: 1,
            focusedProfileID: first.profileID,
            visibleProfileIDs: [first.profileID]
        )
        let harness = makeHarness(
            identities: [first],
            context: singleContext
        )
        let gate = ManualGate<ProviderFetchResult>()

        _ = await enqueue(
            makeGatedJob(identity: first, gate: gate),
            on: harness,
            context: singleContext
        )
        let fetchStarted = await waitForStarts(gate, count: 1)
        XCTAssertTrue(fetchStarted)
        let multiContext = UsagePresentationContext(
            epoch: 2,
            focusedProfileID: first.profileID,
            visibleProfileIDs: [
                first.profileID,
                second.profileID
            ]
        )
        harness.store.activate(multiContext)

        gate.resolve(
            ProviderFetchResult(
                report: try makeReport(providerID: .codex)
            )
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(harness.committer.durableCommits.count, 1)
        XCTAssertNil(harness.store.snapshot(for: first.profileID))
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[first.profileID]
            ),
            .superseded
        )
    }

    func testSelectedProfileChangeRejectsOldProfilePresentation()
        async throws
    {
        let first = makeIdentity()
        let second = makeIdentity()
        let firstContext = UsagePresentationContext(
            epoch: 5,
            focusedProfileID: first.profileID,
            visibleProfileIDs: [first.profileID]
        )
        let harness = makeHarness(
            identities: [first],
            context: firstContext
        )
        let gate = ManualGate<ProviderFetchResult>()

        _ = await enqueue(
            makeGatedJob(identity: first, gate: gate),
            on: harness,
            context: firstContext
        )
        let fetchStarted = await waitForStarts(gate, count: 1)
        XCTAssertTrue(fetchStarted)
        let secondContext = UsagePresentationContext(
            epoch: 5,
            focusedProfileID: second.profileID,
            visibleProfileIDs: [second.profileID]
        )
        harness.store.activate(secondContext)

        gate.resolve(
            ProviderFetchResult(
                report: try makeReport(providerID: .codex)
            )
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        XCTAssertEqual(harness.committer.durableCommits.count, 1)
        XCTAssertNil(harness.store.snapshot(for: first.profileID))
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[first.profileID]
            ),
            .superseded
        )
    }

    func testPendingRequestNeverReceivesLateIdleActivity()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let first = ManualGate<ProviderFetchResult>()
        let second = ManualGate<ProviderFetchResult>()
        let recordedActivities =
            Locked<[UsageRefreshActivity]>([])
        let shouldRecord = Locked(false)
        let activityObservation = harness.store.$snapshots.sink {
            snapshots in
            guard shouldRecord.snapshot(),
                  let activity =
                    snapshots[identity.profileID]?.activity else {
                return
            }
            recordedActivities.withValue {
                $0.append(activity)
            }
        }

        _ = await enqueue(
            makeGatedJob(identity: identity, gate: first),
            on: harness,
            context: context
        )
        let firstStarted = await waitForStarts(first, count: 1)
        XCTAssertTrue(firstStarted)
        shouldRecord.withValue { $0 = true }
        _ = await enqueue(
            makeGatedJob(identity: identity, gate: second),
            on: harness,
            context: context
        )
        first.resolve(
            ProviderFetchResult(
                report: try makeReport(providerID: .codex)
            )
        )
        let secondStarted = await waitForStarts(second, count: 1)
        XCTAssertTrue(secondStarted)

        await assertEventually {
            guard case .refreshing =
                    harness.store.snapshot(
                        for: identity.profileID
                    )?.activity else {
                return false
            }
            return true
        }
        XCTAssertFalse(
            recordedActivities.snapshot().contains(.idle)
        )
        second.resolve(
            ProviderFetchResult(
                report: try makeReport(providerID: .codex)
            )
        )
        await assertEventually {
            harness.batches.snapshot.count == 2
                && harness.store.snapshot(
                    for: identity.profileID
                )?.activity == .idle
        }
        let completedActivities = recordedActivities.snapshot()
        XCTAssertEqual(completedActivities.last, .idle)
        XCTAssertFalse(completedActivities.dropLast().contains(.idle))
        withExtendedLifetime(activityObservation) {}
    }

    func testQueuedPresentationRejectsOlderTerminalPublication()
        async throws
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )
        let terminalPresentationGate = ManualGate<Void>()
        harness.committer.presentationGate =
            terminalPresentationGate
        let latestFetch = ManualGate<ProviderFetchResult>()
        let recordedActivities =
            Locked<[UsageRefreshActivity]>([])
        let shouldRecord = Locked(false)
        let activityObservation = harness.store.$snapshots.sink {
            snapshots in
            guard shouldRecord.snapshot(),
                  let activity =
                    snapshots[identity.profileID]?.activity else {
                return
            }
            recordedActivities.withValue {
                $0.append(activity)
            }
        }

        _ = await enqueue(
            makeImmediateJob(
                identity: identity,
                result: ProviderFetchResult(
                    report: try makeReport(
                        providerID: .codex,
                        marker: 81
                    )
                )
            ),
            on: harness,
            context: context
        )
        let presentationStarted = await waitForStarts(
            terminalPresentationGate,
            count: 1
        )
        XCTAssertTrue(presentationStarted)
        guard case .refreshing(let oldRequestID, _, _) =
                harness.store.snapshot(
                    for: identity.profileID
                )?.activity else {
            return XCTFail("Expected the older request to be refreshing")
        }

        shouldRecord.withValue { $0 = true }
        _ = await enqueue(
            makeGatedJob(identity: identity, gate: latestFetch),
            on: harness,
            context: context
        )
        guard case .queued(let latestRequestID, _, _) =
                recordedActivities.snapshot().last else {
            return XCTFail("Expected the latest request to be queued")
        }
        XCTAssertNotEqual(latestRequestID, oldRequestID)

        terminalPresentationGate.resolve(())
        harness.committer.presentationGate = nil
        let latestStarted = await waitForStarts(
            latestFetch,
            count: 1
        )
        XCTAssertTrue(latestStarted)

        for activity in recordedActivities.snapshot() {
            switch activity {
            case .idle:
                XCTFail(
                    "Older terminal idle must not overwrite queued state"
                )
            case .refreshing(let requestID, _, _):
                XCTAssertEqual(requestID, latestRequestID)
            case .queued(let requestID, _, _):
                XCTAssertEqual(requestID, latestRequestID)
            }
        }

        latestFetch.resolve(
            ProviderFetchResult(
                report: try makeReport(
                    providerID: .codex,
                    marker: 82
                )
            )
        )
        await assertEventually {
            harness.batches.snapshot.count == 2
                && harness.store.snapshot(
                    for: identity.profileID
                )?.activity == .idle
        }
        withExtendedLifetime(activityObservation) {}
    }

    func testRejectedOlderStatusBeginIsReestablishedByNewerSameContext()
        async throws
    {
        let identity = makeIdentity(providerID: .claude)
        let context = makeContext(visible: [identity.profileID])
        let statusGate = ManualGate<ClaudeStatus>()
        let calls = Locked(0)
        let harness = makeHarness(
            identities: [identity],
            context: context,
            statusFetch: {
                calls.withValue { $0 += 1 }
                return await statusGate.wait()
            }
        )
        let job = makeImmediateJob(
            identity: identity,
            result: ProviderFetchResult(
                report: try makeReport(providerID: .claude)
            )
        )
        // Force the original order-1 begin to lose the MainActor ownership
        // race before the engine learns about order 2.
        harness.store.registerClaudeStatusInvocation(2)

        _ = await harness.engine.enqueue(
            [job],
            trigger: .manual,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 1,
            requestsClaudeStatus: true
        )
        let statusStarted = await waitForStarts(
            statusGate,
            count: 1
        )
        XCTAssertTrue(statusStarted)
        XCTAssertFalse(harness.store.claudeStatus.isRefreshing)

        _ = await harness.engine.enqueue(
            [job],
            trigger: .retry,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 2,
            requestsClaudeStatus: true
        )
        await assertEventually {
            harness.store.claudeStatus.isRefreshing
        }

        let newest = ClaudeStatus(
            indicator: .minor,
            description: "Newest"
        )
        statusGate.resolve(newest)
        await assertEventually {
            harness.store.claudeStatus.status == newest
                && !harness.store.claudeStatus.isRefreshing
        }
        XCTAssertEqual(calls.snapshot(), 1)
    }

    func testStatusABAUpgradeClearsStaleDifferentContextPending()
        async throws
    {
        let identity = makeIdentity(providerID: .claude)
        let contextA = makeContext(
            epoch: 1,
            visible: [identity.profileID]
        )
        let contextB = makeContext(
            epoch: 2,
            visible: [identity.profileID]
        )
        let statusGate = ManualGate<ClaudeStatus>()
        let calls = Locked(0)
        let harness = makeHarness(
            identities: [identity],
            context: contextA,
            statusFetch: {
                calls.withValue { $0 += 1 }
                return await statusGate.wait()
            }
        )
        let job = makeImmediateJob(
            identity: identity,
            result: ProviderFetchResult(
                report: try makeReport(providerID: .claude)
            )
        )

        _ = await harness.engine.enqueue(
            [job],
            trigger: .manual,
            presentationContext: contextA,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 1,
            requestsClaudeStatus: true
        )
        let firstStarted = await waitForStarts(
            statusGate,
            count: 1
        )
        XCTAssertTrue(firstStarted)
        _ = await harness.engine.enqueue(
            [job],
            trigger: .timer,
            presentationContext: contextB,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 2,
            requestsClaudeStatus: true
        )
        _ = await harness.engine.enqueue(
            [job],
            trigger: .retry,
            presentationContext: contextA,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 3,
            requestsClaudeStatus: true
        )
        await assertEventually {
            harness.store.claudeStatus.isRefreshing
                && harness.store.claudeStatus.presentationEpoch
                    == contextA.epoch
        }

        let newestA = ClaudeStatus(
            indicator: .major,
            description: "Newest A"
        )
        statusGate.resolve(newestA)
        await assertEventually {
            harness.store.claudeStatus.status == newestA
                && !harness.store.claudeStatus.isRefreshing
        }
        await Task.yield()

        XCTAssertEqual(calls.snapshot(), 1)
        XCTAssertEqual(
            harness.store.claudeStatus.presentationEpoch,
            contextA.epoch
        )
    }

    func testSameContextStatusRequestsCoalesce() async throws {
        let identity = makeIdentity(providerID: .claude)
        let context = makeContext(visible: [identity.profileID])
        let statusGate = ManualGate<ClaudeStatus>()
        let calls = Locked(0)
        let harness = makeHarness(
            identities: [identity],
            context: context,
            statusFetch: {
                calls.withValue { $0 += 1 }
                return await statusGate.wait()
            }
        )
        let job = makeImmediateJob(
            identity: identity,
            result: ProviderFetchResult(
                report: try makeReport(providerID: .claude)
            )
        )

        _ = await enqueue(job, on: harness, context: context)
        let statusStarted = await waitForStarts(statusGate, count: 1)
        XCTAssertTrue(statusStarted)
        _ = await enqueue(job, on: harness, context: context)
        await Task.yield()

        XCTAssertEqual(calls.snapshot(), 1)
        statusGate.resolve(.operational)
    }

    func testStatusCoalescingKeepsLatestPresentationContext()
        async throws
    {
        let identity = makeIdentity(providerID: .claude)
        let firstContext = makeContext(
            epoch: 1,
            visible: [identity.profileID]
        )
        let secondContext = makeContext(
            epoch: 2,
            visible: [identity.profileID]
        )
        let latestContext = makeContext(
            epoch: 3,
            visible: [identity.profileID]
        )
        let firstStatus = ManualGate<ClaudeStatus>()
        let latestStatus = ManualGate<ClaudeStatus>()
        let calls = Locked(0)
        let harness = makeHarness(
            identities: [identity],
            context: firstContext,
            statusFetch: {
                let call = calls.withValue {
                    $0 += 1
                    return $0
                }
                return await (
                    call == 1 ? firstStatus : latestStatus
                ).wait()
            }
        )
        let job = makeImmediateJob(
            identity: identity,
            result: ProviderFetchResult(
                report: try makeReport(providerID: .claude)
            )
        )

        _ = await enqueue(job, on: harness, context: firstContext)
        let firstStatusStarted = await waitForStarts(
            firstStatus,
            count: 1
        )
        XCTAssertTrue(firstStatusStarted)
        _ = await enqueue(job, on: harness, context: secondContext)
        _ = await enqueue(job, on: harness, context: latestContext)
        harness.store.activate(latestContext)
        firstStatus.resolve(.operational)
        let latestStatusStarted = await waitForStarts(
            latestStatus,
            count: 1
        )
        XCTAssertTrue(latestStatusStarted)
        let latest = ClaudeStatus(
            indicator: .minor,
            description: "Latest"
        )
        latestStatus.resolve(latest)
        let published = await eventually {
            harness.store.claudeStatus.status == latest
                && !harness.store.claudeStatus.isRefreshing
        }

        XCTAssertTrue(published)
        XCTAssertEqual(calls.snapshot(), 2)
        XCTAssertEqual(
            harness.store.claudeStatus.presentationEpoch,
            latestContext.epoch
        )
    }

    func testStatusFailureRetainsPreviousStatus() async throws {
        let identity = makeIdentity(providerID: .claude)
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context,
            statusFetch: { throw AppError.networkTimeout() }
        )
        harness.store.registerClaudeStatusInvocation(1)
        harness.store.publishClaudeStatus(
            .operational,
            expected: context,
            invocationOrder: 1
        )

        _ = await enqueue(
            makeImmediateJob(
                identity: identity,
                result: ProviderFetchResult(
                    report: try makeReport(providerID: .claude)
                )
            ),
            on: harness,
            context: context
        )
        let failed = await eventually {
            harness.store.claudeStatus.failedAt != nil
        }

        XCTAssertTrue(failed)
        XCTAssertEqual(harness.store.claudeStatus.status, .operational)
        XCTAssertFalse(harness.store.claudeStatus.isRefreshing)
        XCTAssertEqual(
            harness.store.claudeStatus.failure?.kind,
            .timedOut
        )
        XCTAssertEqual(
            harness.store.claudeStatus.failure?.legacyErrorCode,
            .networkTimeout
        )
    }

    func testRuntimeShutdownRejectsAllLatePresentationMutation()
        async throws
    {
        let profile = Profile(
            name: "Claude",
            claudeSessionKey: "session",
            organizationId: "organization"
        )
        let identity = ProviderRefreshIdentity(
            profileID: profile.id,
            providerID: .claude,
            providerRevision: profile.providerRevision
        )
        let usage = makeClaudeUsage(marker: 92)
        let statusGate = ManualGate<ClaudeStatus>()
        let presentationGate = ManualGate<Void>()
        let registry = UsageProviderRegistry(
            featureAvailability: .production,
            claudeRequestCapture: { _ in
                CapturedClaudeProviderRequest(
                    coreFetch: { usage }
                )
            },
            codexExecutableResolver: {
                throw TestFailure.core
            },
            codexFetchFactory: { _ in
                throw TestFailure.core
            },
            now: { TestValues.now }
        )
        let batches = BatchRecorder()
        let ledger = UsageRefreshInputLedger()
        let committer = FakeCommitter(ledger: ledger)
        committer.register(identity)
        committer.presentationGate = presentationGate
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches,
            registry: registry,
            statusFetch: { await statusGate.wait() }
        )
        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 1
        )
        let originalContext = runtime.presentationContext

        let refreshTask = runtime.refresh(
            profiles: [profile],
            trigger: .manual
        )
        let statusStarted = await waitForStarts(
            statusGate,
            count: 1
        )
        let presentationStarted = await waitForStarts(
            presentationGate,
            count: 1
        )
        XCTAssertTrue(statusStarted)
        XCTAssertTrue(presentationStarted)

        runtime.shutdown(profiles: [profile])
        XCTAssertTrue(runtime.presentationStore.snapshots.isEmpty)
        XCTAssertFalse(
            runtime.presentationStore.claudeStatus.isRefreshing
        )

        let lateContext = makeContext(
            epoch: 99,
            visible: [profile.id]
        )
        let lateReport = try makeReport(
            providerID: .claude,
            marker: 99
        )
        let lateSnapshot = makeSnapshot(
            identity: identity,
            epoch: originalContext.epoch,
            report: lateReport
        )
        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: lateContext.epoch
        )
        runtime.presentationStore.activate(
            lateContext,
            hydrated: [profile.id: lateSnapshot]
        )
        runtime.presentationStore.registerActivityInvocation(
            99,
            profileIDs: [profile.id]
        )
        runtime.presentationStore.registerClaudeStatusInvocation(99)
        runtime.presentationStore.markDeleting(profileID: profile.id)

        XCTAssertFalse(
            runtime.presentationStore.publish(
                lateSnapshot,
                expected: originalContext,
                invocationOrder: 99
            )
        )
        XCTAssertFalse(
            runtime.presentationStore.beginClaudeStatus(
                expected: originalContext,
                invocationOrder: 99
            )
        )
        XCTAssertFalse(
            runtime.presentationStore.publishClaudeStatus(
                .operational,
                expected: originalContext,
                invocationOrder: 99
            )
        )

        presentationGate.resolve(())
        statusGate.resolve(.operational)
        _ = await refreshTask.value
        await runtime.shutdownAndWait(profiles: [profile])
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertEqual(runtime.presentationContext, originalContext)
        XCTAssertEqual(
            runtime.presentationStore.context,
            originalContext
        )
        XCTAssertTrue(runtime.presentationStore.snapshots.isEmpty)
        XCTAssertEqual(
            runtime.presentationStore.claudeStatus.status,
            .unknown
        )
        XCTAssertFalse(
            runtime.presentationStore.claudeStatus.isRefreshing
        )
        XCTAssertNil(runtime.presentationStore.claudeStatus.failure)
    }

    func testRuntimeShutdownWaitsForCancelledFetchToExit()
        async
    {
        let profile = Profile(
            name: "Claude",
            claudeSessionKey: "session",
            organizationId: "organization"
        )
        let identity = ProviderRefreshIdentity(
            profileID: profile.id,
            providerID: .claude,
            providerRevision: profile.providerRevision
        )
        let exited = Locked(false)
        let gate = CancellationGate<ClaudeUsage> {
            exited.withValue { $0 = true }
        }
        let registry = UsageProviderRegistry(
            featureAvailability: .production,
            claudeRequestCapture: { _ in
                CapturedClaudeProviderRequest(
                    coreFetch: {
                        try await gate.wait()
                    }
                )
            },
            codexExecutableResolver: {
                throw TestFailure.core
            },
            codexFetchFactory: { _ in
                throw TestFailure.core
            },
            now: { TestValues.now }
        )
        let batches = BatchRecorder()
        let ledger = UsageRefreshInputLedger()
        let committer = FakeCommitter(ledger: ledger)
        committer.register(identity)
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches,
            registry: registry
        )
        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 1
        )

        let refreshTask = runtime.refresh(
            profiles: [profile],
            trigger: .manual
        )
        let started = await waitForStarts(gate, count: 1)
        XCTAssertTrue(started)

        await runtime.shutdownAndWait(profiles: [profile])
        _ = await refreshTask.value

        XCTAssertTrue(exited.snapshot())
        XCTAssertTrue(runtime.presentationStore.snapshots.isEmpty)
        XCTAssertTrue(batches.snapshot.isEmpty)
    }

    func testRuntimeDuplicateIDsFailClosedBeforeProviderCapture()
        async
    {
        let duplicateID = UUID()
        let first = Profile(
            name: "First",
            claudeSessionKey: "session-first",
            organizationId: "organization-first"
        )
        let duplicateClaude = Profile(
            id: duplicateID,
            name: "Duplicate Claude",
            claudeSessionKey: "session-duplicate",
            organizationId: "organization-duplicate"
        )
        let second = Profile(
            name: "Second",
            claudeSessionKey: "session-second",
            organizationId: "organization-second"
        )
        let duplicateCodex = Profile(
            id: duplicateID,
            name: "Duplicate Codex",
            providerConfiguration: .codex(.init())
        )
        let firstIdentity = ProviderRefreshIdentity(
            profileID: first.id,
            providerID: .claude,
            providerRevision: first.providerRevision
        )
        let secondIdentity = ProviderRefreshIdentity(
            profileID: second.id,
            providerID: .claude,
            providerRevision: second.providerRevision
        )
        let captureOrder = Locked<[UUID]>([])
        let codexResolverCalls = Locked(0)
        let codexFactoryCalls = Locked(0)
        let statusFetches = Locked(0)
        let usage = makeClaudeUsage(marker: 63)
        let registry = UsageProviderRegistry(
            featureAvailability: .testing(),
            claudeRequestCapture: { profile in
                captureOrder.withValue { $0.append(profile.id) }
                return CapturedClaudeProviderRequest(
                    coreFetch: { usage }
                )
            },
            codexExecutableResolver: {
                codexResolverCalls.withValue { $0 += 1 }
                throw TestFailure.core
            },
            codexFetchFactory: { _ in
                codexFactoryCalls.withValue { $0 += 1 }
                throw TestFailure.core
            },
            now: { TestValues.now }
        )
        let batches = BatchRecorder()
        let ledger = UsageRefreshInputLedger()
        let committer = FakeCommitter(ledger: ledger)
        committer.register(firstIdentity)
        committer.register(secondIdentity)
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches,
            registry: registry,
            statusFetch: {
                statusFetches.withValue { $0 += 1 }
                return .operational
            }
        )
        runtime.activate(
            profiles: [first, second],
            focusedProfileID: first.id,
            visibleProfileIDs: [
                first.id,
                second.id,
                duplicateID
            ],
            epoch: 1,
            mode: .multi
        )
        var failureEvents = [UsageRefreshFailureEvent]()
        _ = runtime.eventHub.observeFailures {
            failureEvents.append($0)
        }

        _ = await runtime.refresh(
            profiles: [
                first,
                duplicateClaude,
                second,
                duplicateCodex
            ],
            trigger: .manual
        ).value
        await assertEventually {
            batches.snapshot.count == 1
                && statusFetches.snapshot() == 1
        }

        XCTAssertEqual(captureOrder.snapshot(), [first.id, second.id])
        XCTAssertEqual(codexResolverCalls.snapshot(), 0)
        XCTAssertEqual(codexFactoryCalls.snapshot(), 0)
        XCTAssertEqual(batches.snapshot[0].outcomes.count, 3)
        XCTAssertEqual(
            outcome(batches.snapshot[0].outcomes[first.id]),
            .accepted
        )
        XCTAssertEqual(
            outcome(batches.snapshot[0].outcomes[second.id]),
            .accepted
        )
        XCTAssertEqual(
            outcome(batches.snapshot[0].outcomes[duplicateID]),
            .unavailable
        )
        XCTAssertFalse(
            committer.commitAttempts.contains {
                $0.identity.profileID == duplicateID
            }
        )
        XCTAssertFalse(
            committer.failurePublications.contains {
                $0.identity.profileID == duplicateID
            }
        )
        XCTAssertTrue(failureEvents.isEmpty)
    }

    func testRuntimeCaptureUnavailablePublishesTypedFailure()
        async
    {
        let profile = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init())
        )
        let identity = ProviderRefreshIdentity(
            profileID: profile.id,
            providerID: .codex,
            providerRevision: profile.providerRevision
        )
        let batches = BatchRecorder()
        let ledger = UsageRefreshInputLedger()
        let committer = FakeCommitter(ledger: ledger)
        committer.register(identity)
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches,
            featureAvailability: .testing(
                codexRefreshEnabled: false
            )
        )
        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 1
        )

        _ = await runtime.refresh(
            profiles: [profile],
            trigger: .manual
        ).value
        await assertEventually {
            batches.snapshot.count == 1
        }

        XCTAssertEqual(
            outcome(batches.snapshot[0].outcomes[profile.id]),
            .unavailable
        )
        XCTAssertEqual(
            runtime.presentationStore.snapshot(
                for: profile.id
            )?.configurationState,
            .disabled
        )
        XCTAssertEqual(
            runtime.presentationStore.snapshot(
                for: profile.id
            )?.currentFailure?.kind,
            .disabled
        )
    }

    func testRuntimeCaptureFailureSubscriberInvalidationSuppressesEvent()
        async
    {
        let profile = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init())
        )
        let identity = ProviderRefreshIdentity(
            profileID: profile.id,
            providerID: .codex,
            providerRevision: profile.providerRevision
        )
        let batches = BatchRecorder()
        let ledger = UsageRefreshInputLedger()
        let committer = FakeCommitter(ledger: ledger)
        committer.register(identity)
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches,
            featureAvailability: .testing(
                codexRefreshEnabled: false
            )
        )
        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 1
        )
        var failureEvents: [UsageRefreshFailureEvent] = []
        _ = runtime.eventHub.observeFailures {
            failureEvents.append($0)
        }
        var armed = false
        var invalidatedGeneration: UInt64?
        let observation = runtime.presentationStore.$snapshots.sink {
            snapshots in
            guard armed,
                  invalidatedGeneration == nil,
                  snapshots[profile.id]?.currentFailure != nil else {
                return
            }
            invalidatedGeneration = ledger.invalidate(
                profileID: profile.id
            )
        }
        armed = true

        _ = await runtime.refresh(
            profiles: [profile],
            trigger: .manual
        ).value
        await assertEventually {
            batches.snapshot.count == 1
        }

        XCTAssertNotNil(invalidatedGeneration)
        XCTAssertTrue(failureEvents.isEmpty)
        XCTAssertEqual(
            outcome(batches.snapshot[0].outcomes[profile.id]),
            .superseded
        )
        XCTAssertEqual(
            runtime.presentationStore.snapshot(
                for: profile.id
            )?.currentFailure?.kind,
            .disabled
        )
        withExtendedLifetime(observation) {}
    }

    func testRuntimeCaptureSelfInvalidationSuppressesFailureEvent()
        async
    {
        let profile = Profile(
            name: "Claude",
            claudeSessionKey: "session",
            organizationId: "organization"
        )
        let identity = ProviderRefreshIdentity(
            profileID: profile.id,
            providerID: .claude,
            providerRevision: profile.providerRevision
        )
        let ledger = UsageRefreshInputLedger()
        let registry = UsageProviderRegistry(
            featureAvailability: .production,
            claudeRequestCapture: { capturedProfile in
                _ = ledger.invalidate(
                    profileID: capturedProfile.id
                )
                throw TestFailure.core
            },
            codexExecutableResolver: {
                throw TestFailure.core
            },
            codexFetchFactory: { _ in
                throw TestFailure.core
            },
            now: { TestValues.now }
        )
        let batches = BatchRecorder()
        let committer = FakeCommitter(ledger: ledger)
        committer.register(identity)
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches,
            registry: registry
        )
        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 1
        )
        var failureEvents: [UsageRefreshFailureEvent] = []
        _ = runtime.eventHub.observeFailures {
            failureEvents.append($0)
        }

        _ = await runtime.refresh(
            profiles: [profile],
            trigger: .manual
        ).value
        await assertEventually {
            batches.snapshot.count == 1
        }

        XCTAssertEqual(ledger.generation(for: profile.id), 1)
        XCTAssertTrue(failureEvents.isEmpty)
        XCTAssertNil(
            runtime.presentationStore.snapshot(
                for: profile.id
            )?.currentFailure
        )
        XCTAssertEqual(
            outcome(batches.snapshot[0].outcomes[profile.id]),
            .superseded
        )
    }

    func testSecondCaptureInvalidationSupersedesAlreadyCapturedProfile()
        async
    {
        let profileA = Profile(
            name: "Claude A",
            claudeSessionKey: "session-a",
            organizationId: "organization-a"
        )
        let profileB = Profile(
            name: "Claude B",
            claudeSessionKey: "session-b",
            organizationId: "organization-b"
        )
        let identityA = ProviderRefreshIdentity(
            profileID: profileA.id,
            providerID: .claude,
            providerRevision: profileA.providerRevision
        )
        let identityB = ProviderRefreshIdentity(
            profileID: profileB.id,
            providerID: .claude,
            providerRevision: profileB.providerRevision
        )
        let ledger = UsageRefreshInputLedger()
        let fetchesA = Locked(0)
        let usageA = makeClaudeUsage(marker: 61)
        let usageB = makeClaudeUsage(marker: 62)
        let registry = UsageProviderRegistry(
            featureAvailability: .production,
            claudeRequestCapture: { capturedProfile in
                if capturedProfile.id == profileA.id {
                    return CapturedClaudeProviderRequest(
                        coreFetch: {
                            fetchesA.withValue { $0 += 1 }
                            return usageA
                        }
                    )
                }
                _ = ledger.invalidate(profileID: profileA.id)
                return CapturedClaudeProviderRequest(
                    coreFetch: { usageB }
                )
            },
            codexExecutableResolver: {
                throw TestFailure.core
            },
            codexFetchFactory: { _ in
                throw TestFailure.core
            },
            now: { TestValues.now }
        )
        let batches = BatchRecorder()
        let committer = FakeCommitter(ledger: ledger)
        committer.register(identityA)
        committer.register(identityB)
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches,
            registry: registry
        )
        runtime.activate(
            profiles: [profileA, profileB],
            focusedProfileID: profileA.id,
            visibleProfileIDs: [profileA.id, profileB.id],
            epoch: 1,
            mode: .multi
        )

        _ = await runtime.refresh(
            profiles: [profileA, profileB],
            trigger: .manual
        ).value
        await assertEventually {
            batches.snapshot.count == 1
        }

        XCTAssertEqual(fetchesA.snapshot(), 0)
        XCTAssertFalse(
            committer.durableCommits.contains {
                $0.0.identity.profileID == profileA.id
            }
        )
        XCTAssertFalse(
            committer.acceptedPublications.contains {
                $0.0.identity.profileID == profileA.id
            }
        )
        XCTAssertEqual(
            outcome(batches.snapshot[0].outcomes[profileA.id]),
            .superseded
        )
        XCTAssertEqual(
            outcome(batches.snapshot[0].outcomes[profileB.id]),
            .accepted
        )
    }

    func testRuntimePropagatesMonotonicInvocationOrder()
        async
    {
        let profile = Profile(
            name: "Claude",
            claudeSessionKey: "session",
            organizationId: "organization"
        )
        let identity = ProviderRefreshIdentity(
            profileID: profile.id,
            providerID: .claude,
            providerRevision: profile.providerRevision
        )
        let firstUsage = ManualGate<ClaudeUsage>()
        let registry = UsageProviderRegistry(
            featureAvailability: .production,
            claudeRequestCapture: { _ in
                CapturedClaudeProviderRequest(
                    coreFetch: {
                        await firstUsage.wait()
                    }
                )
            },
            codexExecutableResolver: {
                throw TestFailure.core
            },
            codexFetchFactory: { _ in
                throw TestFailure.core
            },
            now: { TestValues.now }
        )
        let batches = BatchRecorder()
        let ledger = UsageRefreshInputLedger()
        let committer = FakeCommitter(ledger: ledger)
        committer.register(identity)
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches,
            registry: registry
        )
        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 1
        )

        let firstTask = runtime.refresh(
            profiles: [profile],
            trigger: .manual
        )
        let firstStarted = await waitForStarts(
            firstUsage,
            count: 1
        )
        XCTAssertTrue(firstStarted)
        let secondTask = runtime.refresh(
            profiles: [],
            trigger: .retry
        )
        _ = await secondTask.value
        await assertEventually {
            batches.snapshot.contains {
                $0.invocationOrder == 2
            }
        }

        firstUsage.resolve(makeClaudeUsage(marker: 91))
        _ = await firstTask.value
        await assertEventually {
            batches.snapshot.count == 2
        }

        let firstBatch = batches.snapshot.first {
            $0.invocationOrder == 1
        }
        let secondBatch = batches.snapshot.first {
            $0.invocationOrder == 2
        }
        XCTAssertEqual(firstBatch?.trigger, .manual)
        XCTAssertEqual(secondBatch?.trigger, .retry)
        XCTAssertFalse(firstBatch?.isLatestBatch == true)
        XCTAssertTrue(secondBatch?.isLatestBatch == true)
    }

    func testRuntimeDisabledCodexHydrationDoesNotResolveExecutable()
        throws
    {
        let home = try CodexHomeCanonicalizer().canonicalize(
            FileManager.default.temporaryDirectory.path
        )
        let profile = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init(linkedHome: home))
        )
        let identity = ProviderRefreshIdentity(
            profileID: profile.id,
            providerID: .codex,
            providerRevision: profile.providerRevision
        )
        let resolverCalls = Locked(0)
        let registry = UsageProviderRegistry(
            featureAvailability: .testing(
                codexRefreshEnabled: false
            ),
            claudeRequestCapture: { _ in
                throw TestFailure.core
            },
            codexExecutableResolver: {
                resolverCalls.withValue { $0 += 1 }
                return URL(fileURLWithPath: "/usr/bin/false")
            },
            codexFetchFactory: { _ in
                throw TestFailure.core
            },
            now: { TestValues.now }
        )
        let batches = BatchRecorder()
        let ledger = UsageRefreshInputLedger()
        let committer = FakeCommitter(ledger: ledger)
        committer.register(identity)
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches,
            registry: registry
        )

        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 1
        )

        XCTAssertEqual(resolverCalls.snapshot(), 0)
        XCTAssertEqual(
            runtime.presentationStore.snapshot(
                for: profile.id
            )?.configurationState,
            .disabled
        )
    }

    func testRuntimeUnlinkedCodexHydratesUnlinkedWithoutResolver() {
        let profile = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init())
        )
        let identity = ProviderRefreshIdentity(
            profileID: profile.id,
            providerID: .codex,
            providerRevision: profile.providerRevision
        )
        let resolverCalls = Locked(0)
        let registry = UsageProviderRegistry(
            featureAvailability: .testing(),
            claudeRequestCapture: { _ in
                throw TestFailure.core
            },
            codexExecutableResolver: {
                resolverCalls.withValue { $0 += 1 }
                return URL(fileURLWithPath: "/usr/bin/false")
            },
            codexFetchFactory: { _ in
                throw TestFailure.core
            },
            now: { TestValues.now }
        )
        let batches = BatchRecorder()
        let ledger = UsageRefreshInputLedger()
        let committer = FakeCommitter(ledger: ledger)
        committer.register(identity)
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches,
            registry: registry
        )

        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 1
        )

        XCTAssertEqual(resolverCalls.snapshot(), 0)
        XCTAssertEqual(
            runtime.presentationStore.snapshot(
                for: profile.id
            )?.configurationState,
            .unlinked
        )
    }

    func testRuntimeClaudeWithoutCredentialsHydratesUnauthenticated() {
        let profile = Profile(name: "Claude")
        let identity = ProviderRefreshIdentity(
            profileID: profile.id,
            providerID: .claude,
            providerRevision: profile.providerRevision
        )
        let batches = BatchRecorder()
        let ledger = UsageRefreshInputLedger()
        let committer = FakeCommitter(ledger: ledger)
        committer.register(identity)
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches
        )

        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 1
        )

        XCTAssertEqual(
            runtime.presentationStore.snapshot(
                for: profile.id
            )?.configurationState,
            .unauthenticated
        )
    }

    func testDeletionTombstoneSurvivesReactivationAndModeSwitch()
        throws
    {
        let linkedHome = try CodexHomeCanonicalizer().canonicalize(
            FileManager.default.temporaryDirectory.path
        )
        let profile = Profile(
            name: "Codex",
            providerConfiguration: .codex(
                .init(linkedHome: linkedHome)
            )
        )
        let identity = ProviderRefreshIdentity(
            profileID: profile.id,
            providerID: .codex,
            providerRevision: profile.providerRevision
        )
        let report = try makeReport(
            providerID: .codex,
            marker: 51
        )
        let batches = BatchRecorder()
        let ledger = UsageRefreshInputLedger()
        let committer = FakeCommitter(ledger: ledger)
        committer.register(
            identity,
            usage: ProfileCurrentUsage(
                providerID: .codex,
                providerRevision: profile.providerRevision,
                report: report
            )
        )
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches
        )
        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 1,
            mode: .single
        )

        runtime.beginDeletion(profileID: profile.id)
        XCTAssertEqual(
            runtime.presentationStore.snapshot(
                for: profile.id
            )?.configurationState,
            .deleting
        )
        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 2,
            mode: .multi
        )

        let retained = runtime.presentationStore.snapshot(
            for: profile.id
        )
        XCTAssertEqual(retained?.configurationState, .deleting)
        XCTAssertEqual(retained?.report, report)
        XCTAssertEqual(retained?.presentationEpoch, 2)
        XCTAssertEqual(runtime.presentationContext.mode, .multi)
    }

    func testPersistedDeletionProfileHydratesDeletingWithoutCapture()
        async throws
    {
        let profile = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init()),
            deletionInProgress: true
        )
        let identity = ProviderRefreshIdentity(
            profileID: profile.id,
            providerID: .codex,
            providerRevision: profile.providerRevision
        )
        let report = try makeReport(
            providerID: .codex,
            marker: 52
        )
        let captures = Locked(0)
        let registry = UsageProviderRegistry(
            featureAvailability: .testing(),
            claudeRequestCapture: { _ in
                captures.withValue { $0 += 1 }
                throw TestFailure.core
            },
            codexExecutableResolver: {
                captures.withValue { $0 += 1 }
                throw TestFailure.core
            },
            codexFetchFactory: { _ in
                captures.withValue { $0 += 1 }
                throw TestFailure.core
            },
            now: { TestValues.now }
        )
        let batches = BatchRecorder()
        let ledger = UsageRefreshInputLedger()
        let committer = FakeCommitter(ledger: ledger)
        committer.register(
            identity,
            usage: ProfileCurrentUsage(
                providerID: .codex,
                providerRevision: profile.providerRevision,
                report: report
            )
        )
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches,
            registry: registry
        )

        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 1,
            mode: .single
        )
        _ = await runtime.refresh(
            profiles: [profile],
            trigger: .manual
        ).value

        XCTAssertEqual(captures.snapshot(), 0)
        XCTAssertEqual(
            runtime.presentationStore.snapshot(
                for: profile.id
            )?.configurationState,
            .deleting
        )
        XCTAssertEqual(
            runtime.presentationStore.snapshot(
                for: profile.id
            )?.report,
            nil
        )
        XCTAssertTrue(runtime.inputLedger.isDeleting(profile.id))
    }

    func testRuntimeVerifiedDeletionCompletionPurgesTombstone()
        async throws
    {
        let profile = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init())
        )
        let identity = ProviderRefreshIdentity(
            profileID: profile.id,
            providerID: .codex,
            providerRevision: profile.providerRevision
        )
        let batches = BatchRecorder()
        let ledger = UsageRefreshInputLedger()
        let committer = FakeCommitter(ledger: ledger)
        committer.register(
            identity,
            usage: ProfileCurrentUsage(
                providerID: .codex,
                providerRevision: profile.providerRevision,
                report: try makeReport(providerID: .codex)
            )
        )
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches
        )
        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 1
        )
        runtime.beginDeletion(profileID: profile.id)
        XCTAssertNotNil(
            runtime.presentationStore.snapshot(for: profile.id)
        )

        runtime.completeDeletion(profileID: profile.id)
        await assertEventually {
            runtime.presentationStore.snapshot(
                for: profile.id
            ) == nil
                && runtime.inputLedger.generation(
                    for: profile.id
                ) == 2
        }

        XCTAssertTrue(runtime.inputLedger.isDeleting(profile.id))
    }

    func testSingleReactivationAfterCredentialRemovalClearsUsage()
        throws
    {
        var profile = Profile(
            name: "Claude",
            claudeSessionKey: "session",
            organizationId: "organization"
        )
        let identity = ProviderRefreshIdentity(
            profileID: profile.id,
            providerID: .claude,
            providerRevision: profile.providerRevision
        )
        let cached = ProfileCurrentUsage(
            providerID: .claude,
            providerRevision: profile.providerRevision,
            report: try makeReport(providerID: .claude),
            claudeUsage: makeClaudeUsage(marker: 1),
            apiUsage: makeAPIUsage(spend: 1)
        )
        let batches = BatchRecorder()
        let ledger = UsageRefreshInputLedger()
        let committer = FakeCommitter(ledger: ledger)
        committer.register(identity, usage: cached)
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches
        )
        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 1,
            mode: .single
        )
        XCTAssertNotNil(
            runtime.presentationStore.snapshot(
                for: profile.id
            )?.report
        )

        profile.claudeSessionKey = nil
        profile.organizationId = nil
        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 2,
            mode: .single
        )

        let snapshot = runtime.presentationStore.snapshot(
            for: profile.id
        )
        XCTAssertEqual(snapshot?.configurationState, .unauthenticated)
        XCTAssertNil(snapshot?.report)
        XCTAssertNil(snapshot?.claudeUsage)
        XCTAssertNil(snapshot?.claudeAPIUsage)
    }

    func testSelectedMultiReactivationAfterCredentialRemovalClearsUsage()
        throws
    {
        var profile = Profile(
            name: "Claude",
            claudeSessionKey: "session",
            organizationId: "organization",
            isSelectedForDisplay: true
        )
        let identity = ProviderRefreshIdentity(
            profileID: profile.id,
            providerID: .claude,
            providerRevision: profile.providerRevision
        )
        let cached = ProfileCurrentUsage(
            providerID: .claude,
            providerRevision: profile.providerRevision,
            report: try makeReport(providerID: .claude),
            claudeUsage: makeClaudeUsage(marker: 2),
            apiUsage: makeAPIUsage(spend: 2)
        )
        let batches = BatchRecorder()
        let ledger = UsageRefreshInputLedger()
        let committer = FakeCommitter(ledger: ledger)
        committer.register(identity, usage: cached)
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches
        )
        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 1,
            mode: .multi
        )

        profile.claudeSessionKey = nil
        profile.organizationId = nil
        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 2,
            mode: .multi
        )

        let snapshot = runtime.presentationStore.snapshot(
            for: profile.id
        )
        XCTAssertEqual(snapshot?.configurationState, .unauthenticated)
        XCTAssertNil(snapshot?.report)
        XCTAssertNil(snapshot?.claudeUsage)
        XCTAssertNil(snapshot?.claudeAPIUsage)
        XCTAssertEqual(runtime.presentationContext.mode, .multi)
    }

    func testRuntimeRefreshAfterShutdownDoesNotCaptureOrCommit()
        async
    {
        let profile = Profile(name: "Claude")
        let identity = ProviderRefreshIdentity(
            profileID: profile.id,
            providerID: .claude,
            providerRevision: profile.providerRevision
        )
        let captures = Locked(0)
        let usage = makeClaudeUsage(marker: 1)
        let registry = UsageProviderRegistry(
            featureAvailability: .testing(),
            claudeRequestCapture: { _ in
                captures.withValue { $0 += 1 }
                return CapturedClaudeProviderRequest(
                    coreFetch: { usage }
                )
            },
            codexExecutableResolver: {
                throw TestFailure.core
            },
            codexFetchFactory: { _ in
                throw TestFailure.core
            },
            now: { TestValues.now }
        )
        let batches = BatchRecorder()
        let ledger = UsageRefreshInputLedger()
        let committer = FakeCommitter(ledger: ledger)
        committer.register(identity)
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches,
            registry: registry
        )
        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 1
        )

        runtime.shutdown(profiles: [profile])
        _ = await runtime.refresh(
            profiles: [profile],
            trigger: .manual
        ).value

        XCTAssertEqual(captures.snapshot(), 0)
        XCTAssertEqual(committer.commitAttempts.count, 0)
        XCTAssertTrue(runtime.presentationStore.snapshots.isEmpty)
    }

    func testRuntimeShutdownFencesLateEngineBatchCallbacks()
        async throws
    {
        let identity = makeIdentity()
        let batches = BatchRecorder()
        let ledger = UsageRefreshInputLedger()
        let committer = FakeCommitter(ledger: ledger)
        committer.register(identity)
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches
        )
        var eventBatches: [UsageRefreshBatchResult] = []
        _ = runtime.eventHub.observeBatches {
            eventBatches.append($0)
        }
        await runtime.shutdownAndWait(profiles: [])

        _ = await runtime.engine.enqueue(
            [
                makeImmediateJob(
                    identity: identity,
                    result: ProviderFetchResult(
                        report: try makeReport(
                            providerID: .codex
                        )
                    )
                )
            ],
            trigger: .manual,
            presentationContext: .empty,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 1
        )

        XCTAssertTrue(batches.snapshot.isEmpty)
        XCTAssertTrue(eventBatches.isEmpty)
        XCTAssertTrue(committer.commitAttempts.isEmpty)
    }

    func testRuntimeEmptyRefreshCompletesEmptyBatch() async {
        let batches = BatchRecorder()
        let ledger = UsageRefreshInputLedger()
        let committer = FakeCommitter(ledger: ledger)
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches
        )
        var observedBatches: [UsageRefreshBatchResult] = []
        _ = runtime.eventHub.observeBatches {
            observedBatches.append($0)
        }
        runtime.activate(
            profiles: [],
            focusedProfileID: nil,
            visibleProfileIDs: [],
            epoch: 1
        )

        _ = await runtime.refresh(
            profiles: [],
            trigger: .startup
        ).value

        XCTAssertEqual(batches.snapshot.count, 1)
        XCTAssertTrue(batches.snapshot[0].outcomes.isEmpty)
        XCTAssertEqual(observedBatches.count, 1)
        XCTAssertEqual(observedBatches.first?.trigger, .startup)
        XCTAssertEqual(
            observedBatches.first?.presentationContext,
            runtime.presentationContext
        )
    }

    func testRuntimeBatchNormalizationPublishesDemotedVerdictAtomically()
        async
    {
        let batches = BatchRecorder()
        let ledger = UsageRefreshInputLedger()
        let committer = FakeCommitter(ledger: ledger)
        let runtime = makeRuntime(
            ledger: ledger,
            committer: committer,
            batches: batches
        )
        var eventResults: [
            (result: UsageRefreshBatchResult, ledgerOrder: UInt64)
        ] = []
        _ = runtime.eventHub.observeBatches { result in
            eventResults.append(
                (result, ledger.latestInvocationOrder)
            )
        }
        runtime.activate(
            profiles: [],
            focusedProfileID: nil,
            visibleProfileIDs: [],
            epoch: 1
        )

        // The engine has not seen invocation two, but the runtime input
        // ledger has. This deterministically exercises the MainActor
        // normalization boundary without relying on task scheduling.
        ledger.registerInvocation(2, profileIDs: [])
        _ = await runtime.engine.enqueue(
            [],
            trigger: .manual,
            presentationContext: runtime.presentationContext,
            inputGenerations: [:],
            invocationOrder: 1
        )

        XCTAssertEqual(eventResults.count, 1)
        XCTAssertEqual(eventResults[0].result.invocationOrder, 1)
        XCTAssertFalse(eventResults[0].result.isLatestBatch)
        XCTAssertEqual(eventResults[0].ledgerOrder, 2)
        XCTAssertEqual(batches.snapshot.count, 1)
        XCTAssertFalse(batches.snapshot[0].isLatestBatch)
    }

    // MARK: - Error fidelity: 429/5xx classification

    func testAppErrorRateLimitedClassifiesAsRateLimitedWithRetryAfterAndLegacyCode()
        async
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )

        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: {
                    throw AppError.apiRateLimited(retryAfter: 42)
                }
            ),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        let failure = harness.store.snapshot(
            for: identity.profileID
        )?.currentFailure
        XCTAssertEqual(failure?.kind, .rateLimited)
        XCTAssertEqual(failure?.retryAfter, 42)
        XCTAssertEqual(failure?.legacyErrorCode, .apiRateLimited)
        XCTAssertEqual(
            failure?.retryNotBefore,
            TestValues.now.addingTimeInterval(42)
        )
    }

    func testAppErrorServerErrorClassifiesAsServerErrorWithLegacyCode()
        async
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let harness = makeHarness(
            identities: [identity],
            context: context
        )

        _ = await enqueue(
            makeJob(
                identity: identity,
                coreFetch: {
                    throw AppError.apiServerError(statusCode: 503)
                }
            ),
            on: harness,
            context: context
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        let failure = harness.store.snapshot(
            for: identity.profileID
        )?.currentFailure
        XCTAssertEqual(failure?.kind, .serverError)
        XCTAssertNil(failure?.retryAfter)
        XCTAssertEqual(failure?.legacyErrorCode, .apiServerError)
    }

    // MARK: - Cadence: consecutive-failure backoff

    func testBackoffSkipsScheduledRetryUntilExponentialWindowElapses()
        async
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let clock = MutableClock(TestValues.now)
        let harness = makeHarness(
            identities: [identity],
            context: context,
            now: { clock.now() }
        )

        func timerJob() -> CapturedProviderRefreshJob {
            Self.makeJob(
                identity: identity,
                refreshInterval: 10,
                trigger: .timer,
                coreFetch: {
                    throw UsageProviderError.transportFailure
                }
            )
        }

        // First scheduled attempt fails. refreshInterval is 10s, so the
        // first backoff window is 2^1 * 10 = 20s.
        _ = await harness.engine.enqueue(
            [timerJob()],
            trigger: .timer,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 1
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[0]
                    .outcomes[identity.profileID]
            ),
            .failed
        )

        // A second scheduled attempt inside the 20s window is withheld
        // rather than launched and immediately re-failed.
        _ = await harness.engine.enqueue(
            [timerJob()],
            trigger: .timer,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 2
        )
        await assertEventually {
            harness.batches.snapshot.count == 2
        }
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[1]
                    .outcomes[identity.profileID]
            ),
            .backoffSkipped
        )

        // Once the window elapses, a scheduled attempt runs again.
        clock.advance(by: 21)
        _ = await harness.engine.enqueue(
            [timerJob()],
            trigger: .timer,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 3
        )
        await assertEventually {
            harness.batches.snapshot.count == 3
        }
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[2]
                    .outcomes[identity.profileID]
            ),
            .failed
        )
    }

    func testManualRefreshBypassesBackoffWindow() async throws {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let clock = MutableClock(TestValues.now)
        let harness = makeHarness(
            identities: [identity],
            context: context,
            now: { clock.now() }
        )

        _ = await harness.engine.enqueue(
            [
                Self.makeJob(
                    identity: identity,
                    refreshInterval: 10,
                    trigger: .timer,
                    coreFetch: {
                        throw UsageProviderError.transportFailure
                    }
                )
            ],
            trigger: .timer,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 1
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        // Immediately after, well inside the backoff window, a manual
        // refresh (the Refresh button) still runs rather than being
        // withheld.
        let fetches = Locked(0)
        _ = await harness.engine.enqueue(
            [
                Self.makeJob(
                    identity: identity,
                    refreshInterval: 10,
                    trigger: .manual,
                    coreFetch: {
                        fetches.withValue { $0 += 1 }
                        return ProviderFetchResult(
                            report: try Self.makeReport(
                                providerID: .codex,
                                marker: 2
                            )
                        )
                    }
                )
            ],
            trigger: .manual,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 2
        )
        await assertEventually {
            harness.batches.snapshot.count == 2
        }

        XCTAssertEqual(fetches.snapshot(), 1)
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[1]
                    .outcomes[identity.profileID]
            ),
            .accepted
        )
    }

    func testRetryAfterHintExtendsBackoffBeyondExponentialWindow()
        async
    {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let clock = MutableClock(TestValues.now)
        let harness = makeHarness(
            identities: [identity],
            context: context,
            now: { clock.now() }
        )

        func timerJob() -> CapturedProviderRefreshJob {
            Self.makeJob(
                identity: identity,
                refreshInterval: 5,
                trigger: .timer,
                coreFetch: {
                    throw AppError.apiRateLimited(retryAfter: 120)
                }
            )
        }

        // refreshInterval is 5s, so the exponential window alone would be
        // 2^1 * 5 = 10s, but the server's Retry-After (120s) must win.
        _ = await harness.engine.enqueue(
            [timerJob()],
            trigger: .timer,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 1
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        // Past the exponential window but still well inside Retry-After.
        clock.advance(by: 15)
        _ = await harness.engine.enqueue(
            [timerJob()],
            trigger: .timer,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 2
        )
        await assertEventually {
            harness.batches.snapshot.count == 2
        }
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[1]
                    .outcomes[identity.profileID]
            ),
            .backoffSkipped
        )

        // Past Retry-After (125s total elapsed): runs again.
        clock.advance(by: 110)
        _ = await harness.engine.enqueue(
            [timerJob()],
            trigger: .timer,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 3
        )
        await assertEventually {
            harness.batches.snapshot.count == 3
        }
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[2]
                    .outcomes[identity.profileID]
            ),
            .failed
        )
    }

    func testSuccessResetsBackoffWindow() async {
        let identity = makeIdentity()
        let context = makeContext(visible: [identity.profileID])
        let clock = MutableClock(TestValues.now)
        let harness = makeHarness(
            identities: [identity],
            context: context,
            now: { clock.now() }
        )

        _ = await harness.engine.enqueue(
            [
                Self.makeJob(
                    identity: identity,
                    refreshInterval: 10,
                    trigger: .timer,
                    coreFetch: {
                        throw UsageProviderError.transportFailure
                    }
                )
            ],
            trigger: .timer,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 1
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }

        // A manual refresh bypasses the window and succeeds, which must
        // clear it for the next scheduled attempt.
        _ = await harness.engine.enqueue(
            [
                Self.makeJob(
                    identity: identity,
                    refreshInterval: 10,
                    trigger: .manual,
                    coreFetch: {
                        ProviderFetchResult(
                            report: try Self.makeReport(
                                providerID: .codex,
                                marker: 2
                            )
                        )
                    }
                )
            ],
            trigger: .manual,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 2
        )
        await assertEventually {
            harness.batches.snapshot.count == 2
        }

        // The very next scheduled attempt (no clock advance) now runs
        // instead of being withheld, because success cleared the backoff.
        let fetches = Locked(0)
        _ = await harness.engine.enqueue(
            [
                Self.makeJob(
                    identity: identity,
                    refreshInterval: 10,
                    trigger: .timer,
                    coreFetch: {
                        fetches.withValue { $0 += 1 }
                        return ProviderFetchResult(
                            report: try Self.makeReport(
                                providerID: .codex,
                                marker: 3
                            )
                        )
                    }
                )
            ],
            trigger: .timer,
            presentationContext: context,
            inputGenerations: [identity.profileID: 0],
            invocationOrder: 3
        )
        await assertEventually {
            harness.batches.snapshot.count == 3
        }
        XCTAssertEqual(fetches.snapshot(), 1)
        XCTAssertEqual(
            outcome(
                harness.batches.snapshot[2]
                    .outcomes[identity.profileID]
            ),
            .accepted
        )
    }

    // MARK: - Cadence: multi-profile fan-out stagger

    func testIndexedStaggerPolicyDelaysNonFocusedProfilesByIndexedStep() {
        let policy = IndexedRefreshStaggerPolicy(step: 0.4)

        XCTAssertEqual(
            policy.delay(
                forProfileAt: 0,
                of: 3,
                trigger: .timer,
                isFocusedProfile: false
            ),
            0
        )
        XCTAssertEqual(
            policy.delay(
                forProfileAt: 1,
                of: 3,
                trigger: .timer,
                isFocusedProfile: false
            ),
            0.4,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            policy.delay(
                forProfileAt: 2,
                of: 3,
                trigger: .timer,
                isFocusedProfile: false
            ),
            0.8,
            accuracy: 0.0001
        )

        // A single-profile batch never staggers.
        XCTAssertEqual(
            policy.delay(
                forProfileAt: 0,
                of: 1,
                trigger: .timer,
                isFocusedProfile: false
            ),
            0
        )
    }

    func testIndexedStaggerPolicySkipsDelayOnlyForManualFocusedProfile() {
        let policy = IndexedRefreshStaggerPolicy(step: 0.4)

        // Manual + the profile on screen: always immediate.
        XCTAssertEqual(
            policy.delay(
                forProfileAt: 2,
                of: 3,
                trigger: .manual,
                isFocusedProfile: true
            ),
            0
        )

        // Manual, but a different profile in the same "refresh all" batch:
        // still staggers, since a manual multi-profile refresh can recreate
        // the same thundering herd a timer tick does.
        XCTAssertEqual(
            policy.delay(
                forProfileAt: 2,
                of: 3,
                trigger: .manual,
                isFocusedProfile: false
            ),
            0.8,
            accuracy: 0.0001
        )

        // Scheduled (non-manual) refresh of the focused profile still
        // staggers — only a user-initiated trigger bypasses it.
        XCTAssertEqual(
            policy.delay(
                forProfileAt: 2,
                of: 3,
                trigger: .timer,
                isFocusedProfile: true
            ),
            0.8,
            accuracy: 0.0001
        )
    }

    func testStaggerPolicyDelaysSecondScheduledProfileAgainstTheFirst()
        async
    {
        let first = makeIdentity()
        let second = makeIdentity()
        let context = makeContext(
            visible: [first.profileID, second.profileID]
        )
        let harness = makeHarness(
            identities: [first, second],
            context: context,
            staggerPolicy: IndexedRefreshStaggerPolicy(step: 0.05)
        )
        let startTimes = Locked<[UUID: Date]>([:])

        _ = await harness.engine.enqueue(
            [
                Self.makeJob(
                    identity: first,
                    trigger: .timer,
                    coreFetch: {
                        startTimes.withValue {
                            $0[first.profileID] = Date()
                        }
                        return ProviderFetchResult(
                            report: try Self.makeReport(
                                providerID: .codex,
                                marker: 1
                            )
                        )
                    }
                ),
                Self.makeJob(
                    identity: second,
                    trigger: .timer,
                    coreFetch: {
                        startTimes.withValue {
                            $0[second.profileID] = Date()
                        }
                        return ProviderFetchResult(
                            report: try Self.makeReport(
                                providerID: .codex,
                                marker: 2
                            )
                        )
                    }
                )
            ],
            trigger: .timer,
            presentationContext: context,
            inputGenerations: [
                first.profileID: 0,
                second.profileID: 0
            ],
            invocationOrder: 1
        )
        // The stagger delay is a real `Task.sleep`, which the fast
        // `Task.yield()`-based `eventually` polling loop used elsewhere in
        // this file can outrun without ever letting real time elapse.
        // Sleep past the whole batch's expected stagger window instead.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(harness.batches.snapshot.count, 1)

        let times = startTimes.snapshot()
        guard let firstStart = times[first.profileID],
              let secondStart = times[second.profileID] else {
            XCTFail("Expected both profiles to fetch")
            return
        }
        // Index 0 (also the focused profile, per makeContext) starts
        // essentially immediately; index 1 is held back by ~one stagger
        // step. A generous tolerance keeps this from flaking under load.
        XCTAssertGreaterThan(
            secondStart.timeIntervalSince(firstStart),
            0.03
        )
    }

    func testManualRefreshStaysImmediateForFocusedProfileEvenAtLaterIndex()
        async
    {
        let notFocused = makeIdentity()
        let focused = makeIdentity()
        let context = UsagePresentationContext(
            epoch: 1,
            focusedProfileID: focused.profileID,
            visibleProfileIDs: [
                notFocused.profileID, focused.profileID
            ],
            mode: .multi
        )
        let harness = makeHarness(
            identities: [notFocused, focused],
            context: context,
            staggerPolicy: IndexedRefreshStaggerPolicy(step: 0.3)
        )
        let notFocusedGate = ManualGate<ProviderFetchResult>()
        let focusedGate = ManualGate<ProviderFetchResult>()

        _ = await harness.engine.enqueue(
            [
                makeGatedJob(
                    identity: notFocused,
                    gate: notFocusedGate,
                    trigger: .manual
                ),
                makeGatedJob(
                    identity: focused,
                    gate: focusedGate,
                    trigger: .manual
                )
            ],
            trigger: .manual,
            presentationContext: context,
            inputGenerations: [
                notFocused.profileID: 0,
                focused.profileID: 0
            ],
            invocationOrder: 1
        )

        // `focused` is index 1 in this batch, yet a manual trigger never
        // delays the profile currently on screen.
        let focusedStarted = await waitForStarts(
            focusedGate,
            count: 1
        )
        XCTAssertTrue(focusedStarted)

        notFocusedGate.resolve(
            ProviderFetchResult(
                report: try! Self.makeReport(
                    providerID: .codex,
                    marker: 1
                )
            )
        )
        focusedGate.resolve(
            ProviderFetchResult(
                report: try! Self.makeReport(
                    providerID: .codex,
                    marker: 2
                )
            )
        )
        await assertEventually {
            harness.batches.snapshot.count == 1
        }
    }

    // MARK: - Helpers

    private func makeHarness(
        identities: [ProviderRefreshIdentity] = [],
        context: UsagePresentationContext,
        cached: [UUID: ProfileCurrentUsage] = [:],
        statusFetch: @escaping UsageRefreshEngine.StatusFetch = {
            .operational
        },
        memberEnqueueObserver:
            UsageRefreshEngine.MemberEnqueueObserver? = nil,
        now: @escaping @Sendable () -> Date = { TestValues.now },
        staggerPolicy: any RefreshStaggerPolicy =
            IndexedRefreshStaggerPolicy(),
        maximumBackoffWindow: TimeInterval = 30 * 60
    ) -> Harness {
        let ledger = retain(UsageRefreshInputLedger())
        let committer = retain(FakeCommitter(ledger: ledger))
        for identity in identities {
            committer.register(
                identity,
                usage: cached[identity.profileID]
            )
        }
        let store = retain(UsagePresentationStore())
        store.activate(context)
        let batches = BatchRecorder()
        let engine = retain(UsageRefreshEngine(
            committer: committer,
            presentationStore: store,
            statusFetch: statusFetch,
            now: now,
            batchObserver: { result in
                batches.append(result)
            },
            memberEnqueueObserver: memberEnqueueObserver,
            staggerPolicy: staggerPolicy,
            maximumBackoffWindow: maximumBackoffWindow
        ))
        return Harness(
            ledger: ledger,
            committer: committer,
            store: store,
            batches: batches,
            engine: engine
        )
    }

    private func makeRuntime(
        ledger: UsageRefreshInputLedger,
        committer: FakeCommitter,
        batches: BatchRecorder,
        registry customRegistry: UsageProviderRegistry? = nil,
        featureAvailability: UsageProviderFeatureAvailability =
            .production,
        statusFetch: @escaping UsageRefreshEngine.StatusFetch = {
            .operational
        },
        // Runtime-level tests assert on fast `Task.yield()` polling and
        // predate the fan-out stagger policy; disable it by default so
        // they keep exercising true multi-profile concurrency. Tests that
        // specifically cover staggering pass a real policy explicitly.
        staggerPolicy: any RefreshStaggerPolicy =
            IndexedRefreshStaggerPolicy(step: 0)
    ) -> UsageRefreshRuntime {
        let registry = customRegistry ?? UsageProviderRegistry(
            featureAvailability: featureAvailability,
            claudeRequestCapture: { _ in
                throw TestFailure.core
            },
            codexExecutableResolver: {
                throw TestFailure.core
            },
            codexFetchFactory: { _ in
                throw TestFailure.core
            },
            now: { TestValues.now }
        )
        return retain(UsageRefreshRuntime(
            registry: registry,
            presentationStore: UsagePresentationStore(),
            eventHub: UsageRefreshEventHub(),
            inputLedger: ledger,
            committer: committer,
            statusFetch: statusFetch,
            now: { TestValues.now },
            batchObserver: { result in
                batches.append(result)
            },
            staggerPolicy: staggerPolicy
        ))
    }

    private func enqueue(
        _ job: CapturedProviderRefreshJob,
        on harness: Harness,
        context: UsagePresentationContext
    ) async -> UUID {
        await harness.engine.enqueue(
            [job],
            trigger: job.requestContext.trigger,
            presentationContext: context,
            inputGenerations: [
                job.identity.profileID:
                    harness.ledger.generation(
                        for: job.identity.profileID
                    )
            ]
        )
    }

    private func makeJob(
        identity: ProviderRefreshIdentity,
        refreshInterval: TimeInterval = 30,
        trigger: UsageRefreshTrigger = .manual,
        epoch: UInt64 = 1,
        coreFetch: @escaping ProviderCoreFetch,
        apiFetch: ProviderAPIFetch? = nil,
        _ instanceCall: Void = ()
    ) -> CapturedProviderRefreshJob {
        Self.makeJob(
            identity: identity,
            refreshInterval: refreshInterval,
            trigger: trigger,
            epoch: epoch,
            coreFetch: coreFetch,
            apiFetch: apiFetch
        )
    }

    nonisolated private static func makeJob(
        identity: ProviderRefreshIdentity,
        refreshInterval: TimeInterval = 30,
        trigger: UsageRefreshTrigger = .manual,
        epoch: UInt64 = 1,
        coreFetch: @escaping ProviderCoreFetch,
        apiFetch: ProviderAPIFetch? = nil
    ) -> CapturedProviderRefreshJob {
        CapturedProviderRefreshJob(
            identity: identity,
            profileName: "Profile",
            notificationSettings: NotificationSettings(),
            refreshInterval: refreshInterval,
            requestContext: UsageRefreshRequestContext(
                trigger: trigger,
                requestedAt: TestValues.requestDate,
                presentationEpoch: epoch
            ),
            capabilities: ProviderCapabilities([
                .usageLimits: .available
            ]),
            coreFetch: coreFetch,
            apiFetch: apiFetch
        )
    }

    private func makeImmediateJob(
        identity: ProviderRefreshIdentity,
        refreshInterval: TimeInterval = 30,
        result: ProviderFetchResult
    ) -> CapturedProviderRefreshJob {
        Self.makeJob(
            identity: identity,
            refreshInterval: refreshInterval,
            coreFetch: { result }
        )
    }

    private func makeGatedJob(
        identity: ProviderRefreshIdentity,
        gate: ManualGate<ProviderFetchResult>,
        trigger: UsageRefreshTrigger = .manual
    ) -> CapturedProviderRefreshJob {
        Self.makeJob(
            identity: identity,
            trigger: trigger,
            coreFetch: {
                await gate.wait()
            }
        )
    }

    private func makeFailingJob(
        identity: ProviderRefreshIdentity
    ) -> CapturedProviderRefreshJob {
        Self.makeJob(
            identity: identity,
            coreFetch: { throw UsageProviderError.transportFailure }
        )
    }

    private func makeIdentity(
        providerID: ProviderID = .codex,
        revision: UInt64 = 0,
        _ instanceCall: Void = ()
    ) -> ProviderRefreshIdentity {
        Self.makeIdentity(
            providerID: providerID,
            revision: revision
        )
    }

    nonisolated private static func makeIdentity(
        providerID: ProviderID = .codex,
        revision: UInt64 = 0
    ) -> ProviderRefreshIdentity {
        ProviderRefreshIdentity(
            profileID: UUID(),
            providerID: providerID,
            providerRevision: revision
        )
    }

    private func makeContext(
        epoch: UInt64 = 1,
        visible: Set<UUID> = [],
        _ instanceCall: Void = ()
    ) -> UsagePresentationContext {
        Self.makeContext(epoch: epoch, visible: visible)
    }

    nonisolated private static func makeContext(
        epoch: UInt64 = 1,
        visible: Set<UUID> = []
    ) -> UsagePresentationContext {
        UsagePresentationContext(
            epoch: epoch,
            focusedProfileID: visible.first,
            visibleProfileIDs: visible
        )
    }

    private func makeReport(
        providerID: ProviderID,
        marker: Int = 1,
        _ instanceCall: Void = ()
    ) throws -> UsageReport {
        try Self.makeReport(
            providerID: providerID,
            marker: marker
        )
    }

    nonisolated private static func makeReport(
        providerID: ProviderID,
        marker: Int = 1
    ) throws -> UsageReport {
        try UsageReport(
            providerID: providerID,
            health: ProviderHealth(
                status: .healthy,
                checkedAt: TestValues.now
            ),
            limitGroups: [],
            usageSummary: try UsageSummary(
                metrics: [
                    try UsageMetric(
                        id: UsageMetricID("test-marker"),
                        value: Double(marker),
                        unit: .tokens
                    )
                ]
            ),
            fetchedAt: TestValues.now
        )
    }

    private func makeAPIUsage(
        spend: Int,
        _ instanceCall: Void = ()
    ) -> APIUsage {
        Self.makeAPIUsage(spend: spend)
    }

    nonisolated private static func makeAPIUsage(
        spend: Int
    ) -> APIUsage {
        APIUsage(
            currentSpendCents: spend,
            resetsAt: TestValues.now.addingTimeInterval(86_400),
            prepaidCreditsCents: 100,
            currency: "USD",
            apiTokenCostCents: nil,
            apiCostByModel: nil,
            costBySource: nil,
            dailyCostCents: nil
        )
    }

    private func makeClaudeUsage(
        marker: Int,
        _ instanceCall: Void = ()
    ) -> ClaudeUsage {
        Self.makeClaudeUsage(marker: marker)
    }

    private static func makeClaudeUsage(
        marker: Int
    ) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: marker,
            sessionLimit: 100,
            sessionPercentage: Double(marker),
            sessionResetTime:
                TestValues.now.addingTimeInterval(10_000),
            weeklyTokensUsed: marker,
            weeklyLimit: 100,
            weeklyPercentage: Double(marker),
            weeklyResetTime:
                TestValues.now.addingTimeInterval(20_000),
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            fableWeeklyTokensUsed: 0,
            fableWeeklyPercentage: 0,
            fableWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            lastUpdated: TestValues.now,
            userTimezone: TimeZone(secondsFromGMT: 0)!
        )
    }

    private func makeSnapshot(
        identity: ProviderRefreshIdentity,
        epoch: UInt64,
        report: UsageReport?,
        activity: UsageRefreshActivity = .idle,
        _ instanceCall: Void = ()
    ) -> PresentationSnapshot {
        Self.makeSnapshot(
            identity: identity,
            epoch: epoch,
            report: report,
            activity: activity
        )
    }

    nonisolated private static func makeSnapshot(
        identity: ProviderRefreshIdentity,
        epoch: UInt64,
        report: UsageReport?,
        activity: UsageRefreshActivity = .idle
    ) -> PresentationSnapshot {
        PresentationSnapshot(
            profileID: identity.profileID,
            profileName: "Profile",
            providerID: identity.providerID,
            providerRevision: identity.providerRevision,
            presentationEpoch: epoch,
            capabilities: ProviderCapabilities(),
            configurationState: .ready,
            report: report,
            claudeUsage: nil,
            claudeAPIUsage: nil,
            activity: activity,
            lastSuccessfulAt: report?.fetchedAt,
            currentFailure: nil
        )
    }

    private func waitForStarts<Value>(
        _ gate: ManualGate<Value>,
        count: Int
    ) async -> Bool {
        await eventually { gate.startCount >= count }
    }

    private func waitForStarts<Value>(
        _ gate: CancellationGate<Value>,
        count: Int
    ) async -> Bool {
        await eventually { gate.startCount >= count }
    }

    private func eventually(
        attempts: Int = 2_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }

    private func assertEventually(
        attempts: Int = 2_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let satisfied = await eventually(
            attempts: attempts,
            condition
        )
        XCTAssertTrue(satisfied, file: file, line: line)
    }

    private func outcome(
        _ value: UsageRefreshBatchResult.Outcome?
    ) -> OutcomeTag? {
        switch value {
        case .accepted:
            return .accepted
        case .failed:
            return .failed
        case .superseded:
            return .superseded
        case .unavailable:
            return .unavailable
        case .backoffSkipped:
            return .backoffSkipped
        case nil:
            return nil
        }
    }
}
