//
//  TerminalSoftwareInputDelegate.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import UIKit

    @MainActor
    public protocol TerminalSoftwareInputDelegate: AnyObject {
        func terminalView(_ view: UITerminalView, insertText text: String) -> Bool
        func terminalViewDeleteBackward(_ view: UITerminalView) -> Bool
    }
#endif
