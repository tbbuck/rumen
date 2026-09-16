import SwiftUI

/// 40px bar along the bottom. Downloads arrive with M4; until then it says nothing is moving.
struct TransfersStrip: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Transfers").font(.sheetUI(12.5, .semibold)).foregroundStyle(Palette.muted)
            StatusDot(color: Palette.muted2)
            Caption("Nothing moving", size: 12.5, color: Palette.muted2)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(Palette.panel)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}
