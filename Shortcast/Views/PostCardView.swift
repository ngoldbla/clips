import SwiftUI

/// One editable result card for a single platform.
struct PostCardView: View {

    @Binding var variant: PostVariant

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 16) {
                labeledField("HOOK") {
                    editor($variant.hook, minHeight: 58)
                }
                labeledField("CAPTION") {
                    editor($variant.summary, minHeight: 168)
                }
                labeledField("HASHTAGS") {
                    editor(hashtagsBinding, minHeight: 66)
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: variant.platform.symbolName)
            Text(variant.platform.displayName)
                .fontWeight(.semibold)
            Spacer()
        }
        .font(.subheadline)
        .foregroundStyle(variant.platform.tint)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(variant.platform.tint.opacity(0.12))
    }

    private func labeledField(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)
            content()
        }
    }

    private func editor(_ text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: minHeight)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
    }

    /// Hashtags edited as a free `#a #b #c` string, re-split on every change.
    private var hashtagsBinding: Binding<String> {
        Binding(
            get: { variant.hashtags.map { "#\($0)" }.joined(separator: " ") },
            set: { newValue in
                variant.hashtags = newValue
                    .split(whereSeparator: { " ,\n".contains($0) })
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
                    .filter { !$0.isEmpty }
            })
    }
}
