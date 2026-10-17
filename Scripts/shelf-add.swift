// Adds files to Glance's Shelf as bookmarks (references; the files are not moved, copied
// or modified). Run only while Glance is NOT running, e.g.:
//   swiftc -O Scripts/shelf-add.swift -o /tmp/shelf-add && /tmp/shelf-add file1 file2 ...
import Foundation
let store = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Glance/shelf.json")
var list: [[String: Any]] = []
if let d = try? Data(contentsOf: store), let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] { list = a }
var added: [[String: Any]] = []
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else { print("missing: \(path)"); continue }
    if list.contains(where: { ($0["lastPath"] as? String) == path }) { print("already on shelf: \(path)"); continue }
    var item: [String: Any] = ["id": UUID().uuidString, "kind": "file", "name": url.lastPathComponent,
                               "lastPath": path, "date": Date().timeIntervalSinceReferenceDate]
    if let bm = try? url.bookmarkData() { item["bookmark"] = bm.base64EncodedString() }
    added.append(item)
    print("added: \(url.lastPathComponent)")
}
list = added + list   // given order first, in the order passed
let data = try JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted])
FileManager.default.createFile(atPath: store.path, contents: data, attributes: [.posixPermissions: 0o600])
