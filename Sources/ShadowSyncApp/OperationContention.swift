enum OperationContentionIntent: Equatable {
    case recoveryPresentation
    case startNewRun
    case quitUtility

    func coalescing(_ other: OperationContentionIntent) -> OperationContentionIntent {
        if self == .quitUtility || other == .quitUtility {
            return .quitUtility
        }
        return other == .recoveryPresentation ? self : other
    }
}

enum OperationContentionObservation: Equatable {
    case held
    case released
}

enum OperationContentionEffect: Equatable {
    case scheduleRevalidation(token: UInt64, delayed: Bool)
    case present(token: UInt64)
    case foreground(token: UInt64)
    case cancelRevalidation
    case dismiss(token: UInt64)
    case resume(token: UInt64, intent: OperationContentionIntent)
}

struct OperationContentionCoordinator {
    private struct Pending: Equatable {
        let token: UInt64
        var intent: OperationContentionIntent
        var isPresented: Bool
        var presentationDismissed: Bool
    }

    private var issuedToken: UInt64 = 0
    private var pending: Pending?

    var currentToken: UInt64? {
        pending?.token
    }

    var hasPendingRetry: Bool {
        pending != nil
    }

    var isPresented: Bool {
        pending?.isPresented == true
    }

    mutating func request(
        _ intent: OperationContentionIntent
    ) -> [OperationContentionEffect] {
        if var current = pending {
            current.intent = current.intent.coalescing(intent)
            pending = current
            return current.isPresented
                ? [.foreground(token: current.token)]
                : []
        }
        issuedToken &+= 1
        let token = issuedToken
        pending = Pending(
            token: token,
            intent: intent,
            isPresented: false,
            presentationDismissed: false
        )
        return [
            .scheduleRevalidation(token: token, delayed: false),
        ]
    }

    mutating func observe(
        _ observation: OperationContentionObservation,
        token: UInt64
    ) -> [OperationContentionEffect] {
        guard var current = pending, current.token == token else {
            return []
        }
        switch observation {
        case .held:
            if current.isPresented || current.presentationDismissed {
                return [
                    .scheduleRevalidation(token: token, delayed: true),
                ]
            }
            current.isPresented = true
            pending = current
            return [
                .present(token: token),
                .scheduleRevalidation(token: token, delayed: true),
            ]
        case .released:
            pending = nil
            var effects: [OperationContentionEffect] = [
                .cancelRevalidation,
            ]
            if current.isPresented {
                effects.append(.dismiss(token: token))
            }
            effects.append(.resume(token: token, intent: current.intent))
            return effects
        }
    }

    mutating func presentationClosed(
        token: UInt64
    ) -> [OperationContentionEffect] {
        guard var current = pending,
              current.token == token,
              current.isPresented else {
            return []
        }
        if current.intent == .quitUtility {
            current.isPresented = false
            current.presentationDismissed = true
            pending = current
            return [
                .scheduleRevalidation(token: token, delayed: true),
            ]
        }
        pending = nil
        return [.cancelRevalidation]
    }

    mutating func cancel() -> [OperationContentionEffect] {
        guard let current = pending else {
            return []
        }
        pending = nil
        var effects: [OperationContentionEffect] = [.cancelRevalidation]
        if current.isPresented {
            effects.append(.dismiss(token: current.token))
        }
        return effects
    }
}
