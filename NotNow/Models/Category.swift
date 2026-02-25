import Foundation
import SwiftData
import SwiftUI

@Model
final class Category {
    @Attribute(.unique) var id: UUID
    var name: String
    var icon: String
    var colorHex: Int
    var sortOrder: Int
    var createdAt: Date

    init(name: String, icon: String = "folder.fill", colorHex: Int = 0x6C5CE7, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }

    var color: Color {
        Color(hex: UInt(colorHex))
    }
}
