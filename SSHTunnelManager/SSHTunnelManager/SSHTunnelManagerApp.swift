import SwiftUI
import Darwin

@main
struct SSHTunnelManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra("SSH Tunnel Manager", systemImage: "network") {
            MenuBarView().environment(delegate.manager)
        }
        .menuBarExtraStyle(.menu)
        Window("SSH Tunnel Manager", id: "main") {
            ContentView().environment(delegate.manager)
        }
        .defaultSize(width: 760, height: 480)
        .windowResizability(.automatic)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager = TunnelManager()
    private var monitor: NetworkMonitor?
    private var startup: Task<Void, Never>?
    private var signals: [DispatchSourceSignal] = []
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableSuddenTermination()
        manager.networkChanged(available: false)
        startup = Task { [self] in
            do {
                try await manager.start()
                let monitor = NetworkMonitor { [weak self] in self?.manager.networkChanged(available: $0) }
                self.monitor = monitor
                monitor.start()
            } catch is InstanceAlreadyRunning {
                // All copies, including Vibe Page, share one lock. Opening a
                // second copy activates the existing app without touching SSH.
                NSWorkspace.shared.runningApplications.first {
                    $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != getpid()
                }?.activate(options: [])
                // AppKit can enter a nested termination loop. Let this startup
                // task return BEFORE the termination delegate awaits it.
                requestAppTermination()
            } catch is CancellationError {
                // Shutdown owns the rest of cleanup.
            } catch {
                manager.errorMessage = "配置加载失败，原文件未改动：\(error.localizedDescription)"
            }
        }
        let notifications = NSWorkspace.shared.notificationCenter
        notifications.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        notifications.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        notifications.addObserver(self, selector: #selector(willPowerOff), name: NSWorkspace.willPowerOffNotification, object: nil)
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { DispatchQueue.main.async { requestAppTermination() } }
            source.resume()
            signals.append(source)
        }
    }

    @objc private func willSleep() { manager.setSleeping(true) }
    @objc private func didWake() {
        manager.networkChanged(available: false)
        manager.setSleeping(false)
        monitor?.refresh()
    }
    @objc private func willPowerOff() { requestAppTermination() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !terminating {
            terminating = true
            monitor?.stop()
            startup?.cancel()
            Task {
                await startup?.value
                await manager.shutdown()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

/// terminateLater enters an AppKit modal loop. Start termination from a run-loop
/// timer, not a Swift task or main-dispatch block: those would hold the executor
/// that the async cleanup needs to finish and reply to AppKit.
@MainActor
func requestAppTermination() {
    NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
}
