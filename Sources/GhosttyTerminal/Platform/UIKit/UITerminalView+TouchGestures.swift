//
//  UITerminalView+TouchGestures.swift
//  libghostty-spm
//

#if canImport(UIKit)
    #if !targetEnvironment(macCatalyst)
        import UIKit

        extension UITerminalView {
            /// Direct-touch grammar: single tap for selection dismissal/keyboard,
            /// double tap for a word, triple tap for a row, long press for the menu.
            func setupTouchSelectionGestures() {
                for count in 1 ... 3 {
                    let tap = UITapGestureRecognizer(target: self, action: #selector(handleSelectionTap(_:)))
                    tap.numberOfTapsRequired = count
                    tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                    // A host delegate handles the single tap in `touchesEnded`.
                    // A double or triple tap still waiting for its later taps
                    // must not hold that touch's end back until it gives up.
                    tap.delaysTouchesEnded = false
                    tap.delegate = self
                    addGestureRecognizer(tap)
                    touchSelection.tapRecognizers.append(tap)
                }
                touchSelection.tapRecognizers[0].require(toFail: touchSelection.tapRecognizers[1])
                touchSelection.tapRecognizers[1].require(toFail: touchSelection.tapRecognizers[2])
                updateTouchSelectionGestures()
            }

            func updateTouchSelectionGestures() {
                touchSelection.longPress?.minimumPressDuration = usesHostTextSelection ? 0.5 : 0.7
                // A host delegate keeps single taps; double and triple taps
                // still select a word and a row.
                for (index, tap) in touchSelection.tapRecognizers.enumerated() {
                    tap.isEnabled = usesInlineTextSelection || (touchSelection.enabled && index > 0)
                }
                touchSelection.scrollGesture?.maximumNumberOfTouches = usesInlineTextSelection ? 2 : 1
            }

            @objc func handleSelectionTap(_ gesture: UITapGestureRecognizer) {
                let selects = gesture.numberOfTapsRequired > 1
                guard usesInlineTextSelection || (touchSelection.enabled && selects),
                      gesture.state == .ended, surface != nil
                else { return }
                // With a host delegate the first tap may already have moved
                // the text; select what that tap landed on.
                let tapCell = usesHostTextSelection ? touchSelection.tapCell : nil
                softwareKeyboard.tapCandidateArmed = false
                stopMomentumScrolling()
                let point = gesture.location(in: self)
                defer {
                    touchSelection.tapBeganWithMenu = false
                    touchSelection.tapStopsMomentum = false
                }
                guard !touchSelection.tapStopsMomentum else { return }
                switch gesture.numberOfTapsRequired {
                case 3:
                    beginTouchSelection(at: point, selectAll: false, selectLine: true, cell: tapCell)
                case 2:
                    beginTouchSelection(at: point, selectAll: false, cell: tapCell)
                default:
                    if touchSelection.range != nil {
                        dismissTouchSelection()
                    } else if touchSelection.tapBeganWithMenu || isTouchMenuVisible {
                        if #available(iOS 16.0, *) {
                            selectionEditMenuInteraction.dismissMenu()
                        } else {
                            UIMenuController.shared.hideMenu()
                        }
                    } else {
                        // Report the click before the keyboard changes the grid,
                        // including while a TUI owns mouse input.
                        sendTapClick(at: point)
                        toggleSoftwareKeyboard()
                    }
                }
            }

            /// Once selection is active, a one-finger pan extends around a fixed
            /// endpoint; a two-finger pan remains available for local scrollback.
            func handleTouchSelectionPan(_ gesture: UIPanGestureRecognizer) {
                guard let range = touchSelection.range, let grid = touchSelection.grid else { return }
                let point = gesture.location(in: self)
                switch gesture.state {
                case .began:
                    stopMomentumScrolling()
                    if #available(iOS 16.0, *) {
                        selectionEditMenuInteraction.dismissMenu()
                    }
                    let cell = grid.cell(at: point, viewportOffset: touchViewportOffset)
                    func near(_ endpoint: Int) -> Bool {
                        abs(cell % grid.columns - endpoint % grid.columns) < 3
                            && abs(cell / grid.columns - endpoint / grid.columns) < 2
                    }
                    let fixed: Int = if near(range.lowerBound) {
                        range.upperBound
                    } else if near(range.upperBound) {
                        range.lowerBound
                    } else {
                        touchSelection.pivot?.lowerBound ?? range.lowerBound
                    }
                    touchSelection.pivot = surface?.glyphCells(at: fixed, columns: grid.columns)
                    touchSelection.endpoint = .end
                    beginTouchSelectionLoupe(at: point, from: nil)
                case .changed, .ended:
                    touchSelection.dragPoint = point
                    extendTouchSelection(to: point, endpoint: .end)
                    if gesture.state == .ended {
                        finishTouchSelectionDrag(at: point)
                    } else {
                        moveTouchSelectionLoupe(to: point)
                        startTouchSelectionScrolling()
                    }
                case .cancelled, .failed:
                    dismissTouchSelection()
                default:
                    break
                }
            }
        }
    #endif
#endif
