import Foundation

enum StatusItemVisibilityObservation: Equatable {
    case visible
    case hidden
    case inconclusive
}

struct StatusItemVisibilitySnapshot: Equatable {
    let apiVisible: Bool
    let hasButton: Bool
    let hasWindow: Bool
    let hasAvailableScreen: Bool
    let windowIsOnScreen: Bool

    var observation: StatusItemVisibilityObservation {
        guard apiVisible else {
            return .hidden
        }
        guard hasButton, hasWindow, hasAvailableScreen else {
            return .inconclusive
        }
        return windowIsOnScreen ? .visible : .hidden
    }
}

struct StatusItemGuidanceCoordinator {
    private enum State {
        case awaitingCheck
        case awaitingWindow
        case presented
        case notNeeded
    }

    private var state = State.awaitingCheck

    mutating func completeDeferredCheck(
        _ snapshot: StatusItemVisibilitySnapshot
    ) {
        guard state == .awaitingCheck else {
            return
        }
        switch snapshot.observation {
        case .hidden:
            state = .awaitingWindow
        case .visible, .inconclusive:
            state = .notNeeded
        }
    }

    var hasObservedHiddenStatusItem: Bool {
        state == .awaitingWindow || state == .presented
    }

    var hasPendingGuidance: Bool {
        state == .awaitingWindow
    }

    @discardableResult
    mutating func cancelIfStatusItemIsVisible(
        _ snapshot: StatusItemVisibilitySnapshot
    ) -> Bool {
        guard snapshot.observation == .visible,
              hasObservedHiddenStatusItem else {
            return false
        }
        state = .notNeeded
        return true
    }

    mutating func markGuidancePresented() {
        guard hasPendingGuidance else { return }
        state = .presented
    }

    mutating func requeuePresentedGuidance() {
        guard state == .presented else { return }
        state = .awaitingWindow
    }
}
