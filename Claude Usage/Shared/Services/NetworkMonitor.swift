//
//  NetworkMonitor.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-27.
//

import Foundation
import Network

/// Monitors network connectivity using NWPathMonitor
/// Provides callback when network becomes available
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    enum ConnectivitySnapshot: Equatable, Sendable {
        case unknown
        case offline
        case online
    }

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.claudeusage.networkmonitor")

    private let stateLock = NSLock()
    private var currentSnapshot: ConnectivitySnapshot = .unknown

    /// Path callbacks run on the monitor queue while renewal admission runs
    /// on background tasks. A synchronized snapshot avoids a data race and,
    /// unlike the old initial `false`, does not claim the Mac is offline
    /// before NWPathMonitor has actually delivered its first observation.
    var connectivitySnapshot: ConnectivitySnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentSnapshot
    }

    var isConnected: Bool { connectivitySnapshot == .online }

    /// Callback triggered when network becomes available
    var onNetworkAvailable: (() -> Void)?

    init() {
        monitor = NWPathMonitor()
    }

    /// Starts monitoring network connectivity
    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            let nowConnected = path.status == .satisfied
            self.stateLock.lock()
            let wasConnected = self.currentSnapshot == .online
            switch path.status {
            case .satisfied:
                self.currentSnapshot = .online
            case .unsatisfied:
                self.currentSnapshot = .offline
            case .requiresConnection:
                // An on-demand connection may still succeed; this is not
                // positive evidence that dispatch would be offline.
                self.currentSnapshot = .unknown
            @unknown default:
                self.currentSnapshot = .unknown
            }
            self.stateLock.unlock()

            // Only fire callback when transitioning from disconnected to connected
            if nowConnected && !wasConnected {
                DispatchQueue.main.async {
                    LoggingService.shared.logInfo("Network became available")
                    self.onNetworkAvailable?()
                }
            }
        }

        monitor.start(queue: queue)
    }

    /// Stops monitoring network connectivity
    func stopMonitoring() {
        monitor.cancel()
    }
}
