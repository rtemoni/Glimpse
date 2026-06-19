import Foundation

public enum RecordingStateEvent: String, Equatable, Sendable {
    case startPreparing
    case markReady
    case startRecording
    case pause
    case resume
    case startStopping
    case finishStopped
    case fail
    case reset
}

public enum RecordingStateMachineError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidTransition(event: RecordingStateEvent, state: RecordingState)

    public var description: String {
        switch self {
        case let .invalidTransition(event, state):
            return "Cannot apply \(event.rawValue) while recorder is \(state.rawValue)."
        }
    }
}

public struct RecordingStateMachine: Sendable {
    public private(set) var state: RecordingState

    public init(initialState: RecordingState = .idle) {
        self.state = initialState
    }

    public mutating func startPreparing() throws {
        guard state == .idle else {
            throw RecordingStateMachineError.invalidTransition(event: .startPreparing, state: state)
        }
        state = .preparing
    }

    public mutating func markReady() throws {
        guard state == .preparing else {
            throw RecordingStateMachineError.invalidTransition(event: .markReady, state: state)
        }
        state = .ready
    }

    public mutating func startRecording() throws {
        guard state == .ready else {
            throw RecordingStateMachineError.invalidTransition(event: .startRecording, state: state)
        }
        state = .recording
    }

    public mutating func pause() throws {
        guard state == .recording else {
            throw RecordingStateMachineError.invalidTransition(event: .pause, state: state)
        }
        state = .paused
    }

    public mutating func resume() throws {
        guard state == .paused else {
            throw RecordingStateMachineError.invalidTransition(event: .resume, state: state)
        }
        state = .recording
    }

    public mutating func startStopping() throws {
        switch state {
        case .preparing, .ready, .recording, .paused:
            state = .stopping
        case .idle, .stopping, .error:
            throw RecordingStateMachineError.invalidTransition(event: .startStopping, state: state)
        }
    }

    public mutating func finishStopped() throws {
        guard state == .stopping else {
            throw RecordingStateMachineError.invalidTransition(event: .finishStopped, state: state)
        }
        state = .idle
    }

    public mutating func fail() {
        state = .error
    }

    public mutating func reset() {
        state = .idle
    }
}
