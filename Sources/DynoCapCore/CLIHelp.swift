import Foundation

struct CLIFlag {
    var name: String
    var value: String?
    var summary: String
}

enum CLICommandGroup {
    case primary
    case advanced
}

struct CLICommandSpec {
    var path: [String]
    var group: CLICommandGroup
    var summary: String
    var usage: String
    var flags: [CLIFlag]
    var examples: [String]
    var discussion: String
    var allowsJSON: Bool = false
}

func usageError(_ message: String) -> DynoCapError {
    DynoCapError(message, exitCode: 2)
}

func rethrowUsage(_ body: () throws -> Void) throws {
    do {
        try body()
    } catch let error as DynoCapError {
        throw usageError(error.message)
    }
}

func cliSpec(_ path: [String]) -> CLICommandSpec? {
    cliCommandSpecs.first { $0.path == path }
}

func knownFlag(_ path: [String], _ name: String) -> Bool {
    cliSpec(path)?.flags.contains { $0.name == name } ?? false
}

/// True when `--verbose` is a CLI flag on an invocation that failed before a command was accepted.
/// Successful parses use `CLIInvocation.verbose`, which understands the guest-argument boundary.
public func invocationRequestsVerbose(_ args: [String]) -> Bool {
    cliFailureOptions(args).verbose
}

public func invocationRequestsNoColor(_ args: [String]) -> Bool {
    args.contains("--no-color") && cliFailureOptions(args).noColor
}

public var helpText: String { commandHelp([]) }

public func commandHelp(_ topic: [String], style: CLIStyle = .plain, width: Int = 80) -> String {
    let layout = HelpLayout(style: style, width: min(96, max(40, width)))
    switch topic {
    case []:
        return topLevelHelp(layout)
    case ["advanced"]:
        return layout.index("dynocap help advanced", commands: cliCommandSpecs.filter { $0.group == .advanced })
    case ["workflow"]:
        return layout.guide()
    case ["task"]:
        return layout.index("dynocap task", commands: cliCommandSpecs.filter { $0.path.first == "task" })
    case ["runtime"]:
        return layout.index("dynocap runtime", commands: cliCommandSpecs.filter { $0.path.first == "runtime" })
    default:
        guard let spec = cliSpec(topic) else {
            return "unknown command \(topic.joined(separator: " "))\n"
        }
        return layout.command(spec)
    }
}

func helpTopic(from positionals: [String], strict: Bool) throws -> [String] {
    if positionals.isEmpty { return [] }
    if ["advanced", "workflow"].contains(positionals[0]) {
        if strict && positionals.count > 1 { throw usageError("unexpected argument \(positionals[1])") }
        return [positionals[0]]
    }
    if positionals[0] == "task" || positionals[0] == "runtime" {
        if positionals.count == 1 { return [positionals[0]] }
        let child = [positionals[0], positionals[1]]
        guard cliSpec(child) != nil else { throw usageError("unknown command \(child.joined(separator: " "))") }
        if strict && positionals.count > 2 { throw usageError("unexpected argument \(positionals[2])") }
        return child
    }
    guard cliSpec([positionals[0]]) != nil else { throw usageError("unknown command \(positionals[0])") }
    if strict && positionals.count > 1 { throw usageError("unexpected argument \(positionals[1])") }
    return [positionals[0]]
}

private let networkChoice = """
Network defaults to none, which attaches no virtual NIC. nat enables unrestricted \
outbound access. filtered allows HTTPS only to the runtime's package registry \
(registry.npmjs.org for node; pypi.org and files.pythonhosted.org for python; \
proxy.golang.org and sum.golang.org for go; none for shell) and, for a repository URL, \
that URL's host. A repository \
URL is cloned inside the guest and requires nat or filtered. An ssh URL requires nat. --git-token-env and --ssh-key are used only for that \
guest fetch and are not imported. TTL defaults to 1800 seconds, including boot, and must \
be an integer from 1 to 86400. There is no unlimited lifetime or automatic renewal.
"""

private let sandboxLifetime = """
Network defaults to none. nat enables unrestricted outbound access. filtered allows HTTPS \
only to registry.npmjs.org and, for a repository URL, that URL's host. TTL defaults to \
1800 seconds, including boot, from 1 to 86400. There is no unlimited lifetime or automatic renewal.
"""

/// `exec` and `task exec` accept exactly these flags, parsed by the same function.
private let execFlags = [
    CLIFlag(name: "--timeout", value: "SEC", summary: "Command deadline in seconds. The default is 60. Timeout exits 124."),
    CLIFlag(name: "--cwd", value: "DIR", summary: "Guest working directory. Project sandboxes use /workspace; raw sandboxes use /."),
    CLIFlag(name: "--env", value: "KEY=VAL", summary: "Environment entry for the guest command. Repeat for more than one."),
    CLIFlag(name: "-i", value: nil, summary: "Forward host stdin until EOF, including when stdin is a terminal."),
    CLIFlag(name: "--interactive", value: nil, summary: "Same as -i. This does not allocate a guest terminal; use -t for that."),
    CLIFlag(name: "--no-input", value: nil, summary: "Do not read host stdin. The guest receives immediate EOF."),
    CLIFlag(name: "-t", value: nil, summary: "Run on a guest terminal sized like this one. Stdin must be a terminal; implies -i."),
    CLIFlag(name: "--tty", value: nil, summary: "Same as -t. Output is one combined terminal stream, not separate stdout and stderr."),
]

private let jsonFlag = CLIFlag(name: "--json", value: nil, summary: "Print the documented result object on stdout; errors use the JSON error object.")

let cliCommandSpecs: [CLICommandSpec] = [
    CLICommandSpec(
        path: ["runtime", "prepare"],
        group: .primary,
        summary: "Build and verify a runtime disk from the dynocap source checkout.",
        usage: "dynocap runtime prepare [REPO] [--runtime NAME:VERSION] [--json]",
        flags: [
            CLIFlag(name: "--json", value: nil, summary: "Print a documented success or error object; suppress human progress."),
            CLIFlag(name: "--runtime", value: "NAME:VERSION", summary: "Runtime to build. The default is shell:1 (bash, git and ssh)."),
        ],
        examples: [
            "dynocap runtime prepare . --runtime node:24",
            "dynocap runtime prepare . --runtime=node:24 --json",
        ],
        discussion: """
        Preparation is explicit. Creating a sandbox does not download or substitute a runtime. \
        Supported selections: node:24 and node:22 with npm; python:3.14 with uv; go:1.27 with Go modules; shell:1 with bash, git and ssh only. \
        The default selection is shell:1 when --runtime is omitted. REPO is the dynocap source tree, defaulting to the current directory.
        Progress goes to human stderr; companion output is saved in a build log. JSON suppresses progress.
        See docs/reference/cli/json-schemas.mdx for result schemas.
        """,
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["clone"],
        group: .primary,
        summary: "Create a named project sandbox from a directory or repository URL.",
        usage: "dynocap clone SOURCE NAME [OPTIONS]",
        flags: [
            CLIFlag(name: "--json", value: nil, summary: "Print a documented success or error object; suppress human progress."),
            CLIFlag(
                name: "--runtime", value: "NAME:VERSION",
                summary: "Runtime the sandbox must use. Otherwise a local project's files choose it, else shell:1 (bash)."),
            CLIFlag(name: "--network", value: "none|nat|filtered", summary: "Sandbox network. The default is none."),
            CLIFlag(name: "--ttl", value: "SEC", summary: "Sandbox lifetime in seconds, from 1 to 86400. The default is 1800."),
            CLIFlag(name: "--cpus", value: "N", summary: "Guest CPUs. The default is 2 for a project sandbox."),
            CLIFlag(name: "--memory", value: "MB", summary: "Guest memory in megabytes, at least 128."),
            CLIFlag(name: "--ref", value: "NAME", summary: "Git branch or tag to fetch for a repository URL."),
            CLIFlag(
                name: "--history", value: "branches|head|none",
                summary: "Git history a local directory brings in. The default is branches; stash, reflogs and unreachable objects never come."),
            CLIFlag(
                name: "--git-token-env",
                value: "VAR",
                summary: "Environment variable holding an HTTPS token for the guest fetch."
            ),
            CLIFlag(name: "--ssh-key", value: "PATH", summary: "Private key used only for an ssh guest fetch."),
        ],
        examples: [
            "dynocap clone ./project demo",
            "dynocap clone ./project demo --runtime node:24 --history head",
            "dynocap clone ./project demo --ttl 600 --cpus 2 --memory 1024 --json",
            "dynocap clone https://github.com/org/repo.git demo --network filtered --ref main",
            "dynocap clone https://github.com/org/repo.git demo --network filtered --git-token-env DYNOCAP_EXAMPLE_TOKEN",
            "dynocap clone git@github.com:org/repo.git demo --network nat --ssh-key /tmp/key",
        ],
        discussion: networkChoice
            + " Names match [A-Za-z0-9][A-Za-z0-9._-]* and cannot start with task- or runtime-."
            + " Creation reports runtime, network, and remaining TTL; expiration discards unexported edits."
            + " Interrupting creation removes that attempt or reports `dynocap rm NAME --force` if cleanup fails."
            + " Other sandboxes and retained results stay."
            + " Human progress uses stderr; JSON suppresses it. See docs/reference/cli/json-schemas.mdx for result schemas.",
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["ls"],
        group: .primary,
        summary: "List sandboxes and retained results.",
        usage: "dynocap ls [--json]",
        flags: [
            CLIFlag(name: "--json", value: nil, summary: "Print the machine-readable listing on stdout."),
        ],
        examples: [
            "dynocap ls",
            "dynocap ls --json",
            "dynocap --json ls",
        ],
        discussion: """
        Human-readable columns are the default, including when redirected. Narrow terminals use wrapped labeled entries.
        TTL is the sandbox deadline; RETENTION is the independent retained-record/result deadline, measured from creation.
        A dash means unavailable or not applicable. JSON is an array with explicit nulls and Unix-second deadlines;
        see docs/reference/cli/json-schemas.mdx. JSON failures use stderr; see docs/reference/cli/errors.mdx.
        Terminal output highlights phases and expired deadlines. Use --no-color to disable highlighting.
        """,
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["doctor"],
        group: .primary,
        summary: "Check that this Mac can run sandboxes, and repair what it can with --fix.",
        usage: "dynocap doctor [PROJECT] [--fix] [--runtime NAME:VERSION] [--json]",
        flags: [
            CLIFlag(name: "--fix", value: nil, summary: "Repair failed checks: restart a stale daemon, build the guest image, prepare the runtime."),
            CLIFlag(name: "--runtime", value: "NAME:VERSION", summary: "Check this runtime instead of the one PROJECT's files call for."),
            CLIFlag(name: "--json", value: nil, summary: "Print the diagnostic report as JSON on stdout."),
        ],
        examples: ["dynocap doctor", "dynocap doctor --fix ./project", "dynocap doctor --fix --runtime python:3.14", "dynocap doctor --json"],
        discussion: """
        Check platform/backend support, signed CLI entitlement, companions, image hashes, the runtime, home access, and daemon connectivity.
        The runtime is the one PROJECT (default: the current directory) uses, judged as clone does: package.json is node:24;
        pyproject.toml, uv.lock, requirements.txt, setup.py, or Pipfile is python:3.14; go.mod is go:1.27. With no project,
        doctor lists prepared runtimes and requires none.
        Terminal reports lead with problems and the runtime. --verbose shows every check. A stopped daemon is normal; a broken or outdated daemon is an error.
        Without --fix, doctor changes nothing: it does not create the home, start a daemon or guest, or download anything.
        With --fix, doctor repairs fixable checks, then checks again. Builds need the dynocap checkout and Go, and download pinned,
        verified inputs. It never restarts a daemon that has running sandboxes. Progress goes to stderr; the report goes to stdout.
        Required check failures exit 1. See docs/how-to/troubleshoot-with-doctor.mdx.
        """,
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["logs"],
        group: .primary,
        summary: "Discover executions or replay their retained output.",
        usage: "dynocap logs NAME_OR_ID [--list | --exec N]",
        flags: [
            CLIFlag(name: "--list", value: nil, summary: "List zero-based execution IDs, outcomes, and log integrity."),
            CLIFlag(name: "--exec", value: "N", summary: "Replay this execution ID; default is the latest journal index."),
        ],
        examples: ["dynocap logs demo", "dynocap logs demo --list", "dynocap logs demo --exec=0"],
        discussion: """
        Replay sends stored stdout to stdout and stored stderr to stderr, without labels or a reconstructed chronology.
        Active, missing, or detectably truncated logs are refused before output. Legacy lengths may be unknown; --list reports that.
        Successful replay exits 0 regardless of the original guest status. --json is unsupported, including with --list.
        Logs are retained with the task after shutdown until its original retention deadline. See docs/tutorials/agent-task-workflow.mdx.
        """
    ),
    CLICommandSpec(
        path: ["inspect"],
        group: .primary,
        summary: "Inspect a sandbox or its retained result.",
        usage: "dynocap inspect NAME_OR_ID [--json]",
        flags: [CLIFlag(name: "--json", value: nil, summary: "Print a documented inspection object on stdout.")],
        examples: ["dynocap inspect demo", "dynocap inspect task-example --json"],
        discussion: """
        Show identity, source, phase, runtime, network, independent sandbox/retention deadlines, and available result artifacts.
        Retention expires seven days after task creation, not seven days after finish. Missing information is reported as unavailable.
        Interrupted work cannot be resumed; unexported edits are discarded when the sandbox is lost.
        Inspection does not run guest commands, export, renew TTL, or extend retention. See docs/reference/cli/json-schemas.mdx for JSON fields.
        """,
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["exec"],
        group: .primary,
        summary: "Run a command in a sandbox.",
        usage: "dynocap exec NAME_OR_ID [OPTIONS] [--] COMMAND [ARGS...]",
        flags: execFlags,
        examples: [
            "dynocap exec demo --timeout 30 --cwd /workspace --env CI=1 -- npm test -- --runInBand",
            "dynocap exec demo -- uname -a",
            "dynocap exec --interactive demo -- cat",
            "dynocap exec --no-input demo -- true",
            "dynocap exec -it demo -- top",
            "dynocap exec --tty demo -- vi /workspace/README.md",
        ],
        discussion: """
        Tokens after -- are the guest command and are preserved unchanged, including values that look \
        like dynocap flags such as --home or --json. A command may also start at the first argument after \
        the sandbox name. The sandbox TTL is not renewed. Project sandboxes start in /workspace when --cwd \
        is omitted. Raw sandboxes start in /. A pipe or file is streamed until EOF and then guest stdin \
        is closed. A terminal is not read unless -i or --interactive is set. --no-input closes guest stdin \
        immediately and cannot be combined with -i. Ctrl-C forwards SIGINT to the guest process group and does not \
        destroy the sandbox. The CLI exits 130 when that signal ends the command. A second Ctrl-C stops waiting. \
        Stdout and stderr stay separate. With -t (or -it), the command gets a controlling guest terminal: the host \
        terminal is put in raw mode and restored on exit, window resizes are forwarded, and Ctrl-C is a keystroke \
        that the guest terminal turns into SIGINT for its foreground job. A second Ctrl-C does not stop waiting \
        in this mode. stdout and stderr arrive combined on stdout, and logs replays that transcript. -t needs a \
        terminal on stdin and cannot be combined with --no-input. TERM defaults to xterm-256color. With -t, a stderr \
        warning comes 5 minutes and 1 minute before the sandbox TTL ends. See docs/how-to/interactive-shells-and-terminal.mdx.
        """
    ),
    CLICommandSpec(
        path: ["shell"],
        group: .primary,
        summary: "Open an interactive shell in a sandbox.",
        usage: "dynocap shell NAME_OR_ID",
        flags: [],
        examples: ["dynocap shell demo", "dynocap shell task-example"],
        discussion: """
        Starts the guest's shell on a guest terminal: root's shell from /etc/passwd when it is executable, \
        otherwise /bin/sh. Bash is not required. Project sandboxes start in /workspace; raw sandboxes start in /. \
        The host terminal is put in raw mode, window resizes are forwarded, and Ctrl-C is a keystroke that \
        interrupts the guest foreground job, not the shell. The host terminal is restored when the shell ends, \
        including when the connection is lost or the sandbox expires. There is no command deadline; the shell \
        lasts until you exit it or the sandbox TTL ends it, and the TTL is not renewed. A stderr warning comes \
        5 minutes and 1 minute before expiry; expiry discards unexported edits. Leaving the shell does \
        not finish or remove the sandbox; run finish or rm --force explicitly. The CLI exits with the shell's \
        status. Stdin and stdout must be terminals; use exec to script commands. --json is unsupported. \
        The session is retained as a terminal transcript for logs. See docs/how-to/interactive-shells-and-terminal.mdx.
        """
    ),
    CLICommandSpec(
        path: ["diff"],
        group: .primary,
        summary: "Print the verified patch for a project sandbox.",
        usage: "dynocap diff NAME_OR_ID",
        flags: [],
        examples: ["dynocap diff demo"],
        discussion: "Terminals highlight the patch for review. Redirect stdout to save the original patch. The sandbox keeps running."
    ),
    CLICommandSpec(
        path: ["finish"],
        group: .primary,
        summary: "Export the result and destroy the sandbox.",
        usage: "dynocap finish NAME_OR_ID [--json]",
        flags: [CLIFlag(name: "--json", value: nil, summary: "Print the documented finish result on stdout.")],
        examples: ["dynocap finish demo", "dynocap finish demo --json"],
        discussion: """
        Finish closes command admission, exports the result, and destroys the sandbox. Human output reports \
        the stopped sandbox, patch path, result directory, actual result retention deadline, and a shell-quoted \
        git apply command. The patch matches the imported baseline, including imported uncommitted changes. \
        Finish does not modify the host checkout. A guest command failure stays visible as phase failed after \
        a successful export. Export and teardown failures are separate errors; retry finish while the sandbox \
        TTL permits. Repeating finish returns the existing result. See docs/tutorials/agent-task-workflow.mdx.
        """,
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["rm"],
        group: .primary,
        summary: "Remove a sandbox and release its name.",
        usage: "dynocap rm NAME_OR_ID [--force] [--purge] [--json]",
        flags: [
            jsonFlag,
            CLIFlag(
                name: "--force",
                value: nil,
                summary: "Discard a live sandbox and its unexported work. Required while the sandbox is starting, running, or finalizing."
            ),
            CLIFlag(
                name: "--purge",
                value: nil,
                summary: "Also delete the managed record, retained logs, and published result. Does not authorize discarding a live sandbox."
            ),
        ],
        examples: [
            "dynocap rm demo",
            "dynocap rm demo --force",
            "dynocap rm demo --purge",
            "dynocap rm demo --force --json",
        ],
        discussion: """
        A live sandbox requires --force because removal discards unexported work. The daemon checks the phase when \
        it mutates the record, so a stale lookup cannot bypass the check. Refusal names the sandbox and explains \
        finish versus discard. Finished, failed, and interrupted sandboxes can be removed without --force. \
        --purge separately deletes the retained result and does not imply --force. There is no confirmation prompt. \
        A failed teardown keeps the record so removal can be retried. See docs/reference/cli/commands.mdx.
        """,
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["run"],
        group: .advanced,
        summary: "Start a raw sandbox that is not a project task.",
        usage: "dynocap run --name NAME [--cpus N] [--memory MB] [--ttl SEC] "
            + "[--network none|nat|filtered] [--boot-timeout SEC] [--json]",
        flags: [
            jsonFlag,
            CLIFlag(name: "--name", value: "NAME", summary: "Sandbox name. Required."),
            CLIFlag(name: "--cpus", value: "N", summary: "Guest CPUs. The default is 1."),
            CLIFlag(name: "--memory", value: "MB", summary: "Guest memory in megabytes, at least 128. The default is 1024."),
            CLIFlag(name: "--ttl", value: "SEC", summary: "Sandbox lifetime in seconds, from 1 to 86400. The default is 1800."),
            CLIFlag(name: "--network", value: "none|nat|filtered", summary: "Sandbox network. The default is none."),
            CLIFlag(name: "--boot-timeout", value: "SEC", summary: "How long to wait for the guest agent. The default is 60."),
        ],
        examples: [
            "dynocap run --name demo --cpus 2 --memory 1024 --ttl 1800 --network none --boot-timeout 60",
            "dynocap run --name demo --json",
        ],
        discussion: sandboxLifetime + " Output reports the phase, network, remaining TTL, and a next exec command, "
            + "like clone. A raw sandbox has no project result: expiry or removal discards everything in it. "
            + "Human progress uses stderr; JSON suppresses it. See docs/reference/cli/json-schemas.mdx.",
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["ps"],
        group: .advanced,
        summary: "List raw sandboxes.",
        usage: "dynocap ps [--json]",
        flags: [CLIFlag(name: "--json", value: nil, summary: "Print the ls JSON array, limited to raw sandboxes.")],
        examples: ["dynocap ps", "dynocap ps --json"],
        discussion: """
        ps is ls limited to raw sandboxes (kind sandbox): the same columns, deadlines, and JSON schema. \
        Use ls for project sandboxes and retained results, and inspect NAME for a raw sandbox's failure message. \
        See docs/reference/cli/json-schemas.mdx.
        """,
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["destroy"],
        group: .advanced,
        summary: "Destroy a sandbox; the same removal as rm, without --purge.",
        usage: "dynocap destroy NAME_OR_ID [--force] [--json]",
        flags: [
            jsonFlag,
            CLIFlag(
                name: "--force",
                value: nil,
                summary: "Discard a live sandbox and its unexported work. Required while the sandbox is starting, running, or finalizing."
            ),
        ],
        examples: ["dynocap destroy demo --force", "dynocap destroy demo --force --json"],
        discussion: """
        destroy sends the same request as rm and follows the same removal intent: the daemon refuses a live sandbox, \
        raw or project, unless --force is given, and a stopped one is removed without it. Retained results are kept; \
        use rm --purge to delete them. Output matches rm. See docs/reference/cli/commands.mdx.
        """,
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["daemon"],
        group: .advanced,
        summary: "Run the per-user daemon in the foreground.",
        usage: "dynocap daemon",
        flags: [],
        examples: ["dynocap daemon"],
        discussion: "Commands that need the daemon start it automatically. daemon keeps it in the foreground for debugging. "
            + "It has no result to print until it stops, so --json is unsupported; its log goes to stdout and stderr."
    ),
    CLICommandSpec(
        path: ["task", "start"],
        group: .advanced,
        summary: "Start a project task from a directory or repository URL.",
        usage: "dynocap task start PATH|URL [OPTIONS]",
        flags: [
            CLIFlag(name: "--json", value: nil, summary: "Print the clone result object; suppress human progress."),
            CLIFlag(name: "--name", value: "NAME", summary: "Friendly name. task- and runtime- prefixes are reserved."),
            CLIFlag(
                name: "--runtime", value: "NAME:VERSION",
                summary: "Runtime the sandbox must use. Otherwise a local project's files choose it, else shell:1 (bash)."),
            CLIFlag(name: "--network", value: "none|nat|filtered", summary: "Sandbox network. The default is none."),
            CLIFlag(name: "--ttl", value: "SEC", summary: "Sandbox lifetime in seconds, from 1 to 86400. The default is 1800."),
            CLIFlag(name: "--cpus", value: "N", summary: "Guest CPUs, at least 1."),
            CLIFlag(name: "--memory", value: "MB", summary: "Guest memory in megabytes, at least 128."),
            CLIFlag(name: "--ref", value: "NAME", summary: "Git branch or tag to fetch for a repository URL."),
            CLIFlag(
                name: "--history", value: "branches|head|none",
                summary: "Git history a local directory brings in. The default is branches; stash, reflogs and unreachable objects never come."),
            CLIFlag(name: "--git-token-env", value: "VAR", summary: "Environment variable holding an HTTPS token for the guest fetch."),
            CLIFlag(name: "--ssh-key", value: "PATH", summary: "Private key used only for an ssh guest fetch."),
        ],
        examples: [
            "dynocap task start ./project --name demo --runtime node:24 --history head",
            "dynocap task start ./project --ttl 600 --cpus 2 --memory 1024 --json",
            "dynocap task start https://github.com/org/repo.git --network filtered --ref main --git-token-env DYNOCAP_EXAMPLE_TOKEN",
            "dynocap task start git@github.com:org/repo.git --network nat --ssh-key /tmp/key",
        ],
        discussion: networkChoice + " Creation, progress, output, and JSON are the same as clone; see docs/reference/cli/json-schemas.mdx."
            + " Prefer clone when choosing a name up front.",
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["task", "exec"],
        group: .advanced,
        summary: "Run a command in a project task; the same as exec.",
        usage: "dynocap task exec ID [OPTIONS] [--] COMMAND [ARGS...]",
        flags: execFlags,
        examples: [
            "dynocap task exec demo -- npm test",
            "dynocap task exec demo --timeout 300 --cwd /workspace --env CI=1 -- npm test",
            "dynocap task exec -i demo -- cat",
            "dynocap task exec --interactive demo -- cat",
            "dynocap task exec --no-input demo -- true",
            "dynocap task exec -t demo -- sh",
            "dynocap task exec --tty demo -- top",
        ],
        discussion: """
        task exec takes exactly the flags of exec, with the same defaults: a 60-second --timeout, /workspace for \
        a project sandbox, piped stdin streamed, separate stdout and stderr unless -t, and the guest's exit status. \
        Everything after -- is the guest command and is preserved unchanged. See docs/how-to/interactive-shells-and-terminal.mdx.
        """
    ),
    CLICommandSpec(
        path: ["task", "finish"],
        group: .advanced,
        summary: "Export a project task and destroy its sandbox.",
        usage: "dynocap task finish ID [--json]",
        flags: [CLIFlag(name: "--json", value: nil, summary: "Print the documented finish result on stdout.")],
        examples: ["dynocap task finish demo", "dynocap task finish demo --json"],
        discussion: "Same export, destruction, and result handoff as finish. The argument is the task id. See docs/tutorials/agent-task-workflow.mdx.",
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["version"],
        group: .advanced,
        summary: "Print version and host virtualization support.",
        usage: "dynocap version [--json]",
        flags: [CLIFlag(name: "--json", value: nil, summary: "Print version, guest architecture, and virtualization support as JSON.")],
        examples: ["dynocap version", "dynocap --version", "dynocap version --json"],
        discussion: "The version flag is also accepted before or after another command and then exits without running it. "
            + "With --json, either form prints the version object. See docs/reference/cli/commands.mdx.",
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["help"],
        group: .advanced,
        summary: "Show help for a command.",
        usage: "dynocap help [COMMAND]",
        flags: [],
        examples: ["dynocap help", "dynocap help clone", "dynocap clone --help", "dynocap help workflow", "dynocap help advanced"],
        discussion: "dynocap help COMMAND and dynocap COMMAND --help show the same command help. Help is text only; "
            + "--json is unsupported. See docs/reference/cli/commands.mdx for every command's output and JSON support."
    ),
]

/// The repository workflow, shared word for word with the README quick start (checked by a test).
let quickStart = """
dynocap doctor --fix ./project                     # builds the guest image and the runtime ./project uses
dynocap clone ./project deps --network filtered    # explicit network: HTTPS to the runtime's registry only
dynocap exec deps --timeout 300 -- npm ci          # a node project; see RUNTIMES for the others
dynocap finish deps                                # exports the result and saves the package cache
dynocap clone ./project demo                       # offline by default: no network device
dynocap exec demo -- npm ci --offline              # installs from the saved package cache
dynocap exec demo -- npm test
dynocap shell demo
dynocap ls
dynocap inspect demo
dynocap logs demo
dynocap diff demo
dynocap finish demo                                # exports the patch, then destroys the sandbox
dynocap rm demo
dynocap rm deps
"""

/// Per-runtime equivalents of the quick start's npm commands.
let runtimesHelp = """
The project's files choose the runtime; --runtime overrides it. Filtered egress reaches only its registry.
  RUNTIME       CHOSEN BY         FILTERED INSTALL    OFFLINE INSTALL
  node:24       package.json      npm ci              npm ci --offline
  node:22       --runtime only    npm ci              npm ci --offline
  python:3.14   pyproject.toml    uv sync --frozen    uv sync --offline --frozen
  go:1.27       go.mod            go mod download     go mod download
  shell:1       anything else     bash, git and ssh only; no package manager or cache
"""

private func topLevelHelp(_ layout: HelpLayout) -> String {
    let title = layout.style.paint("dynocap \(DynoCapInfo.version)", .heading)
    let commands = cliCommandSpecs.filter { $0.group == .primary }
    return layout.page([
        title + " · Local Linux sandboxes on macOS",
        layout.section("USAGE", [layout.syntax("dynocap <command> [options]")]),
        layout.commandIndex(commands),
        layout.section("START HERE", [
            layout.syntax("dynocap doctor --fix ./project"),
            layout.syntax("dynocap help <command>"),
            layout.syntax("dynocap help workflow"),
            layout.syntax("dynocap help advanced"),
        ]),
        layout.globals,
    ])
}

private struct HelpLayout {
    let style: CLIStyle
    let width: Int

    func page(_ blocks: [String]) -> String { blocks.joined(separator: "\n\n") + "\n" }

    func section(_ title: String, _ rows: [String]) -> String {
        ([style.paint(title, .heading)] + rows.map { "  " + $0 }).joined(separator: "\n")
    }

    func syntax(_ text: String) -> String {
        let parts = text.components(separatedBy: " #")
        let command = parts[0].components(separatedBy: " ").map { word in
            if word == "dynocap" { return style.paint(word, .heading) }
            if word.hasPrefix("-") || word.hasPrefix("[-") { return style.paint(word, .accent) }
            return word
        }.joined(separator: " ")
        guard parts.count > 1 else { return command }
        return command + style.paint(" #" + parts.dropFirst().joined(separator: " #"), .muted)
    }

    var globals: String {
        section("GLOBAL OPTIONS", [
            syntax("--home PATH   --no-color   --verbose"),
            syntax("-h, --help    --version"),
        ])
    }

    func commandIndex(_ commands: [CLICommandSpec]) -> String {
        let column = (commands.map { $0.path.joined(separator: " ").count }.max() ?? 0) + 2
        let rows = commands.map { spec in
            let name = spec.path.joined(separator: " ")
            let indent = String(repeating: " ", count: column)
            let summary = wrapped(spec.summary, limit: width - column - 2)
                .joined(separator: "\n  " + indent)
            return style.paint(name, .accent) + String(repeating: " ", count: column - name.count) + summary
        }
        return section("COMMANDS", rows)
    }

    func index(_ title: String, commands: [CLICommandSpec]) -> String {
        page([
            style.paint(title, .heading),
            commandIndex(commands),
            section("HELP", [syntax("dynocap help <command>")]),
            globals,
        ])
    }

    func guide() -> String {
        page([
            style.paint("dynocap help workflow", .heading),
            section("WORKFLOW", quickStart.split(separator: "\n").map { syntax(String($0)) }),
            section("RUNTIMES", runtimesHelp.split(separator: "\n").map(String.init)),
        ])
    }

    func command(_ spec: CLICommandSpec) -> String {
        var blocks = [
            style.paint("dynocap " + spec.path.joined(separator: " "), .heading),
            wrapped(spec.summary, limit: width).joined(separator: "\n"),
            section("USAGE", [syntax(spec.usage)]),
            section("EXAMPLES", spec.examples.map(syntax)),
        ]
        if !spec.flags.isEmpty {
            let rows = spec.flags.flatMap { flag in
                let label = flag.value.map { "\(flag.name) \($0)" } ?? flag.name
                return [style.paint(label, .accent)] + wrapped(flag.summary, limit: width - 4).map { "  " + $0 }
            }
            blocks.append(section("OPTIONS", rows))
        }
        blocks.append(section("DETAILS", wrapped(spec.discussion, limit: width - 2)))
        blocks.append(globals)
        return page(blocks)
    }

    private func wrapped(_ text: String, limit: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            if line.isEmpty {
                line = String(word)
            } else if line.count + word.count + 1 <= limit {
                line += " " + word
            } else {
                lines.append(line)
                line = String(word)
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }
}
