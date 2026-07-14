import Foundation

public enum AudioLevelScale {
    private static let noiseFloorDecibels = -50.0
    private static let speechCeilingDecibels = -8.0
    private static let responseExponent = 0.65

    public static func displayLevel(decibels: Double) -> Double {
        guard decibels.isFinite else {
            return 0
        }

        let linearPosition = (decibels - noiseFloorDecibels)
            / (speechCeilingDecibels - noiseFloorDecibels)
        let clampedPosition = min(1, max(0, linearPosition))
        return pow(clampedPosition, responseExponent)
    }

    public static func displayLevel(rootMeanSquare: Double) -> Double {
        guard rootMeanSquare.isFinite, rootMeanSquare > 0 else {
            return 0
        }

        let decibels = 20 * log10(rootMeanSquare)
        return displayLevel(decibels: decibels)
    }
}
