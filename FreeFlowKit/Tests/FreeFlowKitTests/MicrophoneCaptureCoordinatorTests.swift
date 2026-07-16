import Foundation
import Testing

@testable import FreeFlowKit

@Suite("Microphone capture coordinator")
struct MicrophoneCaptureCoordinatorTests {
    @Test("Preview leases share one quiet meter capture and independent newest-value streams")
    func previewLeasesShareOneCaptureAndIndependentStreams() async throws {
        let backend = CoordinatorCaptureBackend()
        let coordinator = MicrophoneCaptureCoordinator(backend: backend)

        let first = try await coordinator.acquirePreview()
        let previewOwner = try #require(await coordinator.activeOwner)
        let second = try await coordinator.acquirePreview()

        let initial = await backend.snapshot()
        #expect(initial.starts.count == 1)
        #expect(initial.starts.first?.owner == previewOwner)
        #expect(await coordinator.activeOwner == previewOwner)
        #expect(initial.starts.first?.configuration == .previewMetering)
        #expect(initial.starts.first?.configuration.retainsPCM == false)
        #expect(initial.starts.first?.configuration.playsSoundFeedback == false)

        await backend.emit(0.1, owner: previewOwner)
        await backend.emit(0.2, owner: previewOwner)
        await backend.emit(0.3, owner: previewOwner)
        await waitUntil { await coordinator.latestAudioLevel == 0.3 }

        var firstIterator = first.audioLevels.makeAsyncIterator()
        var secondIterator = second.audioLevels.makeAsyncIterator()
        #expect(await firstIterator.next() == 0.3)
        #expect(await secondIterator.next() == 0.3)

        #expect(try await second.release())
        #expect(await coordinator.activeOwner == previewOwner)
        #expect(await backend.snapshot().stops.isEmpty)

        #expect(try await first.release())
        #expect(await coordinator.activeOwner == nil)
        #expect(await backend.snapshot().stops == [previewOwner])
    }

    @Test("A stale lease release cannot stop its replacement")
    func staleReleaseCannotStopReplacement() async throws {
        let backend = CoordinatorCaptureBackend()
        let coordinator = MicrophoneCaptureCoordinator(backend: backend)
        let stale = try await coordinator.acquirePreview()
        let staleOwner = try #require(await coordinator.activeOwner)

        #expect(try await stale.release())
        let replacement = try await coordinator.acquirePreview()
        let replacementOwner = try #require(await coordinator.activeOwner)
        let beforeStaleRelease = await backend.snapshot()

        #expect(staleOwner != replacementOwner)
        #expect(try await stale.release() == false)
        #expect(await coordinator.activeOwner == replacementOwner)
        #expect(await backend.snapshot() == beforeStaleRelease)

        #expect(try await replacement.release())
    }

    @Test("A physical preview restart rotates its owner and fences old-owner operations")
    func physicalRestartRotatesOwnerAndFencesOldOperations() async throws {
        let backend = CoordinatorCaptureBackend()
        let coordinator = MicrophoneCaptureCoordinator(
            backend: backend,
            withDeviceSelectionTransaction: { operation in
                guard !CoordinatorTransactionContext.isActive else {
                    throw CoordinatorDeviceBarrierError.nestedTransaction
                }
                try await CoordinatorTransactionContext.$isActive.withValue(
                    true
                ) {
                    try await operation()
                }
            },
            selectDevice: { id in
                try await backend.selectDevice(id: id)
            })
        let preview = try await coordinator.acquirePreview()
        var levels = preview.audioLevels.makeAsyncIterator()
        let oldOwner = try #require(await coordinator.activeOwner)

        try await coordinator.selectDevice(id: 9)

        let newOwner = try #require(await coordinator.activeOwner)
        #expect(newOwner != oldOwner)
        #expect(await backend.snapshot().activeOwners == [newOwner])
        #expect(await backend.snapshot().transactionMembership == [
            false, true, true, true,
        ])

        await backend.emit(0.8, owner: newOwner)
        await waitUntil { await coordinator.latestAudioLevel == 0.8 }
        #expect(await levels.next() == 0.8)

        do {
            _ = try await backend.stopCapture(owner: oldOwner)
            Issue.record("An old-owner stop terminated replacement capture")
        } catch let error as CoordinatorBackendError {
            #expect(error == .ownerMismatch)
        }
        #expect(await backend.forceReset(owner: oldOwner) == false)
        #expect(await backend.snapshot().activeOwners == [newOwner])

        #expect(try await preview.release())
        #expect(await backend.snapshot().stops == [oldOwner, newOwner])
    }

    @Test("Shutdown stops the exact preview owner and permanently seals admission")
    func shutdownSealsAdmission() async throws {
        let backend = CoordinatorCaptureBackend()
        let coordinator = MicrophoneCaptureCoordinator(backend: backend)
        _ = try await coordinator.acquirePreview()
        let owner = try #require(await coordinator.activeOwner)

        await coordinator.shutdown()
        await coordinator.shutdown()

        #expect(await coordinator.activeOwner == nil)
        #expect(await backend.snapshot().stops == [owner])
        do {
            _ = try await coordinator.acquirePreview()
            Issue.record("Shutdown coordinator admitted replacement preview")
        } catch let error as MicrophoneCaptureCoordinatorError {
            #expect(error == .coordinatorShutdown)
        }
        #expect(await backend.snapshot().starts.count == 1)
    }

    @Test("Provider dictation promotion does not drop coordinator preview demand")
    func providerDictationPromotionRetainsPreviewDemand() async throws {
        let backend = CoordinatorCaptureBackend()
        let coordinator = MicrophoneCaptureCoordinator(backend: backend)
        let preview = try await coordinator.acquirePreview()
        let previewOwner = try #require(await coordinator.activeOwner)
        var previewLevels = preview.audioLevels.makeAsyncIterator()
        let dictationOwner = AudioCaptureOwner.dictation(DictationSessionID())

        try await backend.startCapture(
            owner: dictationOwner,
            configuration: .dictation)

        var promoted = await backend.snapshot()
        #expect(promoted.starts.map(\.configuration) == [
            .previewMetering, .dictation,
        ])
        #expect(promoted.stops.isEmpty)
        #expect(promoted.activeOwners == [previewOwner, dictationOwner])

        await backend.emit(0.4, owner: previewOwner)
        await waitUntil { await coordinator.latestAudioLevel == 0.4 }
        #expect(await previewLevels.next() == 0.4)

        _ = try await backend.stopCapture(owner: dictationOwner)
        #expect(await coordinator.activeOwner == previewOwner)

        await backend.emit(0.7, owner: previewOwner)
        await waitUntil { await coordinator.latestAudioLevel == 0.7 }
        #expect(await previewLevels.next() == 0.7)

        promoted = await backend.snapshot()
        #expect(promoted.starts.map(\.owner) == [
            previewOwner, dictationOwner,
        ])
        #expect(promoted.stops == [dictationOwner])
        #expect(promoted.activeOwners == [previewOwner])

        #expect(try await preview.release())
    }

    @Test("Cancelling acquisition drains start before exact cleanup")
    func cancelledAcquisitionSerializesCleanup() async throws {
        let backend = CoordinatorCaptureBackend()
        let startGate = CoordinatorGate()
        await backend.blockNextStart(on: startGate)
        let coordinator = MicrophoneCaptureCoordinator(backend: backend)

        let acquisition = Task {
            try await coordinator.acquirePreview()
        }
        await startGate.waitUntilEntered()
        acquisition.cancel()
        await startGate.open()

        do {
            _ = try await acquisition.value
            Issue.record("Cancelled acquisition unexpectedly returned a lease")
        } catch is CancellationError {
            // Expected after the serialized start is drained and released.
        }

        let snapshot = await backend.snapshot()
        #expect(snapshot.starts.count == 1)
        #expect(snapshot.stops == snapshot.starts.map(\.owner))
        #expect(snapshot.maximumConcurrentOperations == 1)
        #expect(snapshot.activeOwners.isEmpty)
        #expect(await coordinator.activeOwner == nil)
    }

    @Test("Device selection is latest-wins and serialized with capture restart")
    func deviceSelectionIsLatestWinsAndSerialized() async throws {
        let backend = CoordinatorCaptureBackend()
        let firstSelectionGate = CoordinatorGate()
        await backend.blockDeviceSelection(1, on: firstSelectionGate)
        let coordinator = MicrophoneCaptureCoordinator(
            backend: backend,
            selectDevice: { id in
                try await backend.selectDevice(id: id)
            })
        let preview = try await coordinator.acquirePreview()
        let initialOwner = try #require(await coordinator.activeOwner)

        let firstSelection = Task {
            try await coordinator.selectDevice(id: 1)
        }
        await firstSelectionGate.waitUntilEntered()

        let latestSelection = Task {
            try await coordinator.selectDevice(id: 2)
        }
        await waitUntil { await coordinator.requestedDeviceID == 2 }
        await firstSelectionGate.open()

        do {
            try await firstSelection.value
            Issue.record("Superseded device selection unexpectedly succeeded")
        } catch let error as MicrophoneCaptureCoordinatorError {
            #expect(error == .deviceSelectionSuperseded)
        }
        try await latestSelection.value

        let restartedOwner = try #require(await coordinator.activeOwner)
        let snapshot = await backend.snapshot()
        #expect(restartedOwner != initialOwner)
        #expect(snapshot.deviceSelections == [1, 2])
        #expect(snapshot.maximumConcurrentOperations == 1)
        #expect(snapshot.activeOwners == [restartedOwner])
        #expect(snapshot.starts.map(\.owner) == [initialOwner, restartedOwner])
        #expect(snapshot.stops == [initialOwner])

        #expect(try await preview.release())
    }

    @Test("A superseded gated restart never publishes its stale owner")
    func supersededGatedRestartNeverPublishesStaleOwner() async throws {
        let backend = CoordinatorCaptureBackend()
        let staleStartGate = CoordinatorGate()
        let latestTransaction = CoordinatorDeviceTransactionBarrier(
            blockingCall: 2)
        let coordinator = MicrophoneCaptureCoordinator(
            backend: backend,
            withDeviceSelectionTransaction: { operation in
                guard !CoordinatorTransactionContext.isActive else {
                    throw CoordinatorDeviceBarrierError.nestedTransaction
                }
                try await CoordinatorTransactionContext.$isActive.withValue(
                    true
                ) {
                    try await latestTransaction.run(operation)
                }
            },
            selectDevice: { id in
                try await backend.selectDevice(id: id)
            })
        let preview = try await coordinator.acquirePreview()
        let initialOwner = try #require(await coordinator.activeOwner)
        let availability = CoordinatorAvailabilityRecorder()
        let availabilityTask = Task {
            for await isAvailable in preview.captureAvailability {
                await availability.append(isAvailable)
            }
        }
        await waitUntil { await availability.values == [true] }
        await backend.blockNextStart(on: staleStartGate)

        let staleSelection = Task {
            try await coordinator.selectDevice(id: 51)
        }
        await staleStartGate.waitUntilEntered()
        let latestSelection = Task {
            try await coordinator.selectDevice(id: 52)
        }
        await waitUntil { await coordinator.requestedDeviceID == 52 }

        await staleStartGate.open()
        await latestTransaction.waitUntilBlockedCallEntered()
        await waitUntil { await availability.values.last == false }

        let staleStart = try #require(
            await backend.snapshot().starts.last?.owner)
        #expect(staleStart != initialOwner)
        #expect(await coordinator.activeOwner == nil)
        #expect(await backend.snapshot().activeOwners.isEmpty)
        #expect(await backend.snapshot().forceResets == [staleStart])
        #expect(await availability.values == [true, false])

        await latestTransaction.openBlockedCall()
        do {
            try await staleSelection.value
            Issue.record("Superseded device selection unexpectedly succeeded")
        } catch let error as MicrophoneCaptureCoordinatorError {
            #expect(error == .deviceSelectionSuperseded)
        }
        try await latestSelection.value

        let latestOwner = try #require(await coordinator.activeOwner)
        let snapshot = await backend.snapshot()
        #expect(latestOwner != staleStart)
        #expect(await coordinator.selectedDeviceID == 52)
        #expect(snapshot.deviceSelections == [51, 52])
        #expect(snapshot.starts.map(\.owner) == [
            initialOwner, staleStart, latestOwner,
        ])
        #expect(snapshot.activeOwners == [latestOwner])
        #expect(snapshot.forceResets == [staleStart])
        #expect(snapshot.maximumConcurrentOperations == 1)
        #expect(snapshot.transactionMembership.dropFirst().allSatisfy { $0 })

        #expect(try await preview.release())
        await availabilityTask.value
    }

    @Test("A superseded level stream lookup never publishes its stale owner")
    func supersededLevelStreamLookupNeverPublishesStaleOwner() async throws {
        let backend = CoordinatorCaptureBackend()
        let staleStreamGate = CoordinatorGate()
        let latestTransaction = CoordinatorDeviceTransactionBarrier(
            blockingCall: 2)
        let coordinator = MicrophoneCaptureCoordinator(
            backend: backend,
            withDeviceSelectionTransaction: { operation in
                guard !CoordinatorTransactionContext.isActive else {
                    throw CoordinatorDeviceBarrierError.nestedTransaction
                }
                try await CoordinatorTransactionContext.$isActive.withValue(
                    true
                ) {
                    try await latestTransaction.run(operation)
                }
            },
            selectDevice: { id in
                try await backend.selectDevice(id: id)
            })
        let preview = try await coordinator.acquirePreview()
        let initialOwner = try #require(await coordinator.activeOwner)
        var availability = preview.captureAvailability.makeAsyncIterator()
        #expect(await availability.next() == true)
        await backend.blockNextLevelStream(on: staleStreamGate)

        let staleSelection = Task {
            try await coordinator.selectDevice(id: 71)
        }
        await staleStreamGate.waitUntilEntered()
        let latestSelection = Task {
            try await coordinator.selectDevice(id: 72)
        }
        await waitUntil { await coordinator.requestedDeviceID == 72 }

        await staleStreamGate.open()
        await latestTransaction.waitUntilBlockedCallEntered()

        let staleOwner = try #require(
            await backend.snapshot().starts.last?.owner)
        #expect(staleOwner != initialOwner)
        #expect(await coordinator.activeOwner == nil)
        #expect(await backend.snapshot().activeOwners.isEmpty)
        #expect(await backend.snapshot().forceResets == [staleOwner])
        #expect(await availability.next() == false)

        await latestTransaction.openBlockedCall()
        do {
            try await staleSelection.value
            Issue.record("Superseded device selection unexpectedly succeeded")
        } catch let error as MicrophoneCaptureCoordinatorError {
            #expect(error == .deviceSelectionSuperseded)
        }
        try await latestSelection.value

        let latestOwner = try #require(await coordinator.activeOwner)
        let snapshot = await backend.snapshot()
        #expect(latestOwner != staleOwner)
        #expect(await coordinator.selectedDeviceID == 72)
        #expect(snapshot.deviceSelections == [71, 72])
        #expect(snapshot.starts.map(\.owner) == [
            initialOwner, staleOwner, latestOwner,
        ])
        #expect(snapshot.activeOwners == [latestOwner])
        #expect(snapshot.maximumConcurrentOperations == 1)
        #expect(snapshot.transactionMembership.dropFirst().allSatisfy { $0 })

        #expect(try await preview.release())
    }

    @Test("Device selection waits for dictation to drain before restarting preview")
    func deviceSelectionWaitsForDictationDrain() async throws {
        let backend = CoordinatorCaptureBackend()
        let dictationDrained = CoordinatorGate()
        let coordinator = MicrophoneCaptureCoordinator(
            backend: backend,
            withDeviceSelectionTransaction: { operation in
                await dictationDrained.wait()
                try await operation()
            },
            selectDevice: { id in
                try await backend.selectDevice(id: id)
            })
        let preview = try await coordinator.acquirePreview()
        let initialOwner = try #require(await coordinator.activeOwner)
        let dictationOwner = AudioCaptureOwner.dictation(DictationSessionID())
        try await backend.startCapture(
            owner: dictationOwner,
            configuration: .dictation)

        let selection = Task {
            try await coordinator.selectDevice(id: 7)
        }
        await dictationDrained.waitUntilEntered()

        let whileDictating = await backend.snapshot()
        #expect(whileDictating.stops.isEmpty)
        #expect(whileDictating.deviceSelections.isEmpty)
        #expect(whileDictating.activeOwners == [initialOwner, dictationOwner])

        _ = try await backend.stopCapture(owner: dictationOwner)
        await dictationDrained.open()
        try await selection.value

        let restartedOwner = try #require(await coordinator.activeOwner)
        let selected = await backend.snapshot()
        #expect(restartedOwner != initialOwner)
        #expect(selected.deviceSelections == [7])
        #expect(selected.stops == [dictationOwner, initialOwner])
        #expect(selected.starts.map(\.owner) == [
            initialOwner, dictationOwner, restartedOwner,
        ])
        #expect(selected.activeOwners == [restartedOwner])
        #expect(selected.maximumConcurrentOperations == 1)

        #expect(try await preview.release())
    }

    @Test("A failed latest device barrier restores preview after supersession")
    func failedLatestDeviceBarrierRestoresPreview() async throws {
        let backend = CoordinatorCaptureBackend()
        let firstSelectionGate = CoordinatorGate()
        let barrier = CoordinatorDeviceBarrier(failingCall: 2)
        await backend.blockDeviceSelection(1, on: firstSelectionGate)
        let coordinator = MicrophoneCaptureCoordinator(
            backend: backend,
            withDeviceSelectionTransaction: { operation in
                try await barrier.wait()
                try await CoordinatorTransactionContext.$isActive.withValue(
                    true
                ) {
                    try await operation()
                }
            },
            selectDevice: { id in
                try await backend.selectDevice(id: id)
            })
        let preview = try await coordinator.acquirePreview()
        let initialOwner = try #require(await coordinator.activeOwner)

        let firstSelection = Task {
            try await coordinator.selectDevice(id: 1)
        }
        await firstSelectionGate.waitUntilEntered()
        let rejectedSelection = Task {
            try await coordinator.selectDevice(id: 2)
        }
        await waitUntil { await coordinator.requestedDeviceID == 2 }
        await firstSelectionGate.open()

        do {
            try await firstSelection.value
            Issue.record("Superseded device selection unexpectedly succeeded")
        } catch let error as MicrophoneCaptureCoordinatorError {
            #expect(error == .deviceSelectionSuperseded)
        }
        do {
            try await rejectedSelection.value
            Issue.record("Rejected device selection unexpectedly succeeded")
        } catch let error as CoordinatorDeviceBarrierError {
            #expect(error == .rejected)
        }

        let restartedOwner = try #require(await coordinator.activeOwner)
        let snapshot = await backend.snapshot()
        #expect(restartedOwner != initialOwner)
        #expect(snapshot.activeOwners == [restartedOwner])
        #expect(snapshot.starts.map(\.owner) == [initialOwner, restartedOwner])
        #expect(snapshot.stops == [initialOwner])
        #expect(snapshot.maximumConcurrentOperations == 1)
        #expect(snapshot.transactionMembership.last == true)

        #expect(try await preview.release())
    }

    @Test("A failed device selection restores preview inside the transaction")
    func failedDeviceSelectionRestoresPreviewInsideTransaction() async throws {
        let backend = CoordinatorCaptureBackend()
        await backend.failDeviceSelection(11)
        let coordinator = MicrophoneCaptureCoordinator(
            backend: backend,
            withDeviceSelectionTransaction: { operation in
                guard !CoordinatorTransactionContext.isActive else {
                    throw CoordinatorDeviceBarrierError.nestedTransaction
                }
                try await CoordinatorTransactionContext.$isActive.withValue(
                    true
                ) {
                    try await operation()
                }
            },
            selectDevice: { id in
                try await backend.selectDevice(id: id)
            })
        let preview = try await coordinator.acquirePreview()
        let initialOwner = try #require(await coordinator.activeOwner)

        do {
            try await coordinator.selectDevice(id: 11)
            Issue.record("Failed device selection unexpectedly succeeded")
        } catch let error as CoordinatorBackendError {
            #expect(error == .deviceSelectionFailed)
        }

        let restoredOwner = try #require(await coordinator.activeOwner)
        let snapshot = await backend.snapshot()
        #expect(restoredOwner != initialOwner)
        #expect(snapshot.activeOwners == [restoredOwner])
        #expect(snapshot.starts.map(\.owner) == [initialOwner, restoredOwner])
        #expect(snapshot.stops == [initialOwner])
        #expect(snapshot.transactionMembership == [false, true, true, true])

        #expect(try await preview.release())
    }

    @Test("A failed preview restart is retried inside the transaction")
    func failedPreviewRestartIsRetriedInsideTransaction() async throws {
        let backend = CoordinatorCaptureBackend()
        let coordinator = MicrophoneCaptureCoordinator(
            backend: backend,
            withDeviceSelectionTransaction: { operation in
                guard !CoordinatorTransactionContext.isActive else {
                    throw CoordinatorDeviceBarrierError.nestedTransaction
                }
                try await CoordinatorTransactionContext.$isActive.withValue(
                    true
                ) {
                    try await operation()
                }
            },
            selectDevice: { id in
                try await backend.selectDevice(id: id)
            })
        let preview = try await coordinator.acquirePreview()
        let initialOwner = try #require(await coordinator.activeOwner)
        await backend.failNextStart()

        do {
            try await coordinator.selectDevice(id: 12)
            Issue.record("Selection with a failed restart unexpectedly succeeded")
        } catch let error as CoordinatorBackendError {
            #expect(error == .startFailed)
        }

        let restoredOwner = try #require(await coordinator.activeOwner)
        let snapshot = await backend.snapshot()
        #expect(restoredOwner != initialOwner)
        #expect(snapshot.activeOwners == [restoredOwner])
        #expect(snapshot.starts.map(\.owner) == [initialOwner, restoredOwner])
        #expect(snapshot.stops == [initialOwner])
        #expect(snapshot.transactionMembership == [
            false, true, true, true, true,
        ])

        #expect(try await preview.release())
    }

    @Test("Persistent device restart failure keeps delayed recovery transactional")
    func persistentDeviceRestartFailureKeepsRecoveryTransactional() async throws {
        let backend = CoordinatorCaptureBackend()
        let retryDelay = CoordinatorGate()
        let coordinator = MicrophoneCaptureCoordinator(
            backend: backend,
            withDeviceSelectionTransaction: { operation in
                try await CoordinatorTransactionContext.$isActive.withValue(
                    true
                ) {
                    try await operation()
                }
            },
            selectDevice: { id in
                try await backend.selectDevice(id: id)
            },
            previewRecoveryDelay: { _ in
                await retryDelay.wait()
            })
        let preview = try await coordinator.acquirePreview()
        let initialOwner = try #require(await coordinator.activeOwner)
        await backend.failNextStart()
        await backend.failNextStart()
        await backend.failNextStart()

        do {
            try await coordinator.selectDevice(id: 13)
            Issue.record("Selection with persistent restart failure succeeded")
        } catch let error as CoordinatorBackendError {
            #expect(error == .startFailed)
        }
        await retryDelay.waitUntilEntered()
        #expect(await coordinator.activeOwner == nil)

        await retryDelay.open()
        await waitUntil { await coordinator.activeOwner != nil }

        let recoveredOwner = try #require(await coordinator.activeOwner)
        let snapshot = await backend.snapshot()
        #expect(recoveredOwner != initialOwner)
        #expect(snapshot.activeOwners == [recoveredOwner])
        #expect(snapshot.transactionMembership.dropFirst().allSatisfy { $0 })

        #expect(try await preview.release())
    }

    @Test("A missing provider level stream rotates capture without replacing the lease")
    func missingLevelStreamRotatesCapture() async throws {
        let backend = CoordinatorCaptureBackend()
        await backend.returnNilForNextLevelStream()
        let coordinator = MicrophoneCaptureCoordinator(backend: backend)

        let preview = try await coordinator.acquirePreview()
        await waitUntil { await backend.snapshot().starts.count == 2 }

        let replacementOwner = try #require(await coordinator.activeOwner)
        let snapshot = await backend.snapshot()
        let initialOwner = try #require(snapshot.starts.first?.owner)
        #expect(replacementOwner != initialOwner)
        #expect(snapshot.forceResets == [initialOwner])
        #expect(snapshot.activeOwners == [replacementOwner])

        var levels = preview.audioLevels.makeAsyncIterator()
        await backend.emit(0.6, owner: replacementOwner)
        #expect(await levels.next() == 0.6)
        #expect(try await preview.release())
    }

    @Test("An unexpectedly finished provider stream rotates capture and preserves the lease")
    func finishedLevelStreamRotatesCapture() async throws {
        let backend = CoordinatorCaptureBackend()
        let coordinator = MicrophoneCaptureCoordinator(backend: backend)
        let preview = try await coordinator.acquirePreview()
        let initialOwner = try #require(await coordinator.activeOwner)

        await backend.finishLevelStream(owner: initialOwner)
        await waitUntil {
            guard let activeOwner = await coordinator.activeOwner else {
                return false
            }
            return activeOwner != initialOwner
        }

        let replacementOwner = try #require(await coordinator.activeOwner)
        let snapshot = await backend.snapshot()
        #expect(snapshot.starts.map(\.owner) == [initialOwner, replacementOwner])
        #expect(snapshot.forceResets == [initialOwner])
        #expect(snapshot.activeOwners == [replacementOwner])

        var levels = preview.audioLevels.makeAsyncIterator()
        await backend.emit(0.9, owner: replacementOwner)
        #expect(await levels.next() == 0.9)
        #expect(try await preview.release())
    }

    @Test("A superseded stream recovery never publishes its stale owner")
    func supersededStreamRecoveryNeverPublishesStaleOwner() async throws {
        let backend = CoordinatorCaptureBackend()
        let recoveryDelay = CoordinatorGate()
        let staleStartGate = CoordinatorGate()
        let latestTransaction = CoordinatorDeviceTransactionBarrier(
            blockingCall: 1)
        let coordinator = MicrophoneCaptureCoordinator(
            backend: backend,
            withDeviceSelectionTransaction: { operation in
                guard !CoordinatorTransactionContext.isActive else {
                    throw CoordinatorDeviceBarrierError.nestedTransaction
                }
                try await CoordinatorTransactionContext.$isActive.withValue(
                    true
                ) {
                    try await latestTransaction.run(operation)
                }
            },
            selectDevice: { id in
                try await backend.selectDevice(id: id)
            },
            previewRecoveryDelay: { _ in
                await recoveryDelay.wait()
            })
        let preview = try await coordinator.acquirePreview()
        let initialOwner = try #require(await coordinator.activeOwner)
        let availability = CoordinatorAvailabilityRecorder()
        let availabilityTask = Task {
            for await isAvailable in preview.captureAvailability {
                await availability.append(isAvailable)
            }
        }
        await waitUntil { await availability.values == [true] }

        await backend.finishLevelStream(owner: initialOwner)
        await recoveryDelay.waitUntilEntered()
        await waitUntil { await availability.values.last == false }
        await backend.blockNextStart(on: staleStartGate)
        await recoveryDelay.open()
        await staleStartGate.waitUntilEntered()

        let latestSelection = Task {
            try await coordinator.selectDevice(id: 61)
        }
        await waitUntil { await coordinator.requestedDeviceID == 61 }
        await staleStartGate.open()
        await latestTransaction.waitUntilBlockedCallEntered()

        let starts = await backend.snapshot().starts.map(\.owner)
        let staleOwner = try #require(starts.last)
        #expect(starts == [initialOwner, staleOwner])
        #expect(staleOwner != initialOwner)
        #expect(await coordinator.activeOwner == nil)
        #expect(await backend.snapshot().activeOwners.isEmpty)
        #expect(await backend.snapshot().forceResets == [
            initialOwner, staleOwner,
        ])
        #expect(await availability.values == [true, false])

        await latestTransaction.openBlockedCall()
        try await latestSelection.value

        let latestOwner = try #require(await coordinator.activeOwner)
        let snapshot = await backend.snapshot()
        #expect(latestOwner != staleOwner)
        #expect(await coordinator.selectedDeviceID == 61)
        #expect(snapshot.deviceSelections == [61])
        #expect(snapshot.starts.map(\.owner) == [
            initialOwner, staleOwner, latestOwner,
        ])
        #expect(snapshot.activeOwners == [latestOwner])
        #expect(snapshot.maximumConcurrentOperations == 1)
        #expect(snapshot.transactionMembership.last == true)

        #expect(try await preview.release())
        await availabilityTask.value
    }

    @Test("Lease availability fences a dead owner until replacement capture starts")
    func leaseAvailabilityTracksRecovery() async throws {
        let backend = CoordinatorCaptureBackend()
        let retryDelay = CoordinatorGate()
        let coordinator = MicrophoneCaptureCoordinator(
            backend: backend,
            previewRecoveryDelay: { _ in
                await retryDelay.wait()
            })
        let preview = try await coordinator.acquirePreview()
        let initialOwner = try #require(await coordinator.activeOwner)
        var availability = preview.captureAvailability.makeAsyncIterator()

        #expect(await availability.next() == true)
        await backend.finishLevelStream(owner: initialOwner)
        #expect(await availability.next() == false)
        #expect(await coordinator.activeOwner == nil)

        await retryDelay.open()
        #expect(await availability.next() == true)
        let replacementOwner = try #require(await coordinator.activeOwner)
        #expect(replacementOwner != initialOwner)

        #expect(try await preview.release())
        #expect(await availability.next() == nil)
    }

    @Test("Failed eager acquisition recovery preserves the device transaction")
    func acquireWhileRecoveringReschedulesAfterStartFailure() async throws {
        let backend = CoordinatorCaptureBackend()
        let retryDelay = CoordinatorGate()
        let coordinator = MicrophoneCaptureCoordinator(
            backend: backend,
            withDeviceSelectionTransaction: { operation in
                guard !CoordinatorTransactionContext.isActive else {
                    throw CoordinatorDeviceBarrierError.nestedTransaction
                }
                try await CoordinatorTransactionContext.$isActive.withValue(
                    true
                ) {
                    try await operation()
                }
            },
            selectDevice: { id in
                try await backend.selectDevice(id: id)
            },
            previewRecoveryDelay: { _ in
                await retryDelay.wait()
            })
        let alwaysReady = try await coordinator.acquirePreview()
        let initialOwner = try #require(await coordinator.activeOwner)
        var availability = alwaysReady.captureAvailability.makeAsyncIterator()

        #expect(await availability.next() == true)
        await backend.returnNilForNextLevelStream()
        try await coordinator.selectDevice(id: 41)
        #expect(await availability.next() == false)
        await retryDelay.waitUntilEntered()
        #expect(await coordinator.activeOwner == nil)

        await backend.failNextStart()
        do {
            _ = try await coordinator.acquirePreview()
            Issue.record("Acquisition with a failed eager restart succeeded")
        } catch let error as CoordinatorBackendError {
            #expect(error == .startFailed)
        }

        let failedRestart = await backend.snapshot()
        let unavailableOwner = try #require(
            failedRestart.starts.dropFirst().first?.owner)
        #expect(failedRestart.transactionMembership.last == true)
        #expect(await coordinator.activeOwner == nil)

        await retryDelay.open()
        await waitUntil { await coordinator.activeOwner != nil }
        let recoveredOwner = try #require(await coordinator.activeOwner)
        #expect(recoveredOwner != initialOwner)
        #expect(await availability.next() == true)

        let snapshot = await backend.snapshot()
        #expect(snapshot.starts.map(\.owner) == [
            initialOwner,
            unavailableOwner,
            recoveredOwner,
        ])
        #expect(snapshot.activeOwners == [recoveredOwner])
        #expect(snapshot.transactionMembership.dropFirst().allSatisfy { $0 })
        #expect(try await alwaysReady.release())
    }

    @Test("Failed eager recovery during lease release keeps recovery scheduled")
    func releaseWhileRecoveringReschedulesAfterStartFailure() async throws {
        let backend = CoordinatorCaptureBackend()
        let recoveryDelays = CoordinatorRecoveryDelays()
        let coordinator = MicrophoneCaptureCoordinator(
            backend: backend,
            previewRecoveryDelay: { _ in
                await recoveryDelays.wait()
            })
        let alwaysReady = try await coordinator.acquirePreview()
        let transient = try await coordinator.acquirePreview()
        let initialOwner = try #require(await coordinator.activeOwner)
        var availability = alwaysReady.captureAvailability.makeAsyncIterator()

        #expect(await availability.next() == true)
        await backend.finishLevelStream(owner: initialOwner)
        #expect(await availability.next() == false)
        await recoveryDelays.waitUntilEntered(1)
        #expect(await coordinator.activeOwner == nil)

        await backend.failNextStart()
        do {
            _ = try await transient.release()
            Issue.record("Release with a failed eager restart succeeded")
        } catch let error as CoordinatorBackendError {
            #expect(error == .startFailed)
        }

        await recoveryDelays.open(1)
        await waitUntil { await recoveryDelays.callCount == 2 }
        #expect(await coordinator.activeOwner == nil)

        await recoveryDelays.open(2)
        await waitUntil { await coordinator.activeOwner != nil }
        let recoveredOwner = try #require(await coordinator.activeOwner)
        #expect(recoveredOwner != initialOwner)
        #expect(await availability.next() == true)

        let snapshot = await backend.snapshot()
        #expect(snapshot.starts.map(\.owner) == [initialOwner, recoveredOwner])
        #expect(snapshot.activeOwners == [recoveredOwner])
        #expect(try await transient.release() == false)
        #expect(try await alwaysReady.release())
    }

    @Test("Last lease release cancels pending preview recovery")
    func lastLeaseReleaseCancelsPendingRecovery() async throws {
        let backend = CoordinatorCaptureBackend()
        let retryDelay = CoordinatorGate()
        await backend.returnNilForNextLevelStream()
        let coordinator = MicrophoneCaptureCoordinator(
            backend: backend,
            previewRecoveryDelay: { _ in
                await retryDelay.wait()
            })
        let preview = try await coordinator.acquirePreview()
        await retryDelay.waitUntilEntered()

        #expect(try await preview.release())
        await retryDelay.open()
        try? await Task.sleep(nanoseconds: 20_000_000)

        let snapshot = await backend.snapshot()
        #expect(snapshot.starts.count == 1)
        #expect(snapshot.activeOwners.isEmpty)
        #expect(await coordinator.activeOwner == nil)
    }

    @Test("Shutdown cancels pending preview recovery")
    func shutdownCancelsPendingRecovery() async throws {
        let backend = CoordinatorCaptureBackend()
        let retryDelay = CoordinatorGate()
        await backend.returnNilForNextLevelStream()
        let coordinator = MicrophoneCaptureCoordinator(
            backend: backend,
            previewRecoveryDelay: { _ in
                await retryDelay.wait()
            })
        _ = try await coordinator.acquirePreview()
        await retryDelay.waitUntilEntered()

        await coordinator.shutdown()
        await retryDelay.open()
        try? await Task.sleep(nanoseconds: 20_000_000)

        let snapshot = await backend.snapshot()
        #expect(snapshot.starts.count == 1)
        #expect(snapshot.activeOwners.isEmpty)
        #expect(await coordinator.activeOwner == nil)
    }

    @Test("Shutdown cancels an older device transaction before draining preview")
    func shutdownCancelsOlderDeviceTransaction() async throws {
        let backend = CoordinatorCaptureBackend()
        let transaction = CoordinatorCancellationObservation()
        let coordinator = MicrophoneCaptureCoordinator(
            backend: backend,
            withDeviceSelectionTransaction: { operation in
                try await transaction.enterAndSuspend()
                try await operation()
            },
            selectDevice: { id in
                try await backend.selectDevice(id: id)
            })
        let preview = try await coordinator.acquirePreview()
        let initialOwner = try #require(await coordinator.activeOwner)

        let selection = Task { () -> Bool in
            do {
                try await coordinator.selectDevice(id: 71)
                return false
            } catch is CancellationError {
                return true
            } catch {
                Issue.record("Unexpected selection error: \(error)")
                return false
            }
        }
        await waitUntil { await transaction.didEnter }

        await coordinator.shutdown()

        #expect(await selection.value)
        #expect(await coordinator.activeOwner == nil)
        let snapshot = await backend.snapshot()
        #expect(snapshot.stops == [initialOwner])
        #expect(snapshot.deviceSelections.isEmpty)
        #expect(!(try await preview.release()))
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("Condition was not reached")
    }
}

private enum CoordinatorDeviceBarrierError: Error, Equatable {
    case rejected
    case nestedTransaction
}

private enum CoordinatorBackendError: Error, Equatable {
    case ownerMismatch
    case startFailed
    case deviceSelectionFailed
}

private enum CoordinatorTransactionContext {
    @TaskLocal static var isActive = false
}

private actor CoordinatorDeviceBarrier {
    private let failingCall: Int
    private var callCount = 0

    init(failingCall: Int) {
        self.failingCall = failingCall
    }

    func wait() throws {
        callCount += 1
        if callCount == failingCall {
            throw CoordinatorDeviceBarrierError.rejected
        }
    }
}

private actor CoordinatorDeviceTransactionBarrier {
    private let blockingCall: Int
    private let gate = CoordinatorGate()
    private var callCount = 0

    init(blockingCall: Int) {
        self.blockingCall = blockingCall
    }

    func run(
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        callCount += 1
        if callCount == blockingCall {
            await gate.wait()
        }
        try await operation()
    }

    func waitUntilBlockedCallEntered() async {
        await gate.waitUntilEntered()
    }

    func openBlockedCall() async {
        await gate.open()
    }
}

private actor CoordinatorAvailabilityRecorder {
    private(set) var values: [Bool] = []

    func append(_ value: Bool) {
        values.append(value)
    }
}

private actor CoordinatorCancellationObservation {
    private(set) var didEnter = false

    func enterAndSuspend() async throws {
        didEnter = true
        try await Task.sleep(for: .seconds(3_600))
    }
}

private actor CoordinatorGate {
    private var didEnter = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        didEnter = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }

        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor CoordinatorRecoveryDelays {
    private(set) var callCount = 0
    private var enteredWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var delayWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var openCalls: Set<Int> = []

    func wait() async {
        callCount += 1
        let call = callCount
        enteredWaiters.removeValue(forKey: call)?.forEach { $0.resume() }
        guard !openCalls.contains(call) else { return }
        await withCheckedContinuation { delayWaiters[call] = $0 }
    }

    func waitUntilEntered(_ call: Int) async {
        guard callCount < call else { return }
        await withCheckedContinuation {
            enteredWaiters[call, default: []].append($0)
        }
    }

    func open(_ call: Int) {
        openCalls.insert(call)
        delayWaiters.removeValue(forKey: call)?.resume()
    }
}

private actor CoordinatorCaptureBackend: MicrophoneCaptureBackend {
    struct Start: Equatable, Sendable {
        let owner: AudioCaptureOwner
        let configuration: AudioCaptureConfiguration
    }

    struct Snapshot: Equatable, Sendable {
        let starts: [Start]
        let stops: [AudioCaptureOwner]
        let forceResets: [AudioCaptureOwner]
        let deviceSelections: [UInt32?]
        let transactionMembership: [Bool]
        let maximumConcurrentOperations: Int
        let activeOwners: Set<AudioCaptureOwner>
    }

    private struct LevelSource {
        let stream: AsyncStream<Float>
        let continuation: AsyncStream<Float>.Continuation
    }

    private var starts: [Start] = []
    private var stops: [AudioCaptureOwner] = []
    private var forceResets: [AudioCaptureOwner] = []
    private var deviceSelections: [UInt32?] = []
    private var transactionMembership: [Bool] = []
    private var activeOwners: Set<AudioCaptureOwner> = []
    private var levelSources: [AudioCaptureOwner: LevelSource] = [:]
    private var nextStartGate: CoordinatorGate?
    private var startFailuresRemaining = 0
    private var nilLevelStreamRequestsRemaining = 0
    private var nextLevelStreamGate: CoordinatorGate?
    private var failingDeviceSelections: Set<UInt32> = []
    private var deviceSelectionGates: [UInt32: CoordinatorGate] = [:]
    private var concurrentOperations = 0
    private var maximumConcurrentOperations = 0

    func blockNextStart(on gate: CoordinatorGate) {
        nextStartGate = gate
    }

    func failNextStart() {
        startFailuresRemaining += 1
    }

    func returnNilForNextLevelStream() {
        nilLevelStreamRequestsRemaining += 1
    }

    func blockNextLevelStream(on gate: CoordinatorGate) {
        nextLevelStreamGate = gate
    }

    func failDeviceSelection(_ id: UInt32) {
        failingDeviceSelections.insert(id)
    }

    func blockDeviceSelection(_ id: UInt32, on gate: CoordinatorGate) {
        deviceSelectionGates[id] = gate
    }

    func startCapture(
        owner: AudioCaptureOwner,
        configuration: AudioCaptureConfiguration
    ) async throws {
        beginOperation()
        transactionMembership.append(CoordinatorTransactionContext.isActive)
        if startFailuresRemaining > 0 {
            startFailuresRemaining -= 1
            endOperation()
            throw CoordinatorBackendError.startFailed
        }
        let gate = nextStartGate
        nextStartGate = nil
        if let gate { await gate.wait() }

        starts.append(Start(owner: owner, configuration: configuration))
        activeOwners.insert(owner)
        levelSources[owner]?.continuation.finish()
        let pair = AsyncStream<Float>.makeStream()
        levelSources[owner] = LevelSource(
            stream: pair.stream,
            continuation: pair.continuation)
        endOperation()
    }

    func stopCapture(owner: AudioCaptureOwner) async throws -> AudioBuffer {
        beginOperation()
        transactionMembership.append(CoordinatorTransactionContext.isActive)
        guard activeOwners.contains(owner) else {
            endOperation()
            throw CoordinatorBackendError.ownerMismatch
        }
        stops.append(owner)
        activeOwners.remove(owner)
        levelSources.removeValue(forKey: owner)?.continuation.finish()
        endOperation()
        return .empty
    }

    func audioLevelStream(
        owner: AudioCaptureOwner
    ) async -> AsyncStream<Float>? {
        let gate = nextLevelStreamGate
        nextLevelStreamGate = nil
        if let gate { await gate.wait() }
        if nilLevelStreamRequestsRemaining > 0 {
            nilLevelStreamRequestsRemaining -= 1
            return nil
        }
        return levelSources[owner]?.stream
    }

    func forceReset(owner: AudioCaptureOwner) async -> Bool {
        guard activeOwners.remove(owner) != nil else { return false }
        forceResets.append(owner)
        levelSources.removeValue(forKey: owner)?.continuation.finish()
        return true
    }

    func selectDevice(id: UInt32?) async throws {
        beginOperation()
        transactionMembership.append(CoordinatorTransactionContext.isActive)
        deviceSelections.append(id)
        if let id, failingDeviceSelections.remove(id) != nil {
            endOperation()
            throw CoordinatorBackendError.deviceSelectionFailed
        }
        if let id, let gate = deviceSelectionGates.removeValue(forKey: id) {
            await gate.wait()
        }
        endOperation()
    }

    func emit(_ level: Float, owner: AudioCaptureOwner) {
        levelSources[owner]?.continuation.yield(level)
    }

    func finishLevelStream(owner: AudioCaptureOwner) {
        levelSources[owner]?.continuation.finish()
    }

    func snapshot() -> Snapshot {
        Snapshot(
            starts: starts,
            stops: stops,
            forceResets: forceResets,
            deviceSelections: deviceSelections,
            transactionMembership: transactionMembership,
            maximumConcurrentOperations: maximumConcurrentOperations,
            activeOwners: activeOwners)
    }

    private func beginOperation() {
        concurrentOperations += 1
        maximumConcurrentOperations = max(
            maximumConcurrentOperations, concurrentOperations)
    }

    private func endOperation() {
        concurrentOperations -= 1
    }
}
