import Foundation
import GRDB
import GRDBQuery
import SwiftUI

extension View {
    /// Wire the shared DatabasePool into GRDBQuery's environment so every
    /// `@Query<…>` below this point observes the real database.
    func installDatabaseContext() -> some View {
        databaseContext(.readWrite { LibraryDatabase.shared })
    }
}
