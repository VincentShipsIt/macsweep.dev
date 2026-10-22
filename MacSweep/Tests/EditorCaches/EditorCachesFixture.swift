import Foundation

@testable import MacSweepCore

struct EditorCachesFixture {
    let home: URL
    init() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "editor-caches-\(UUID())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        home = EditorCacheMatchers.canonical(path)
    }
    func destroy() { try? FileManager.default.removeItem(at: home) }
    @discardableResult func directory(_ relative: String) throws -> URL {
        let path = home.appending(path: relative)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    func json(_ value: Any, at path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: path)
    }
    @discardableResult func workspace(_ product: String = "Code", id: String, value: String) throws -> URL {
        let path = try directory("Library/Application Support/\(product)/User/workspaceStorage/\(id)")
        try json(["folder": value], at: path.appending(path: "workspace.json"))
        try Data("state".utf8).write(to: path.appending(path: "state.vscdb"))
        return path
    }
    @discardableResult func cache(_ relative: String) throws -> URL {
        let path = try directory(relative)
        try Data("cache".utf8).write(to: path.appending(path: "index"))
        return path
    }
    @discardableResult func extensionVersion(_ version: String, root: String = ".vscode") throws -> URL {
        let path = try directory("\(root)/extensions/fixture.extension-\(version)")
        try json(
            ["publisher": "fixture", "name": "extension", "version": version],
            at: path.appending(path: "package.json"))
        return path
    }
    func registry(_ versions: [String], root: String = ".vscode") throws {
        try json(
            versions.map { version in
                [
                    "identifier": ["id": "fixture.extension"], "version": version,
                    "relativeLocation": "fixture.extension-" + version
                ] as [String: Any]
            }, at: home.appending(path: root + "/extensions/extensions.json"))
    }
    func service(apps: EditorApplicationInventory = .init()) -> EditorCachesService {
        var service = EditorCachesService()
        service.home = home
        service.applications = { apps }
        service.activity = { DevProcessSnapshot() }
        return service
    }
}
