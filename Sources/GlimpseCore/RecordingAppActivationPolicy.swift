public enum RecordingAppActivationPolicy {
    public static func shouldStopRecording(
        state: RecordingState,
        isWindowHiddenForRecording: Bool
    ) -> Bool {
        guard isWindowHiddenForRecording else {
            return false
        }

        return state == .recording || state == .paused
    }
}
