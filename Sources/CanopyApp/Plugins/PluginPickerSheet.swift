import CanopyCore
import SwiftUI

/// One sheet for every plugin: a search field, the plugin's filter chips, and its items. Picking one opens a row for it,
/// or selects the row it has, as the command in the footer would.
struct PluginPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let section: PluginSection
    let picker: PluginPicker
    @State private var isWorking = false
    @State private var error: String?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        @Bindable var picker = picker
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                PluginTile(info: section.info, size: 20)
                Text(section.info.newRowTitle)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            TextField("Search", text: $picker.text, prompt: Text("Search \(section.info.name)"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focused($isFieldFocused)
                .onKeyPress(.downArrow) {
                    picker.moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    picker.moveSelection(by: -1)
                    return .handled
                }
                .onSubmit(runSelected)
            FilterChips(picker: picker)
            PluginItemList(picker: picker, run: runSelected)
                .frame(maxHeight: .infinity)
                .disabled(isWorking)
            if let error {
                Text((try? AttributedString(markdown: error)) ?? AttributedString(error))
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Text(verbatim: footerCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help("The canopy command that does the same")
                Spacer(minLength: 8)
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle, action: runSelected)
                    .keyboardShortcut(.defaultAction)
                    .disabled(picker.selectedAction == nil || isWorking)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .task { await picker.load() }
        .onAppear { isFieldFocused = true }
    }

    /// What picking the selected item runs, or how to list the items before one is picked.
    private var footerCommand: String {
        picker.selectedAction.map(picker.command(for:)) ?? "canopy plugin items \(section.id)"
    }

    private var primaryTitle: String {
        if case .select? = picker.selectedAction { return "Open Row" }
        return "Create Row"
    }

    private func runSelected() {
        guard !isWorking, let action = picker.selectedAction else { return }
        isWorking = true
        error = nil
        Task {
            error = await model.open(action, in: section)
            isWorking = false
            if error == nil {
                dismiss()
            }
        }
    }
}

/// The plugin's choices, one of which is always on, then its toggles.
private struct FilterChips: View {
    @Bindable var picker: PluginPicker

    var body: some View {
        HStack(spacing: 6) {
            ForEach(picker.filters.choices) { choice in
                Chip(title: choice.title, isOn: picker.choice == choice.id) { picker.choice = choice.id }
            }
            if !picker.filters.choices.isEmpty, !picker.filters.toggles.isEmpty {
                Rectangle().fill(.separator).frame(width: 1, height: 14)
            }
            ForEach(picker.filters.toggles) { toggle in
                let isOn = picker.toggles.contains(toggle.id)
                Chip(title: toggle.title, isOn: isOn) { picker.setToggle(toggle.id, !isOn) }
            }
            Spacer(minLength: 0)
            if picker.isLoading, picker.shownItems != nil {
                ProgressView()
                    .controlSize(.mini)
                    .help("Loading")
            }
        }
    }
}

private struct Chip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Style.body.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(fill, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(isOn ? Color.accentColor.opacity(0.35) : Color(nsColor: .separatorColor))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: Color {
        if isOn { return Color.accentColor.opacity(0.12) }
        return isHovering ? Style.hoverFill : .clear
    }
}

/// The items, a spinner while the first answer loads, or the plugin's error with its fix.
private struct PluginItemList: View {
    @Bindable var picker: PluginPicker
    let run: () -> Void

    var body: some View {
        Group {
            if let error = picker.error {
                ListNote(systemImage: "exclamationmark.triangle.fill", color: .orange, text: error)
            } else if let items = picker.shownItems {
                if items.isEmpty {
                    ListNote(systemImage: nil, color: .secondary, text: "No items match.")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(items) { item in
                                    ItemLine(
                                        item: item, isSelected: picker.selectedItem?.id == item.id,
                                        select: { picker.select(item.id) }, run: run
                                    )
                                    .id(item.id)
                                }
                            }
                            .padding(4)
                        }
                        .onChange(of: picker.selectedItem?.id) {
                            guard let id = picker.selectedItem?.id else { return }
                            proxy.scrollTo(id)
                        }
                    }
                }
            } else {
                ProgressView("Loading…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

private struct ListNote: View {
    let systemImage: String?
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(color)
            }
            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(Style.body)
        .padding(12)
    }
}

/// One item: its title and subtitle, its accessories, and "In row" when it has a row. A click selects it and a double
/// click picks it.
private struct ItemLine: View {
    let item: PluginItem
    let isSelected: Bool
    let select: () -> Void
    let run: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Style.row)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(Style.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            ForEach(Array(item.accessories.enumerated()), id: \.offset) { _, accessory in
                PluginAccessoryView(accessory: accessory)
            }
            if item.row != nil {
                Text("In row")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5)
                    .frame(height: 15)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: Style.tagRadius))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: item.subtitle == nil ? 28 : 42)
        .background(fill, in: RoundedRectangle(cornerRadius: Style.cornerRadius))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .simultaneousGesture(TapGesture(count: 2).onEnded(run))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            select()
            run()
        }
    }

    private var fill: Color {
        if isSelected { return Style.focusedSelectionFill }
        return isHovering ? Style.hoverFill : .clear
    }
}
