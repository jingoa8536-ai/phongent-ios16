// Geometry adapted from sam70361/aora-bot @ e3b6148.
// Personal non-commercial use; original license/notice retained in App/Resources/Aora.
import SwiftUI

struct AoraGeometry: Decodable {
    var body: [[Double]]
    var expressions: [String: [[[Double]]]]
    static let shared: AoraGeometry = {
        guard let url = Bundle.main.url(forResource: "AoraGeometry", withExtension: "json"), let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(AoraGeometry.self, from: data) else { return AoraGeometry(body: [], expressions: [:]) }
        return value
    }()
}
struct RingVector: VectorArithmetic {
    var values: [Double]
    static let zero = RingVector(values: [])
    static func + (lhs: Self, rhs: Self) -> Self { .init(values: (0..<max(lhs.values.count, rhs.values.count)).map { (lhs.values.indices.contains($0) ? lhs.values[$0] : 0) + (rhs.values.indices.contains($0) ? rhs.values[$0] : 0) }) }
    static func - (lhs: Self, rhs: Self) -> Self { var r = rhs; r.scale(by: -1); return lhs + r }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}
struct AoraRing: Shape {
    var vector: RingVector
    init(_ points: [[Double]]) { vector = RingVector(values: points.flatMap { $0 }) }
    var animatableData: RingVector { get { vector } set { vector = newValue } }
    func path(in rect: CGRect) -> Path {
        var p = Path(); let v = vector.values
        for i in stride(from: 0, to: v.count - (v.count % 2), by: 2) {
            let point = CGPoint(x: (v[i] + 15) / 259 * rect.width, y: (v[i+1] + 15) / 259 * rect.height)
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath(); return p
    }
}
struct AoraAvatar: View {
    var phase: String
    var tint: Color = .mint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var dimmed
    var body: some View {
        let geometry = AoraGeometry.shared
        let eyes = geometry.expressions[phase] ?? geometry.expressions["idle"] ?? []
        let color = phase == "failed" ? Color(red: 0.87, green: 0.34, blue: 0.34) : Color(red: 0.95, green: 0.94, blue: 0.91)
        ZStack {
            AoraRing(geometry.body).fill(RadialGradient(colors: [.white, color, color.opacity(0.7)], center: .init(x: 0.35, y: 0.28), startRadius: 0, endRadius: 100))
            ForEach(0..<eyes.count, id: \.self) { i in AoraRing(eyes[i]).fill(Color(white: 0.09)) }
        }
        .rotationEffect(.degrees(phase == "failed" ? -6 : phase == "waiting" ? 5 : 0))
        .scaleEffect(phase == "completed" ? 1.05 : 1)
        .animation(reduceMotion || dimmed ? nil : .spring(duration: 0.65, bounce: 0.22), value: phase)
        .accessibilityLabel("agent 表情：" + AgentSnapshot.label(phase))
    }
}
enum AoraEmotion {
    static func id(for phase: String) -> String { ["offline":"00", "idle":"02", "running":"32", "waiting":"35", "takeover":"13", "confirmation":"20", "completed":"33", "failed":"34", "cancelled":"41"][phase] ?? "02" }
}
