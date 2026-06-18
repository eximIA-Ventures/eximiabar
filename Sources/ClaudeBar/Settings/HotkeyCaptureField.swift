import AppKit
import SwiftUI

/// A SwiftUI field that captures a global keyboard shortcut (EXB-4.4 AC4 §11).
///
/// Click the field to enter capture mode (it reads "Press shortcut…"); press a key combination and
/// the binding is saved. While capturing, the field becomes first responder and swallows key events
/// so the combo is recorded rather than triggering anything else. Pressing Escape cancels; pressing
/// Delete/Backspace clears the binding (→ `nil`). Mirrors the common macOS shortcut-recorder UX with
/// no third-party dependency.
struct HotkeyCaptureField: NSViewRepresentable {
    @Binding var binding: HotkeyBinding?
    /// Placeholder shown when there is no binding and the field is not capturing.
    let placeholder: String
    /// Prompt shown while the field is actively capturing.
    let capturingPrompt: String

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.placeholder = placeholder
        button.capturingPrompt = capturingPrompt
        button.onCapture = { newBinding in
            // `nil` clears the binding (Delete); a value sets it.
            binding = newBinding
        }
        button.refresh(binding: binding)
        return button
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.placeholder = placeholder
        nsView.capturingPrompt = capturingPrompt
        nsView.refresh(binding: binding)
    }

    /// The recorder control. A bordered `NSButton`-style box that, when clicked, becomes first
    /// responder and records the next key-down as a `HotkeyBinding`.
    final class RecorderButton: NSView {
        var placeholder = ""
        var capturingPrompt = ""
        var onCapture: ((HotkeyBinding?) -> Void)?

        private var currentBinding: HotkeyBinding?
        private var isCapturing = false
        private let label = NSTextField(labelWithString: "")

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            self.configure()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            self.configure()
        }

        private func configure() {
            self.wantsLayer = true
            self.layer?.cornerRadius = 5
            self.layer?.borderWidth = 1
            self.layer?.borderColor = NSColor.separatorColor.cgColor
            self.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

            self.label.translatesAutoresizingMaskIntoConstraints = false
            self.label.alignment = .center
            self.label.font = .systemFont(ofSize: NSFont.systemFontSize)
            self.label.textColor = .labelColor
            self.label.lineBreakMode = .byTruncatingTail
            self.addSubview(self.label)
            NSLayoutConstraint.activate([
                self.label.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                self.label.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 8),
                self.label.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -8),
                self.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            ])
        }

        /// Update the displayed binding from SwiftUI (no capture in progress).
        func refresh(binding: HotkeyBinding?) {
            guard !self.isCapturing else { return }
            self.currentBinding = binding
            self.renderIdle()
        }

        private func renderIdle() {
            self.layer?.borderColor = NSColor.separatorColor.cgColor
            if let currentBinding {
                self.label.stringValue = currentBinding.displayString
                self.label.textColor = .labelColor
            } else {
                self.label.stringValue = self.placeholder
                self.label.textColor = .secondaryLabelColor
            }
        }

        private func renderCapturing() {
            self.layer?.borderColor = NSColor.controlAccentColor.cgColor
            self.label.stringValue = self.capturingPrompt
            self.label.textColor = .controlAccentColor
        }

        // MARK: - First responder + clicks

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            self.beginCapture()
        }

        private func beginCapture() {
            self.isCapturing = true
            self.window?.makeFirstResponder(self)
            self.renderCapturing()
        }

        private func endCapture() {
            self.isCapturing = false
            self.window?.makeFirstResponder(nil)
            self.renderIdle()
        }

        override func resignFirstResponder() -> Bool {
            if self.isCapturing {
                // Lost focus mid-capture (clicked elsewhere): cancel without changing the binding.
                self.isCapturing = false
                self.renderIdle()
            }
            return super.resignFirstResponder()
        }

        override func keyDown(with event: NSEvent) {
            guard self.isCapturing else {
                super.keyDown(with: event)
                return
            }

            // Escape cancels; Delete/Backspace clears the binding.
            if event.keyCode == 53 { // Escape
                self.endCapture()
                return
            }
            if event.keyCode == 51 || event.keyCode == 117 { // Delete / Forward-delete
                self.currentBinding = nil
                self.onCapture?(nil)
                self.endCapture()
                return
            }

            // Require at least one real modifier so a bare letter can't become a global hotkey.
            let modifiers = event.modifierFlags.deviceIndependentRelevant
            guard !modifiers.isEmpty else {
                // Flash the prompt; ignore an un-modified key.
                NSSound.beep()
                return
            }

            let captured = HotkeyBinding(modifiers: modifiers, keyCode: event.keyCode)
            self.currentBinding = captured
            self.onCapture?(captured)
            self.endCapture()
        }

        override func updateLayer() {
            super.updateLayer()
            // Keep the static layer colors in sync with appearance changes (light/dark).
            self.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            if !self.isCapturing {
                self.layer?.borderColor = NSColor.separatorColor.cgColor
            }
        }
    }
}
