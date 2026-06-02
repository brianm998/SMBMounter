// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SystemConfiguration

/// Optional network-reachability monitor (§12). Watches each unique server
/// hostname and invokes `onReachable(server)` when it transitions to reachable,
/// so the daemon can nudge any `Failed` supervisors for that server to retry.
///
/// Uses `SCNetworkReachabilitySetDispatchQueue` so callbacks arrive on a GCD
/// queue — no CFRunLoop required (the daemon parks on `dispatchMain`). Entirely
/// best-effort: if SystemConfiguration can't create a target, that server is
/// simply not monitored.
final class Reachability {
    /// Boxed context handed to the C callback via an opaque pointer. Retained for
    /// the lifetime of the monitor in `boxes`.
    private final class Box {
        let server: String
        let onReachable: (String) -> Void
        init(server: String, onReachable: @escaping (String) -> Void) {
            self.server = server
            self.onReachable = onReachable
        }
    }

    private let queue = DispatchQueue(label: "com.brian.smbmounter.reachability")
    private let log = Log(category: "reachability")
    private var targets: [SCNetworkReachability] = []
    private var boxes: [Box] = []
    private let servers: [String]
    private let onReachable: (String) -> Void

    init(servers: [String], onReachable: @escaping (String) -> Void) {
        self.servers = Array(Set(servers))   // unique
        self.onReachable = onReachable
    }

    func start() {
        for server in servers {
            guard let target = SCNetworkReachabilityCreateWithName(nil, server) else {
                log.warn("could not create reachability target for \(server)")
                continue
            }
            let box = Box(server: server, onReachable: onReachable)
            boxes.append(box)

            var context = SCNetworkReachabilityContext()
            context.info = Unmanaged.passUnretained(box).toOpaque()

            let callback: SCNetworkReachabilityCallBack = { _, flags, info in
                guard let info = info else { return }
                let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
                let reachable = flags.contains(.reachable) && !flags.contains(.connectionRequired)
                if reachable { box.onReachable(box.server) }
            }

            if SCNetworkReachabilitySetCallback(target, callback, &context),
               SCNetworkReachabilitySetDispatchQueue(target, queue) {
                targets.append(target)
                log.debug("monitoring reachability of \(server)")
            } else {
                log.warn("failed to register reachability callback for \(server)")
            }
        }
    }

    func stop() {
        for target in targets {
            SCNetworkReachabilitySetDispatchQueue(target, nil)
        }
        targets.removeAll()
        boxes.removeAll()
    }
}
