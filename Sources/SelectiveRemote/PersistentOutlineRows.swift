import SwiftUI

/// A small `OutlineGroup` replacement whose disclosure state is controlled by
/// the caller. SwiftUI's built-in outline owns that state internally, so it is
/// lost whenever the application process exits.
struct SelectiveRemotePersistentOutlineRows<Item, Row>: View
where Item: Identifiable, Item.ID: Hashable, Row: View {
    let items: [Item]
    let children: KeyPath<Item, [Item]?>
    @Binding var expandedIDs: Set<Item.ID>
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        ForEach(items) { item in
            if let nested = item[keyPath: children] {
                DisclosureGroup(isExpanded: expansionBinding(for: item.id)) {
                    SelectiveRemotePersistentOutlineRows(
                        items: nested,
                        children: children,
                        expandedIDs: $expandedIDs,
                        row: row
                    )
                } label: {
                    row(item)
                }
            } else {
                row(item)
            }
        }
    }

    private func expansionBinding(for id: Item.ID) -> Binding<Bool> {
        Binding(
            get: { expandedIDs.contains(id) },
            set: { expanded in
                if expanded { expandedIDs.insert(id) }
                else { expandedIDs.remove(id) }
            }
        )
    }
}
