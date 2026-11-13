import Foundation

/// The runtime a local project needs, judged by the files at its root, and the file that decided it.
public struct ProjectRuntime: Equatable {
    public var runtime: RuntimeSelection
    /// The file that chose the runtime; nil for the shell fallback.
    public var marker: String?

    /// Earlier markers win when a project has several, so a Node frontend with a Go helper stays Node.
    static let markers: [(file: String, runtime: RuntimeSelection)] = [
        ("package.json", RuntimeSelection(name: "node", version: "24")),
        ("pyproject.toml", RuntimeSelection(name: "python", version: "3.14")),
        ("uv.lock", RuntimeSelection(name: "python", version: "3.14")),
        ("requirements.txt", RuntimeSelection(name: "python", version: "3.14")),
        ("setup.py", RuntimeSelection(name: "python", version: "3.14")),
        ("Pipfile", RuntimeSelection(name: "python", version: "3.14")),
        ("go.mod", RuntimeSelection(name: "go", version: "1.27")),
    ]

    public static func detect(_ directory: URL) -> ProjectRuntime? {
        markers.first { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.file).path) }
            .map { ProjectRuntime(runtime: $0.runtime, marker: $0.file) }
    }

    /// The runtime for a task that names none, decided the same way for every client (CLI, MCP, SDK):
    /// a local project's files choose it, and anything else, including a repository URL, gets the shell runtime.
    public static func choose(projectPath: String?) -> ProjectRuntime {
        projectPath.flatMap { detect(URL(fileURLWithPath: $0)) } ?? ProjectRuntime(runtime: RuntimeArtifact.defaultRuntimes[0], marker: nil)
    }

    /// The note `clone` prints, so the choice is never silent.
    public var note: String {
        let reason = marker.map { "detected from \($0)" } ?? "bash, git and ssh; no project file named a language"
        return "Using runtime \(runtime.name):\(runtime.version) (\(reason)); choose another with --runtime."
    }
}
