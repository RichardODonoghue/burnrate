import SwiftUI

/// Rounded card surface shared by every pane, so the usage dashboard and the
/// settings panes read as one app.
///
/// Deliberately not `GroupBox`: in these layouts it drew broken/partial
/// outlines depending on the content size.
struct Card<Content: View>: View {
    private let title: String?
    private let icon: String?
    private let subtleTitle: Bool
    private let footnote: String?
    @ViewBuilder private let content: Content

    /// - Parameters:
    ///   - title: section title; omit for a plain surface.
    ///   - icon: SF Symbol shown before the title.
    ///   - subtleTitle: small grey caption instead of a headline (stat cards).
    ///   - footnote: explanatory line shown under the content.
    init(
        _ title: String? = nil,
        icon: String? = nil,
        subtleTitle: Bool = false,
        footnote: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.subtleTitle = subtleTitle
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon)
                    }
                    Text(title)
                        .fontWeight(subtleTitle ? .medium : .semibold)
                        .font(subtleTitle ? .caption : .headline)
                }
                .foregroundStyle(subtleTitle ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            content
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

/// Scrollable, padded stack of cards — the scaffold every pane uses.
struct CardPane<Content: View>: View {
    @ViewBuilder private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Label on the left, control on the right — the standard settings row.
struct CardRow<Control: View>: View {
    private let label: String
    @ViewBuilder private let control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer(minLength: 12)
            control
        }
    }
}
