import SwiftUI

enum ChartStyle: String, CaseIterable {
    case ring, bar, stepped, numeric, spark

    var label: String {
        switch self {
        case .ring: "Ring"
        case .bar: "Bar"
        case .stepped: "Stepped"
        case .numeric: "Numeric"
        case .spark: "Sparkline"
        }
    }
}

@MainActor
final class StylePref: StylePreferenceStore<ChartStyle> {
    static let shared = StylePref()

    private init() {
        super.init(
            styleKey: "MacIsland.chartStyle",
            cycledKey: "MacIsland.hasCycledStyle",
            defaultStyle: .ring
        )
    }
}
