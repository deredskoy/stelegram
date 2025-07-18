Here’s the AppConfiguration struct with the conflicts removed and disableSearch defaulting to true:

import Foundation
import Postbox

public struct AppConfiguration: Codable, Equatable {
    public var data: JSON?
    public var hash: Int32
    // Search functionality is disabled by default.
    // Remote configuration can toggle this flag by setting `ios_disable_search`.
    public static var disableSearch: Bool = true
    
    public static var defaultValue: AppConfiguration {
        return AppConfiguration(data: nil, hash: 0)
    }
    
    init(data: JSON?, hash: Int32) {
        self.data = data
        self.hash = hash
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)
        self.data = try container.decodeIfPresent(JSON.self, forKey: "data")
        self.hash = (try container.decodeIfPresent(Int32.self, forKey: "storedHash")) ?? 0
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        try container.encodeIfPresent(self.data, forKey: "data")
        try container.encode(self.hash, forKey: "storedHash")
    }
}