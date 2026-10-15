import Foundation
import Testing

/// Inspects packaged documentation without depending on its prose or headings.
enum SkillMarkdown {
    static func documents(in skill: URL) throws -> [String: String] {
        let fm = FileManager.default
        let root = skill.resolvingSymlinksInPath().standardizedFileURL
        let files = try #require(fm.enumerator(at: root, includingPropertiesForKeys: nil))
        var result: [String: String] = [:]
        for case let file as URL in files where file.pathExtension == "md" {
            #expect(try fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular)
            let relativePath = file.standardizedFileURL.pathComponents
                .dropFirst(root.pathComponents.count).joined(separator: "/")
            result[relativePath] = try String(contentsOf: file, encoding: .utf8)
        }
        return result
    }

    static func validateLinks(in plugin: URL) throws {
        let fm = FileManager.default
        let root = plugin.resolvingSymlinksInPath().standardizedFileURL
        let files = try #require(fm.enumerator(at: root, includingPropertiesForKeys: nil))
        let links = try NSRegularExpression(pattern: #"(?<!!)\[[^\]\n]+\]\(([^)\s]+)\)"#)
        var graph: [URL: [URL]] = [:]
        for case let file as URL in files where file.pathExtension == "md" {
            let document = file.standardizedFileURL
            graph[document] = []
            let text = try String(contentsOf: file, encoding: .utf8)
            for link in links.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let range = try #require(Range(link.range(at: 1), in: text))
                let path = String(text[range]).components(separatedBy: "#")[0]
                if path.isEmpty || URL(string: path)?.scheme != nil { continue }
                let target = file.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
                #expect(target.path.hasPrefix(root.path + "/"))
                #expect(try fm.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType == .typeRegular)
                #expect(!(try Data(contentsOf: target)).isEmpty)
                graph[document, default: []].append(target)
            }
        }
        var pending = graph.keys.filter { $0.lastPathComponent == "SKILL.md" }
        #expect(!pending.isEmpty)
        var reached: Set<URL> = []
        while let document = pending.popLast() {
            if reached.insert(document).inserted { pending.append(contentsOf: graph[document] ?? []) }
        }
        #expect(Set(graph.keys).isSubset(of: reached))
    }

    static func recapExample(in text: String) throws -> [String: Any] {
        let example = try #require(text.components(separatedBy: "```sh\n").dropFirst().first)
            .components(separatedBy: "```")[0]
        let body = example.split(separator: "\n").dropFirst().dropLast().joined(separator: "\n")
        return try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }
}
