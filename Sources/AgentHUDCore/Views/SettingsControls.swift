import SwiftUI

/// A card of rows with hairline separators, plus optional header and footer text.
struct SettingsSection<Content: View>: View {
    var header: String?
    var footer: String?
    @ViewBuilder let content: Content

    init(header: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            }
            _VariadicView.Tree(SeparatedRows()) { content }
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            if let footer {
                Text(footer)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private struct SeparatedRows: _VariadicView_MultiViewRoot {
        @ViewBuilder
        func body(children: _VariadicView.Children) -> some View {
            VStack(spacing: 0) {
                ForEach(children) { child in
                    child
                    if child.id != children.last?.id {
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }
    }
}

/// One label-left, control-right settings row.
struct SettingsRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
            Spacer()
            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.blue)
            .controlSize(.small)
    }
}
