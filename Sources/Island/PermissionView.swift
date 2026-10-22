import SwiftUI

struct PermissionView: View {
    let request: PermissionRequest
    let theme: Theme
    let queued: Int
    private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        // MARK: wip/character: the character waves on the left while Claude waits.
        HStack(spacing: 0) {
            if CharacterEngine.shared.active {
                // The rig scales its 124 x 120 box to fit, bottom-centred: a 150 pt column with
                // up to 158 pt of height draws the pose at about 1.2x, standing on the button
                // row and clear of the island's rounded bottom corner.
                CharacterRig(darkBackdrop: theme.dark)
                    .frame(width: 150)
                    .frame(maxHeight: 158)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.leading, 16).padding(.bottom, 22)
            }
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(claudeOrange.opacity(0.18))
                    Image(systemName: "sparkle").font(.system(size: 14, weight: .semibold)).foregroundStyle(claudeOrange)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude needs your OK").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.primary)
                    HStack(spacing: 6) {
                        Label(request.project, systemImage: "folder").labelStyle(.titleAndIcon)
                        Text("·")
                        Text(request.toolName)
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.secondary)
                }
                Spacer()
                if queued > 1 {
                    Text("1 of \(queued)").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondary)
                        .padding(.horizontal, 8).frame(height: 20)
                        .background(Capsule().fill(theme.card))
                }
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(ClaudeServer.answerWindow - ctx.date.timeIntervalSince(request.received)))
                    Text("\(left)s")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(left < 10 ? Color.orange : theme.tertiary)
                        .help("If you don't answer, Claude Code will ask in the terminal instead.")
                }
            }

            // Full command / input: scrollable, selectable, never truncated.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(request.summary)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let d = request.detail, !d.isEmpty {
                        Text(d).font(.system(size: 11)).foregroundStyle(theme.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.dark ? Color.black.opacity(0.35) : Color.black.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.cardStroke, lineWidth: 0.5))

            HStack(spacing: 10) {
                let lines = request.summary.split(separator: "\n", omittingEmptySubsequences: false).count
                Text(lines > 8 ? "\(lines) lines · scroll to read all" : "Not answering hands it back to the terminal")
                    .font(.system(size: 10)).foregroundStyle(theme.tertiary).lineLimit(1).minimumScaleFactor(0.85)
                Spacer()
                Button { IslandModel.shared.answer(id: request.id, allow: false) } label: {
                    HStack(spacing: 6) {
                        Text("Deny").font(.system(size: 13, weight: .semibold))
                        Text("⌃⌥N").font(.system(size: 11, weight: .medium)).opacity(0.55)
                    }
                    .foregroundStyle(theme.primary)
                    .padding(.horizontal, 16).frame(height: 32)
                    .background(Capsule().fill(theme.card.opacity(1.8)))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Deny")
                Button { IslandModel.shared.answer(id: request.id, allow: true) } label: {
                    HStack(spacing: 6) {
                        Text("Allow").font(.system(size: 13, weight: .semibold))
                        Text("⌃⌥Y").font(.system(size: 11, weight: .medium)).opacity(0.6)
                    }
                    .foregroundStyle(theme.accentText)
                    .padding(.horizontal, 18).frame(height: 32)
                    .background(Capsule().fill(theme.accentFill))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Allow")
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }
}
