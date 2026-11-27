// Test driver: embedded_comment read|remove <file>
import Foundation
let args = CommandLine.arguments
guard args.count == 3 else { print("usage: read|remove file"); exit(2) }
switch args[1] {
case "read": print(EmbeddedComment.read(args[2]) ?? "")
case "remove": do { print(try EmbeddedComment.remove(args[2]) ? "removed" : "none") } catch { print("error: \(error)"); exit(1) }
default: exit(2)
}
