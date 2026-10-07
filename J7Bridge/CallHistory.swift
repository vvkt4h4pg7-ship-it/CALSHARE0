import Foundation
import Combine

struct CallHistoryItem: Identifiable, Codable {
    let id: UUID
    let number: String
    let date: Date
    let direction: String
}

@MainActor
final class CallHistory: ObservableObject {
    @Published private(set) var items: [CallHistoryItem] = []

    func add(number: String, direction: String) {
        guard !number.isEmpty else { return }
        items.insert(
            CallHistoryItem(id: UUID(), number: number, date: Date(), direction: direction),
            at: 0
        )
        if items.count > 100 { items.removeLast(items.count - 100) }
    }

    func clear() {
        items.removeAll()
    }
}
