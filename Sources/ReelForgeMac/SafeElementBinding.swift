import SwiftUI

func safeElementBinding<Element, ID: Equatable>(
    fallback: Element,
    elements: Binding<[Element]>,
    id: KeyPath<Element, ID>
) -> Binding<Element> {
    let elementID = fallback[keyPath: id]

    return Binding(
        get: {
            elements.wrappedValue.first { $0[keyPath: id] == elementID } ?? fallback
        },
        set: { updated in
            guard let index = elements.wrappedValue.firstIndex(where: {
                $0[keyPath: id] == elementID
            }) else {
                return
            }
            elements.wrappedValue[index] = updated
        }
    )
}
