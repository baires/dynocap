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

func usageError(_ message: String) -> MicroVMError {
    MicroVMError(message, exitCode: 2)
}

func rethrowUsage(_ body: () throws -> Void) throws {
    do {
        try body()
    } catch let error as MicroVMError {
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

public var helpText: String { commandHelp([]) }

public func commandHelp(_ topic: [String]) -> String {
    switch topic {
    case []:
        return topLevelHelp()
    case ["advanced"]:
        return advancedHelp()
    case ["task"]:
        return groupHelp(
            "task",
            "Project-task operations that overlap clone, exec, and finish.",
            [["task", "start"], ["task", "exec"], ["task", "finish"]]
        )
    case ["runtime"]:
        return groupHelp(
            "runtime",
            "Prepare the runtime disk a sandbox expects. Clone does not download one for you.",
            [["runtime", "prepare"]]
        )
    default:
        guard let spec = cliSpec(topic) else {
            return "unknown command \(topic.joined(separator: " "))\n"
        }
        return render(spec)
    }
}

func helpTopic(from positionals: [String], strict: Bool) throws -> [String] {
    if positionals.isEmpty { return [] }
    if positionals[0] == "advanced" {
        if strict && positionals.count > 1 { throw usageError("unexpected argument \(positionals[1])") }
        return ["advanced"]
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
outbound access. filtered allows HTTPS only to registry.npmjs.org and, for a repository \
URL, that URL's host. A repository URL is cloned inside the guest and requires nat or \
filtered. An ssh URL requires nat. --git-token-env and --ssh-key are used only for that \
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
        summary: "Build and verify a runtime disk from the microvm source checkout.",
        usage: "microvm runtime prepare [REPO] [--runtime NAME:VERSION] [--json]",
        flags: [
            CLIFlag(name: "--json", value: nil, summary: "Print a documented success or error object; suppress human progress."),
            CLIFlag(name: "--runtime", value: "NAME:VERSION", summary: "Runtime to build. The default is node:22."),
        ],
        examples: [
            "microvm runtime prepare . --runtime node:22",
            "microvm runtime prepare . --runtime=node:22 --json",
        ],
        discussion: """
        Preparation is explicit. Creating a sandbox does not download or substitute a runtime. \
        The default selection is node:22 when --runtime is omitted. REPO is the microvm source tree, defaulting to the current directory.
        Progress goes to human stderr; companion output is saved in a build log. JSON suppresses progress.
        See docs/reference/cli/json-schemas.mdx for result schemas.
        """,
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["clone"],
        group: .primary,
        summary: "Create a named project sandbox from a directory or repository URL.",
        usage: "microvm clone SOURCE NAME [OPTIONS]",
        flags: [
            CLIFlag(name: "--json", value: nil, summary: "Print a documented success or error object; suppress human progress."),
            CLIFlag(name: "--runtime", value: "NAME:VERSION", summary: "Runtime the sandbox must use, such as node:22."),
            CLIFlag(name: "--network", value: "none|nat|filtered", summary: "Sandbox network. The default is none."),
            CLIFlag(name: "--ttl", value: "SEC", summary: "Sandbox lifetime in seconds, from 1 to 86400. The default is 1800."),
            CLIFlag(name: "--cpus", value: "N", summary: "Guest CPUs. The default is 2 for a project sandbox."),
            CLIFlag(name: "--memory", value: "MB", summary: "Guest memory in megabytes, at least 128."),
            CLIFlag(name: "--ref", value: "NAME", summary: "Git branch or tag to fetch for a repository URL."),
            CLIFlag(
                name: "--git-token-env",
                value: "VAR",
                summary: "Environment variable holding an HTTPS token for the guest fetch."
            ),
            CLIFlag(name: "--ssh-key", value: "PATH", summary: "Private key used only for an ssh guest fetch."),
        ],
        examples: [
            "microvm clone ./project demo --runtime node:22 --network none --ttl 1800 --cpus 2 --memory 1024 --ref main --json",
            "microvm clone git@github.com:org/repo.git demo --network nat --git-token-env MICROVM_EXAMPLE_TOKEN --ssh-key /tmp/key",
        ],
        discussion: networkChoice
            + " Names match [A-Za-z0-9][A-Za-z0-9._-]* and cannot start with task- or runtime-."
            + " Creation reports runtime, network, and remaining TTL; expiration discards unexported edits."
            + " Interrupting creation removes that attempt or reports `microvm rm NAME --force` if cleanup fails."
            + " Other sandboxes and retained results stay."
            + " Human progress uses stderr; JSON suppresses it. See docs/reference/cli/json-schemas.mdx for result schemas.",
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["ls"],
        group: .primary,
        summary: "List sandboxes and retained results.",
        usage: "microvm ls [--json]",
        flags: [
            CLIFlag(name: "--json", value: nil, summary: "Print the machine-readable listing on stdout."),
        ],
        examples: [
            "microvm ls",
            "microvm ls --json",
            "microvm --json ls",
        ],
        discussion: """
        Human-readable columns are the default, including when redirected. Narrow terminals use wrapped labeled entries.
        TTL is the sandbox deadline; RETENTION is the independent retained-record/result deadline, measured from creation.
        A dash means unavailable or not applicable. JSON is an array with explicit nulls and Unix-second deadlines;
        see docs/reference/cli/json-schemas.mdx. JSON failures use stderr; see docs/reference/cli/errors.mdx.
        Human output is plain text without color or paging.
        """,
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["doctor"],
        group: .primary,
        summary: "Diagnose host prerequisites without starting or repairing anything.",
        usage: "microvm doctor [--runtime NAME:VERSION] [--json]",
        flags: [
            CLIFlag(name: "--runtime", value: "NAME:VERSION", summary: "Check this runtime selection; defaults to node:22."),
            CLIFlag(name: "--json", value: nil, summary: "Print the diagnostic report as JSON on stdout."),
        ],
        examples: ["microvm doctor", "microvm doctor --runtime node:22 --json"],
        discussion: """
        Check platform/backend support, signed CLI entitlement, companions, image hashes, selected runtime, home access, and daemon connectivity.
        A stopped daemon is normal; a broken listener or held daemon lock without a socket is an error.
        Findings use stdout in both modes. Required check failures exit 1; valid setup with a stopped daemon exits 0.
        Does not create the home, start a daemon or guest, download, prepare, or repair artifacts. See docs/how-to/troubleshoot-with-doctor.mdx.
        """,
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["logs"],
        group: .primary,
        summary: "Discover executions or replay their retained output.",
        usage: "microvm logs NAME_OR_ID [--list | --exec N]",
        flags: [
            CLIFlag(name: "--list", value: nil, summary: "List zero-based execution IDs, outcomes, and log integrity."),
            CLIFlag(name: "--exec", value: "N", summary: "Replay this execution ID; default is the latest journal index."),
        ],
        examples: ["microvm logs demo", "microvm logs demo --list", "microvm logs demo --exec=0"],
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
        usage: "microvm inspect NAME_OR_ID [--json]",
        flags: [CLIFlag(name: "--json", value: nil, summary: "Print a documented inspection object on stdout.")],
        examples: ["microvm inspect demo", "microvm inspect task-example --json"],
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
        usage: "microvm exec NAME_OR_ID [OPTIONS] [--] COMMAND [ARGS...]",
        flags: execFlags,
        examples: [
            "microvm exec demo --timeout 30 --cwd /workspace --env CI=1 -- npm test -- --runInBand",
            "microvm exec demo -- uname -a",
            "microvm exec --interactive demo -- cat",
            "microvm exec --no-input demo -- true",
            "microvm exec -it demo -- top",
            "microvm exec --tty demo -- vi /workspace/README.md",
        ],
        discussion: """
        Tokens after -- are the guest command and are preserved unchanged, including values that look \
        like microvm flags such as --home or --json. A command may also start at the first argument after \
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
        usage: "microvm shell NAME_OR_ID",
        flags: [],
        examples: ["microvm shell demo", "microvm shell task-example"],
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
        usage: "microvm diff NAME_OR_ID",
        flags: [],
        examples: ["microvm diff demo"],
        discussion: "The patch is the command's stdout. diff does not destroy the sandbox."
    ),
    CLICommandSpec(
        path: ["finish"],
        group: .primary,
        summary: "Export the result and destroy the sandbox.",
        usage: "microvm finish NAME_OR_ID [--json]",
        flags: [CLIFlag(name: "--json", value: nil, summary: "Print the documented finish result on stdout.")],
        examples: ["microvm finish demo", "microvm finish demo --json"],
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
        usage: "microvm rm NAME_OR_ID [--force] [--purge] [--json]",
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
            "microvm rm demo",
            "microvm rm demo --force",
            "microvm rm demo --purge",
            "microvm rm demo --force --json",
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
        usage: "microvm run --name NAME [--cpus N] [--memory MB] [--ttl SEC] "
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
            "microvm run --name demo --cpus 2 --memory 1024 --ttl 1800 --network none --boot-timeout 60",
            "microvm run --name demo --json",
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
        usage: "microvm ps [--json]",
        flags: [CLIFlag(name: "--json", value: nil, summary: "Print the ls JSON array, limited to raw sandboxes.")],
        examples: ["microvm ps", "microvm ps --json"],
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
        usage: "microvm destroy NAME_OR_ID [--force] [--json]",
        flags: [
            jsonFlag,
            CLIFlag(
                name: "--force",
                value: nil,
                summary: "Discard a live sandbox and its unexported work. Required while the sandbox is starting, running, or finalizing."
            ),
        ],
        examples: ["microvm destroy demo --force", "microvm destroy demo --force --json"],
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
        usage: "microvm daemon",
        flags: [],
        examples: ["microvm daemon"],
        discussion: "Commands that need the daemon start it automatically. daemon keeps it in the foreground for debugging. "
            + "It has no result to print until it stops, so --json is unsupported; its log goes to stdout and stderr."
    ),
    CLICommandSpec(
        path: ["task", "start"],
        group: .advanced,
        summary: "Start a project task from a directory or repository URL.",
        usage: "microvm task start PATH|URL [OPTIONS]",
        flags: [
            CLIFlag(name: "--json", value: nil, summary: "Print the clone result object; suppress human progress."),
            CLIFlag(name: "--name", value: "NAME", summary: "Friendly name. task- and runtime- prefixes are reserved."),
            CLIFlag(name: "--runtime", value: "NAME:VERSION", summary: "Runtime the sandbox must use, such as node:22."),
            CLIFlag(name: "--network", value: "none|nat|filtered", summary: "Sandbox network. The default is none."),
            CLIFlag(name: "--ttl", value: "SEC", summary: "Sandbox lifetime in seconds, from 1 to 86400. The default is 1800."),
            CLIFlag(name: "--cpus", value: "N", summary: "Guest CPUs, at least 1."),
            CLIFlag(name: "--memory", value: "MB", summary: "Guest memory in megabytes, at least 128."),
            CLIFlag(name: "--ref", value: "NAME", summary: "Git branch or tag to fetch for a repository URL."),
            CLIFlag(name: "--git-token-env", value: "VAR", summary: "Environment variable holding an HTTPS token for the guest fetch."),
            CLIFlag(name: "--ssh-key", value: "PATH", summary: "Private key used only for an ssh guest fetch."),
        ],
        examples: [
            "microvm task start /tmp/project --name demo --runtime node:22 --network none --ttl 1800 "
                + "--cpus 2 --memory 1024 --ref main --ssh-key /tmp/key --git-token-env MICROVM_EXAMPLE_TOKEN",
            "microvm task start /tmp/project --name demo --json",
        ],
        discussion: networkChoice + " Creation, progress, output, and JSON are the same as clone; see docs/reference/cli/json-schemas.mdx."
            + " Prefer clone when choosing a name up front.",
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["task", "exec"],
        group: .advanced,
        summary: "Run a command in a project task; the same as exec.",
        usage: "microvm task exec ID [OPTIONS] [--] COMMAND [ARGS...]",
        flags: execFlags,
        examples: [
            "microvm task exec demo -- npm test",
            "microvm task exec demo --timeout 300 --cwd /workspace --env CI=1 -- npm test",
            "microvm task exec -i demo -- cat",
            "microvm task exec --interactive demo -- cat",
            "microvm task exec --no-input demo -- true",
            "microvm task exec -t demo -- sh",
            "microvm task exec --tty demo -- top",
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
        usage: "microvm task finish ID [--json]",
        flags: [CLIFlag(name: "--json", value: nil, summary: "Print the documented finish result on stdout.")],
        examples: ["microvm task finish demo", "microvm task finish demo --json"],
        discussion: "Same export, destruction, and result handoff as finish. The argument is the task id. See docs/tutorials/agent-task-workflow.mdx.",
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["version"],
        group: .advanced,
        summary: "Print version and host virtualization support.",
        usage: "microvm version [--json]",
        flags: [CLIFlag(name: "--json", value: nil, summary: "Print version, guest architecture, and virtualization support as JSON.")],
        examples: ["microvm version", "microvm --version", "microvm version --json"],
        discussion: "The version flag is also accepted before or after another command and then exits without running it. "
            + "With --json, either form prints the version object. See docs/reference/cli/commands.mdx.",
        allowsJSON: true
    ),
    CLICommandSpec(
        path: ["help"],
        group: .advanced,
        summary: "Show help for a command.",
        usage: "microvm help [COMMAND]",
        flags: [],
        examples: ["microvm help", "microvm help clone", "microvm clone --help"],
        discussion: "microvm help COMMAND and microvm COMMAND --help show the same command help. Help is text only; "
            + "--json is unsupported. See docs/reference/cli/commands.mdx for every command's output and JSON support."
    ),
]

/// The repository workflow, shared word for word with the README quick start (checked by a test).
let quickStart = """
microvm doctor
microvm runtime prepare . --runtime node:22        # in the microvm checkout; downloads verified inputs
microvm clone ./project deps --network filtered    # explicit network: HTTPS to the npm registry only
microvm exec deps --timeout 300 -- npm ci
microvm finish deps                                # exports the result and saves the npm cache
microvm clone ./project demo                       # offline by default: no network device
microvm exec demo -- npm ci --offline              # installs from the saved npm cache
microvm exec demo -- npm test
microvm shell demo
microvm ls
microvm inspect demo
microvm logs demo
microvm diff demo
microvm finish demo                                # exports the patch, then destroys the sandbox
microvm rm demo
microvm rm deps
"""

private func topLevelHelp() -> String {
    let commands = cliCommandSpecs.filter { $0.group == .primary }.map { spec in
        "  \(spec.usage)\n        \(spec.summary)"
    }.joined(separator: "\n")
    return """
    microvm \(MicroVMInfo.version) — local Linux microVMs on macOS

    Bring a repository into a disposable sandbox, run commands there, and export a result.
    Names are explicit targets. \(networkChoice)

    WORKFLOW
    \(quickStart.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n"))

    COMMANDS
    \(commands)

    Run `microvm help <command>` or `microvm <command> --help` for flags and examples.
    Run `microvm help advanced` for raw sandboxes, task commands, and the daemon.

    \(globalOptions)

    Images are built with scripts/fetch-image.sh and stored under MICROVM_HOME (default ~/.microvm).
    Commands that need a daemon start one. Help and invalid usage do not.

    """
}

private func advancedHelp() -> String {
    let commands = cliCommandSpecs.filter { $0.group == .advanced }.map { spec in
        "  \(spec.usage)\n        \(spec.summary)"
    }.joined(separator: "\n")
    return """
    Advanced commands

    These remain available beside the repository workflow. Overlapping commands share the same sandbox behavior.

    \(commands)

    \(globalOptions)
    """
}

private func groupHelp(_ name: String, _ intro: String, _ paths: [[String]]) -> String {
    let commands = paths.compactMap(cliSpec).map { spec in
        "  \(spec.usage)\n        \(spec.summary)"
    }.joined(separator: "\n")
    return """
    microvm \(name)

    \(intro)

    \(commands)

    Run `microvm help \(name) <subcommand>` for flags and examples.

    \(globalOptions)
    """
}

private func render(_ spec: CLICommandSpec) -> String {
    let options: String
    if spec.flags.isEmpty {
        options = "  This command accepts no flags besides the global options.\n"
    } else {
        options = spec.flags.map { flag in
            let label = flag.value.map { "\(flag.name) \($0)" } ?? flag.name
            return "  \(label)\n        \(flag.summary)"
        }.joined(separator: "\n") + "\n"
    }
    let examples = spec.examples.map { "  \($0)" }.joined(separator: "\n")
    return """
    \(spec.summary)

    USAGE
      \(spec.usage)

    OPTIONS
    \(options)
    \(spec.discussion)

    EXAMPLES
    \(examples)

    \(globalOptions)
    """
}

private let globalOptions = """
GLOBAL OPTIONS
  --home PATH
        Use this directory instead of MICROVM_HOME. It may appear before or after the subcommand.
  --verbose
        On failure, include safe error code, operation, source, and exit status diagnostics on stderr.
  -h, --help
        Show help for the current command and exit.
  --version
        Print the version and exit.

Valued options accept a separate argument or an equals sign, for example --network nat or --network=nat.
Guest arguments after exec's -- are not read as options.
"""
