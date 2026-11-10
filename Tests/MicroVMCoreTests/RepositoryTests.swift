import XCTest

@testable import MicroVMCore

final class RepositoryTests: XCTestCase {
    func testPublicURLRequiresNATAndClonesInTheGuest() throws {
        var command = TaskCommand(op: "start")
        command.repositoryUrl = "https://github.com/org/repo.git"
        XCTAssertThrowsError(try TaskSourceResolver.resolve(command)) { error in
            XCTAssertEqual(String(describing: error), "repository fetch requires --network nat")
        }
        command.network = .nat
        command.ref = "main"
        guard case .guestClone(let repo) = try TaskSourceResolver.resolve(command) else {
            return XCTFail("expected guest clone")
        }
        XCTAssertEqual(repo.url, "https://github.com/org/repo.git")
        XCTAssertEqual(repo.ref, "main")
        XCTAssertNil(repo.token)
        let argv = GuestGit.clone(url: repo.url, ref: repo.ref)
        XCTAssertTrue(argv.contains("--branch"))
        XCTAssertTrue(argv.contains("main"))
        XCTAssertFalse(argv.contains("--no-checkout"))
        XCTAssertTrue(argv.contains("core.hooksPath=/dev/null"))
        XCTAssertTrue(argv.contains("credential.helper="))
        XCTAssertTrue(argv.contains("protocol.file.allow=never"))
        XCTAssertEqual(argv.suffix(3), ["--", repo.url, "/workspace"])
        command.network = .filtered
        guard case .guestClone = try TaskSourceResolver.resolve(command) else {
            return XCTFail("filtered public clone")
        }
        let sha = "d6de9f4b36f175b11586f89339689c1fe3c88805"
        let commit = GuestGit.clone(url: repo.url, ref: sha)
        XCTAssertFalse(commit.contains("--branch"))
        XCTAssertTrue(commit.contains("--no-checkout"))
        XCTAssertTrue(commit.contains("--no-recurse-submodules"))
        XCTAssertEqual(commit.suffix(3), ["--", repo.url, "/workspace"])
        let fetch = GuestGit.fetchCommit(sha)
        XCTAssertTrue(fetch.contains("fetch"))
        XCTAssertTrue(fetch.contains(sha))
        XCTAssertTrue(fetch.contains("core.hooksPath=/dev/null"))
        XCTAssertTrue(fetch.contains("--no-recurse-submodules"))
        XCTAssertTrue(fetch.contains("credential.helper="))
    }

    func testCredentialSelectsGuestFetchAndRecordOmitsIt() throws {
        var command = TaskCommand(op: "start")
        command.repositoryUrl = "https://github.com/org/private.git"
        command.gitToken = "secret-token"
        XCTAssertThrowsError(try TaskSourceResolver.resolve(command)) { error in
            XCTAssertEqual(String(describing: error), "repository fetch requires --network nat")
        }
        command.network = .filtered
        guard case .guestClone(let repo) = try TaskSourceResolver.resolve(command) else {
            return XCTFail("expected guest fetch")
        }
        XCTAssertEqual(repo.token, "secret-token")
        let argv = GuestGit.privateFetch(url: repo.url, ref: repo.ref)
        XCTAssertEqual(argv, ["/usr/local/bin/microvm-agent", "fetch", "/workspace", repo.url, ""])
        XCTAssertFalse(argv.joined(separator: "\n").contains("secret-token"))
        XCTAssertEqual(try GuestGit.secretEnv(repo), ["MICROVM_GIT_TOKEN=secret-token"])
        let console = "Authorization: Bearer secret-token\nfatal: authentication failed"
        XCTAssertEqual(
            redactSecrets(console, secrets: ["secret-token"]),
            "Authorization: Bearer <redacted>\nfatal: authentication failed")
        var record = TaskRecord(
            id: "task-test", phase: "running", runtimeDigest: "digest", createdAtUnix: 1, expiresAtUnix: 2,
            sourceUrl: repo.url, network: .none)
        record.sourceRevision = String(repeating: "a", count: 40)
        let encoded = String(data: try JSONEncoder().encode(record), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("secret-token"))
        XCTAssertTrue(encoded.contains("sourceUrl"))
        XCTAssertTrue(encoded.contains("github.com"))
        let descriptor = String(data: try JSONEncoder().encode(TaskDescriptor(record)), encoding: .utf8) ?? ""
        XCTAssertFalse(descriptor.contains("secret-token"))
        XCTAssertTrue(descriptor.contains(record.sourceRevision ?? ""))
    }

    func testRejectedURLsAndMismatchedCredentials() {
        let rejected = [
            "file:///tmp/repo.git", "http://github.com/org/repo.git", "ext::sh", "https://token@github.com/org/repo.git",
            "ssh://token@github.com/org/repo.git",
        ]
        for url in rejected {
            var command = TaskCommand(op: "start")
            command.repositoryUrl = url
            command.network = .nat
            XCTAssertThrowsError(try TaskSourceResolver.resolve(command), url)
        }
        var both = TaskCommand(op: "start")
        both.repositoryUrl = "https://github.com/org/repo.git"
        both.gitToken = "secret-token"
        both.sshKeyPath = "/tmp/key"
        XCTAssertThrowsError(try TaskSourceResolver.resolve(both))
        var ssh = TaskCommand(op: "start")
        ssh.repositoryUrl = "git@github.com:org/repo.git"
        XCTAssertThrowsError(try TaskSourceResolver.resolve(ssh)) { error in
            XCTAssertEqual(String(describing: error), "ssh repository requires --ssh-key")
        }
        ssh.sshKeyPath = "/tmp/id_ed25519"
        XCTAssertThrowsError(try TaskSourceResolver.resolve(ssh)) { error in
            XCTAssertEqual(String(describing: error), "repository fetch requires --network nat")
        }
        ssh.network = .filtered
        XCTAssertThrowsError(try TaskSourceResolver.resolve(ssh)) { error in
            XCTAssertEqual(String(describing: error), "an ssh repository requires --network nat")
        }
        ssh.network = .nat
        guard case .guestClone(let repo) = try? TaskSourceResolver.resolve(ssh) else {
            return XCTFail("expected ssh guest fetch")
        }
        XCTAssertEqual(repo.kind, "ssh")
        XCTAssertNil(repo.token)
        let argv = GuestGit.privateFetch(url: repo.url, ref: nil)
        XCTAssertFalse(argv.joined(separator: "\n").contains("id_ed25519"))
        XCTAssertEqual(argv.last, "")
    }

    func testSSHKeyBytesStayInTheFetchEnvironment() throws {
        let key = FileManager.default.temporaryDirectory.appendingPathComponent("microvm-key-" + UUID().uuidString)
        let material = "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret-key-material\n-----END OPENSSH PRIVATE KEY-----\n"
        try Data(material.utf8).write(to: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        defer { try? FileManager.default.removeItem(at: key) }
        var command = TaskCommand(op: "start")
        command.repositoryUrl = "git@github.com:org/private.git"
        command.sshKeyPath = key.path
        command.network = .nat
        guard case .guestClone(let repo) = try TaskSourceResolver.resolve(command) else {
            return XCTFail("expected guest fetch")
        }
        let argv = GuestGit.privateFetch(url: repo.url, ref: nil).joined(separator: "\n")
        let env = try GuestGit.secretEnv(repo)
        XCTAssertFalse(argv.contains("secret-key-material"))
        XCTAssertEqual(env, ["MICROVM_SSH_KEY=\(material)"])
        let record = TaskRecord(
            id: "task-test", phase: "starting", runtimeDigest: "digest", createdAtUnix: 1, expiresAtUnix: 2,
            sourceUrl: repo.url, network: .nat)
        let encoded = String(data: try JSONEncoder().encode(record), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("secret-key-material"))
        XCTAssertFalse(encoded.contains(key.path))
    }

    func testCLIReadsTokenFromTheNamedVariable() throws {
        setenv("MICROVM_TEST_TOKEN", "secret-token", 1)
        defer { unsetenv("MICROVM_TEST_TOKEN") }
        let invocation = try parseCommand([
            "microvm", "task", "start", "https://github.com/org/private.git", "--git-token-env", "MICROVM_TEST_TOKEN",
            "--ref", "release",
        ])
        guard case .task(let command) = invocation.command else { return XCTFail("expected task") }
        XCTAssertEqual(command.repositoryUrl, "https://github.com/org/private.git")
        XCTAssertNil(command.projectPath)
        XCTAssertEqual(command.gitToken, "secret-token")
        XCTAssertEqual(command.ref, "release")
        XCTAssertThrowsError(
            try parseCommand(["microvm", "task", "start", "https://github.com/org/repo.git", "--git-token-env", "MICROVM_MISSING_TOKEN"])
        )
        let directory = try parseCommand(["microvm", "task", "start", "/tmp/project", "--runtime", "node:22"])
        guard case .task(let local) = directory.command else { return XCTFail("expected directory task") }
        XCTAssertEqual(local.projectPath, "/tmp/project")
        XCTAssertNil(local.repositoryUrl)
    }
}
