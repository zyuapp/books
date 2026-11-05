import SwiftUI

/// Liquid Glass on macOS 26; material and bordered styles on earlier systems.
extension View {
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.regularMaterial)
                    if let tint { shape.fill(tint) }
                    shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                }
            }
        }
    }

    /// Liquid Glass draws its own shadow; earlier systems get a drawn one.
    @ViewBuilder
    func glassShadow(opacity: Double = 0.12, radius: CGFloat, y: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self
        } else {
            shadow(color: .black.opacity(opacity), radius: radius, y: y)
        }
    }

    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func glassProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// Keeps scrolled content from smearing under the header.
    @ViewBuilder
    func hiddenTopScrollEdge() -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }

    @ViewBuilder
    func softScrollEdges(_ edges: Edge.Set = .all) -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }
}
