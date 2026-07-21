import Foundation
import SwiftReckless

let missingDirectory = URL(fileURLWithPath: "/nonexistent/swiftreckless-networks")
precondition(RecklessEngine(networkDirectory: missingDirectory) == nil)
print(RecklessNetworkLoader.network.filename)
