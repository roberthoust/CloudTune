//
//  PlainTextField.swift
//  CloudTune
//
//  Created by Robert Houst on 9/1/25.
//


import SwiftUI
import UIKit

struct PlainTextField: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var onChange: ((String) -> Void)?

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField(frame: .zero)
        tf.placeholder = placeholder
        tf.borderStyle = .none
        tf.clearButtonMode = .whileEditing

        // Kill anything that triggers heavy input ops
        tf.keyboardType = .asciiCapable
        tf.autocorrectionType = .no
        tf.spellCheckingType = .no
        tf.smartDashesType = .no
        tf.smartQuotesType = .no
        tf.smartInsertDeleteType = .no
        tf.textContentType = .none
        tf.returnKeyType = .done
        tf.delegate = context.coordinator

        // iOS 17+: avoid inline predictions
        if #available(iOS 17.0, *) {
            tf.inlinePredictionType = .no
        }

        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        return tf
    }

    func updateUIView(_ tf: UITextField, context: Context) {
        if tf.text != text { tf.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onChange: onChange) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var onChange: ((String) -> Void)?
        init(text: Binding<String>, onChange: ((String) -> Void)?) {
            self.text = text; self.onChange = onChange
        }

        @objc func editingChanged(_ sender: UITextField) {
            text.wrappedValue = sender.text ?? ""
            onChange?(text.wrappedValue)
        }

        // Optional: block emoji input outright (keeps OS out of emoji search)
        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if containsEmoji(string) { return false }
            return true
        }

        private func containsEmoji(_ s: String) -> Bool {
            for scalar in s.unicodeScalars {
                // fast enough heuristic
                switch scalar.value {
                case 0x1F300...0x1FAD6, // Misc emoji blocks
                     0x1FA70...0x1FAFF,
                     0x1F1E6...0x1F1FF, // flags
                     0x2600...0x27BF,   // misc symbols
                     0xFE0F:            // variation selector
                    return true
                default: continue
                }
            }
            return false
        }
    }
}