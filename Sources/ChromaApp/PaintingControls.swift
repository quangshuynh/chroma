import AppKit
import ChromaCore
import SwiftUI

extension EditorColor {
    var nsColor: NSColor {
        NSColor(
            srgbRed: Double(red) / 255, green: Double(green) / 255,
            blue: Double(blue) / 255, alpha: Double(alpha) / 255)
    }
    init?(native color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(
            sRGBRed: srgb.redComponent, green: srgb.greenComponent,
            blue: srgb.blueComponent, alpha: srgb.alphaComponent)
    }
}

struct PaintingControls: View {
    @ObservedObject var state: EditorState
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                toolPicker
                paintControls
            }
            VStack(alignment: .leading, spacing: 8) {
                toolPicker
                paintControls
            }
        }.controlSize(.small).padding(.horizontal, 16).padding(.vertical, 8)
    }
    private var toolPicker: some View {
        Picker("Tool", selection: $state.tool) {
            ForEach(PaintTool.allCases, id: \.self) { tool in Text(tool.rawValue).tag(tool) }
        }.frame(width: 210).accessibilityLabel("Editing tool")
    }
    private var paintControls: some View {
        HStack(spacing: 12) {
            Stepper(value: $state.diameter, in: StrokeSettings.diameterRange) {
                HStack(spacing: 4) {
                    Text("Size")
                    TextField(
                        "Size",
                        value: Binding(
                            get: { state.diameter },
                            set: {
                                state.diameter = min(512, max(1, $0))
                            }), format: .number.grouping(.never)
                    )
                    .frame(width: 38).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Brush size in pixels")
                    Text("px")
                }
            }.fixedSize().disabled(!state.tool.paints)
                .accessibilityLabel("Brush diameter").accessibilityValue("\(state.diameter) pixels")
                .help("Diameter in document pixels, from 1 to 512")
            ColorPicker("Foreground", selection: colorBinding(foreground: true), supportsOpacity: true)
                .fixedSize().help("Pencil and Brush color, including alpha")
            ColorPicker("Background", selection: colorBinding(foreground: false), supportsOpacity: true)
                .fixedSize().help("Secondary editor color; swap to paint with it")
            Button {
                let color = state.foreground
                state.foreground = state.background
                state.background = color
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .accessibilityLabel("Swap foreground and background colors").help("Swap colors")
            Spacer(minLength: 0)
        }
    }
    private func colorBinding(foreground: Bool) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: (foreground ? state.foreground : state.background).nsColor) },
            set: {
                guard let color = EditorColor(native: NSColor($0)) else { return }
                if foreground { state.foreground = color } else { state.background = color }
            })
    }
}
