import CanopyCore

/// A made-up item, like a support ticket, for checking the plugin base without a real service.
struct FixtureItem: Sendable, Equatable {
    struct Owner: Sendable, Equatable {
        var name: String
        var initials: String
        var color: PluginColor
    }

    var number: Int
    /// Its folder's name. Two items share one, so the second row's folder gets a suffix.
    var slug: String
    var title: String
    var subtitle: String
    var waiting = false
    var owner: Owner?
    var closed = false

    var id: String { "fx-\(number)" }

    var accessories: [PluginAccessory] {
        var accessories: [PluginAccessory] = []
        if waiting { accessories.append(.dot(.orange, help: "Waiting for a reply")) }
        if closed { accessories.append(.tag("closed", help: "Closed")) }
        if let owner {
            accessories.append(.initials(owner.initials, color: owner.color, help: "Owned by \(owner.name)"))
        }
        return accessories
    }

    var pluginItem: PluginItem {
        PluginItem(id: id, title: title, subtitle: subtitle, accessories: accessories)
    }

    /// What `item.md` holds.
    var markdown: String {
        """
        # \(title)

        \(subtitle)

        A made-up item from Canopy's fixture plugin. Nothing here reaches a real service.

        """
    }

    static let all: [FixtureItem] = [
        FixtureItem(
            number: 1, slug: "alpha", title: "Alpha: sign-in loops back to the start", subtitle: "maya · 2h ago",
            waiting: true, owner: Owner(name: "maya", initials: "MA", color: .blue)),
        FixtureItem(
            number: 2, slug: "beta", title: "Beta: export stops at 10,000 rows", subtitle: "sam · 5h ago",
            owner: Owner(name: "sam", initials: "SA", color: .green)),
        FixtureItem(
            number: 3, slug: "gamma",
            title: "Gamma: search is slow on long queries, and the spinner never stops once the results have come back",
            subtitle: "priya · 1d ago"),
        FixtureItem(
            number: 4, slug: "same", title: "Same folder: one of two items named same", subtitle: "jordan · 3d ago",
            waiting: true),
        FixtureItem(
            number: 5, slug: "same", title: "Same folder: the other item named same", subtitle: "alex · 4d ago",
            owner: Owner(name: "alex", initials: "AL", color: .purple)),
        FixtureItem(
            number: 6, slug: "delta", title: "Delta: footer colors in dark mode", subtitle: "maya · 2w ago",
            owner: Owner(name: "maya", initials: "MA", color: .blue), closed: true),
        FixtureItem(
            number: 7, slug: "epsilon", title: "Epsilon: a duplicate of Alpha", subtitle: "sam · 3w ago",
            closed: true),
    ]
}
