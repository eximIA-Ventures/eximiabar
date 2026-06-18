import AppKit
import ApplicationServices
import ClaudeBarCore
import os

/// Registers a single global keyboard shortcut that toggles the popover (EXB-4.4 AC4).
///
/// **Dependency-free (AC10):** uses `NSEvent.addGlobalMonitorForEvents` — no Carbon
/// `RegisterEventHotKey`, no third-party `HotKey.swift`. A *global* monitor only fires while another
/// app is frontmost, so a companion *local* monitor is also installed to catch the shortcut when one
/// of exímIABar's own windows (e.g. Settings) is key. The local monitor swallows the event (returns
/// `nil`) so the keystroke does not also reach the focused control.
///
/// **Accessibility gate (Dev Notes):** the global monitor requires Accessibility permission. We check
/// `AXIsProcessTrusted()` before installing the global monitor and surface `isTrusted` so Settings can
/// show the "grant access" hint. The local monitor needs no permission, so the shortcut still works
/// inside the app's own windows even when access has not been granted — the popover is always
/// additionally reachable by clicking the menu-bar icon (the hotkey is additive, never the only path).
///
/// `@MainActor` because every property and the toggle action are UI state; the action is invoked on
/// the main actor directly (monitors deliver on the main run loop).
@MainActor
final class GlobalHotkeyManager {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var binding: HotkeyBinding?
    private var action: (@MainActor () -> Void)?

    private let log = Logger(subsystem: CoreLog.subsystem, category: "hotkey")

    /// Whether the process currently has Accessibility permission. Settings reads this to decide
    /// whether to show the "grant access" hint (AC4 / Dev Notes step 2). Never prompts.
    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Register `binding` to invoke `action`. Replaces any previous registration. A `nil` binding
    /// unregisters (the user cleared the shortcut); the popover stays reachable via the icon.
    func register(binding: HotkeyBinding?, action: @escaping @MainActor () -> Void) {
        self.unregister()
        self.action = action
        self.binding = binding
        guard let binding else {
            self.log.debug("hotkey unregistered (no binding)")
            return
        }

        // Local monitor: fires when one of our own windows is key. No Accessibility permission needed.
        // Returning `nil` consumes the matched event so the focused control never also sees it.
        self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matches(event, binding: binding) else { return event }
            self.fire()
            return nil
        }

        // Global monitor: fires only while another app is frontmost, and only with Accessibility
        // permission. Skip installing it (but keep the local monitor) when not trusted so we never
        // prompt and never silently fail the in-app path.
        guard self.isTrusted else {
            self.log.info("accessibility not trusted; global hotkey limited to in-app windows")
            return
        }
        self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matches(event, binding: binding) else { return }
            self.fire()
        }
        self.log.debug("global hotkey registered")
    }

    /// Remove both monitors. Safe to call when nothing is registered.
    func unregister() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    deinit {
        // `NSEvent.removeMonitor` is main-actor-safe to skip in deinit: monitors are torn down on
        // app exit by AppKit. Avoid touching `@MainActor` state from a nonisolated deinit.
    }

    // MARK: - Matching

    /// `true` when `event` is the configured key + exactly the configured modifiers (AC4 §10). The
    /// modifier comparison is on the device-independent set so Caps Lock / keypad bits never block it.
    private func matches(_ event: NSEvent, binding: HotkeyBinding) -> Bool {
        guard event.keyCode == binding.keyCodeValue else { return false }
        return event.modifierFlags.deviceIndependentRelevant == binding.modifierFlags
    }

    private func fire() {
        self.action?()
    }
}
