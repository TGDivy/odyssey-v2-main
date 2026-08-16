import Foundation
import OdysseyDomain
import OdysseyExtensionBridge
#if canImport(WatchConnectivity)
@preconcurrency import WatchConnectivity
#endif

public enum WatchConnectivityActivationState: String, Hashable, Sendable {
    case unavailable
    case inactive
    case activating
    case activated
}

public struct WatchCommandSenderStatus: Hashable, Sendable {
    public let activationState: WatchConnectivityActivationState
    public let isReachable: Bool
    public let pendingCommandCount: Int

    public init(
        activationState: WatchConnectivityActivationState,
        isReachable: Bool,
        pendingCommandCount: Int
    ) {
        self.activationState = activationState
        self.isReachable = isReachable
        self.pendingCommandCount = pendingCommandCount
    }
}

#if canImport(WatchConnectivity)
#if os(iOS)
private actor PhoneWatchCommandInbox {
    private let queue: ExtensionCommandQueue

    init(queue: ExtensionCommandQueue) {
        self.queue = queue
    }

    func accept(_ data: Data) async -> WatchCommandAcknowledgment? {
        guard let command = try? WatchCommandTransportCodec.decodeCommand(data) else {
            return nil
        }
        do {
            try await queue.enqueue(command)
            return WatchCommandAcknowledgment(
                commandID: command.commandID,
                disposition: .accepted
            )
        } catch {
            return WatchCommandAcknowledgment(
                commandID: command.commandID,
                disposition: .retry
            )
        }
    }
}

@MainActor
public final class PhoneWatchCommandReceiver: NSObject {
    public var onCommandAccepted: (@MainActor @Sendable () async -> Void)?

    private let session: WCSession
    private let inbox: PhoneWatchCommandInbox

    public init?(commandQueue: ExtensionCommandQueue) {
        guard WCSession.isSupported() else { return nil }
        session = .default
        inbox = PhoneWatchCommandInbox(queue: commandQueue)
        super.init()
        session.delegate = self
    }

    public func activate() {
        session.activate()
    }

    public func publish(foodSnapshot: WatchFoodPresetSnapshot) throws {
        let data = try WatchCommandTransportCodec.encodeFoodSnapshot(foodSnapshot)
        try session.updateApplicationContext([
            WatchCommandTransportCodec.foodSnapshotDataKey: data,
        ])
    }

    private func accept(_ data: Data) async -> WatchCommandAcknowledgment? {
        let acknowledgment = await inbox.accept(data)
        if acknowledgment?.disposition == .accepted,
           let onCommandAccepted
        {
            Task {
                await onCommandAccepted()
            }
        }
        return acknowledgment
    }

    private func backgroundAcknowledgment(
        for data: Data
    ) async -> [String: Any]? {
        guard let acknowledgment = await accept(data),
              let acknowledgmentData = try? WatchCommandTransportCodec
                  .encodeAcknowledgment(acknowledgment)
        else {
            return nil
        }
        return [
            WatchCommandTransportCodec.acknowledgmentDataKey: acknowledgmentData,
        ]
    }
}

extension PhoneWatchCommandReceiver: WCSessionDelegate {
    nonisolated public func session(
        _: WCSession,
        activationDidCompleteWith _: WCSessionActivationState,
        error _: Error?
    ) {}

    #if os(iOS)
    nonisolated public func sessionDidBecomeInactive(_: WCSession) {}

    nonisolated public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    nonisolated public func session(
        _: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  let acknowledgment = await accept(messageData),
                  let data = try? WatchCommandTransportCodec
                      .encodeAcknowledgment(acknowledgment)
            else {
                replyHandler(Data())
                return
            }
            replyHandler(data)
        }
    }

    nonisolated public func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        guard let data = userInfo[WatchCommandTransportCodec.commandDataKey] as? Data else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self,
                  let acknowledgment = await backgroundAcknowledgment(for: data)
            else {
                return
            }
            session.transferUserInfo(acknowledgment)
        }
    }
}
#endif

#if os(watchOS)
@MainActor
public final class WatchCommandSender: NSObject {
    public var onStatusChange: (@MainActor @Sendable (WatchCommandSenderStatus) -> Void)?
    public var onFoodSnapshot: (@MainActor @Sendable (WatchFoodPresetSnapshot) -> Void)?

    private let session: WCSession
    private let outbox: WatchCommandOutbox
    private var isFlushing = false
    private var retryNotBefore = [UUIDv7: Date]()

    public init?(outbox: WatchCommandOutbox) {
        guard WCSession.isSupported() else { return nil }
        session = .default
        self.outbox = outbox
        super.init()
        session.delegate = self
    }

    public func activate() {
        session.activate()
        Task { [weak self] in
            await self?.publishStatus()
        }
    }

    public func submit(_ command: ExtensionCommand) async throws {
        try await outbox.submit(command)
        await publishStatus()
        Task { [weak self] in
            await self?.flush()
        }
    }

    public func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        guard session.activationState == .activated else {
            session.activate()
            await publishStatus()
            return
        }
        let now = Date()
        retryNotBefore = retryNotBefore.filter { $0.value > now }
        let outstandingTransfers = Set(session.outstandingUserInfoTransfers.compactMap {
            transfer -> UUIDv7? in
            guard let data = transfer.userInfo[
                WatchCommandTransportCodec.commandDataKey
            ] as? Data else {
                return nil
            }
            return try? WatchCommandTransportCodec.decodeCommand(data).commandID
        })
        let outstanding = outstandingTransfers.union(retryNotBefore.keys)
        guard let commands = try? await outbox.commandsReadyForTransfer(
            excluding: outstanding
        ) else {
            await publishStatus()
            return
        }
        for command in commands {
            guard let data = try? WatchCommandTransportCodec.encodeCommand(command) else {
                try? await outbox.resolve(WatchCommandAcknowledgment(
                    commandID: command.commandID,
                    disposition: .rejected
                ))
                continue
            }
            if session.isReachable,
               let acknowledgment = await sendImmediately(
                   data,
                   commandID: command.commandID
               )
            {
                if acknowledgment.disposition == .retry {
                    scheduleRetry(for: command.commandID)
                } else {
                    try? await outbox.resolve(acknowledgment)
                }
                continue
            }
            session.transferUserInfo([
                WatchCommandTransportCodec.commandDataKey: data,
            ])
        }
        await publishStatus()
    }

    private func sendImmediately(
        _ data: Data,
        commandID: UUIDv7
    ) async -> WatchCommandAcknowledgment? {
        await withCheckedContinuation { continuation in
            session.sendMessageData(data) { replyData in
                guard let acknowledgment = try? WatchCommandTransportCodec
                    .decodeAcknowledgment(replyData),
                    acknowledgment.commandID == commandID
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: acknowledgment)
            } errorHandler: { _ in
                continuation.resume(returning: nil)
            }
        }
    }

    private func receiveAcknowledgment(_ data: Data) async {
        guard let acknowledgment = try? WatchCommandTransportCodec
            .decodeAcknowledgment(data)
        else {
            return
        }
        try? await outbox.resolve(acknowledgment)
        await publishStatus()
        if acknowledgment.disposition == .retry {
            scheduleRetry(for: acknowledgment.commandID)
        }
    }

    private func scheduleRetry(for commandID: UUIDv7) {
        guard retryNotBefore[commandID] == nil else { return }
        retryNotBefore[commandID] = Date().addingTimeInterval(60)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            await self?.flush()
        }
    }

    private func receiveFoodSnapshot(_ data: Data) {
        guard let snapshot = try? WatchCommandTransportCodec.decodeFoodSnapshot(data) else {
            return
        }
        onFoodSnapshot?(snapshot)
    }

    private func publishStatus() async {
        let pendingCount = (try? await outbox.pendingCount()) ?? 0
        let activationState: WatchConnectivityActivationState
        switch session.activationState {
        case .notActivated:
            activationState = .inactive
        case .inactive:
            activationState = .inactive
        case .activated:
            activationState = .activated
        @unknown default:
            activationState = .unavailable
        }
        onStatusChange?(WatchCommandSenderStatus(
            activationState: activationState,
            isReachable: session.isReachable,
            pendingCommandCount: pendingCount
        ))
    }

    private func consumeCurrentFoodSnapshot() {
        guard let data = session.receivedApplicationContext[
            WatchCommandTransportCodec.foodSnapshotDataKey
        ] as? Data else {
            return
        }
        receiveFoodSnapshot(data)
    }
}

extension WatchCommandSender: WCSessionDelegate {
    nonisolated public func session(
        _: WCSession,
        activationDidCompleteWith _: WCSessionActivationState,
        error _: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            consumeCurrentFoodSnapshot()
            await publishStatus()
            await flush()
        }
    }

    nonisolated public func sessionReachabilityDidChange(_: WCSession) {
        Task { @MainActor [weak self] in
            await self?.publishStatus()
            await self?.flush()
        }
    }

    nonisolated public func session(
        _: WCSession,
        didReceiveMessageData messageData: Data
    ) {
        Task { @MainActor [weak self] in
            await self?.receiveAcknowledgment(messageData)
        }
    }

    nonisolated public func session(
        _: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        guard let data = userInfo[
            WatchCommandTransportCodec.acknowledgmentDataKey
        ] as? Data else {
            return
        }
        Task { @MainActor [weak self] in
            await self?.receiveAcknowledgment(data)
        }
    }

    nonisolated public func session(
        _: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        guard let data = applicationContext[
            WatchCommandTransportCodec.foodSnapshotDataKey
        ] as? Data else {
            return
        }
        Task { @MainActor [weak self] in
            self?.receiveFoodSnapshot(data)
        }
    }

    nonisolated public func session(
        _: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: Error?
    ) {
        guard error != nil else { return }
        Task { @MainActor [weak self] in
            await self?.flush()
        }
    }
}
#endif
#endif
