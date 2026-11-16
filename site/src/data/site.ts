// Assumptions:
// - Production URL is a stand-in (https://dynocap.dev) until a host is chosen. placeholder: true.
// - Homebrew installs baires/tap/dynocap from github.com/baires/homebrew-tap.
// - /install.sh serves scripts/install.sh. The curl command uses the production domain.
// - Source build remains ./scripts/build-macos.sh from a checkout.
// - @dynocap/sdk and @dynocap/mcp ship in this repository. They are not on the public npm registry.
// - Timings are medians from docs/research/boot-time.md, one Apple Silicon Mac, 13 Nov 2026.
//   They apply after the daemon is up and the guest image or runtime is already prepared.

export const site = {
  name: "DynoCap",
  role: "Local Linux VMs",
  url: "https://dynocap.dev",
  placeholder: true,
  description:
    "Local Linux sandboxes for coding agents and developers on macOS. Copy a project, run code, review the diff, and export a patch with the CLI, SDK, or MCP.",
  repository: "https://github.com/baires/dynocap",
  license: "Apache-2.0",
  licenseHref: "https://www.apache.org/licenses/LICENSE-2.0",
};

export const hero = {
  title: "Give your coding agent its own Linux machine.",
  lede: "Each task gets a fresh microVM on your Mac, with its own kernel, no network, and no host folders mounted. It is ready in 299 ms, sized to the job, and hands back a patch you review before anything touches your checkout.",
};

export const workflow = [
  {
    title: "Copy your project",
    command: "dynocap clone . demo",
    text: "Imports the current directory into a disposable workspace.",
  },
  {
    title: "Run code inside",
    command: "dynocap exec demo -- uname -a",
    text: "Runs in the Linux guest. Output returns to your terminal.",
  },
  {
    title: "Review the changes",
    command: "dynocap diff demo",
    text: "Shows the patch for anything you or your agent changed.",
  },
  {
    title: "Export and clean up",
    command: "dynocap finish demo",
    text: "Saves the patch and logs, then destroys the sandbox.",
  },
];

// The commands in site/demo/workflow.tape, in order. Keep the two in sync.
export const demo = {
  video: "/demo/dynocap-workflow",
  duration: "20-second",
  commands: [
    "cat README.md",
    "dynocap clone . demo",
    "dynocap exec demo -- uname -sr",
    "dynocap exec demo -- sed -i 's/from the host/from a microVM/' README.md",
    "dynocap diff demo",
    "dynocap finish demo",
    "cat README.md",
  ],
};

export const installation = {
  brew: "brew install baires/tap/dynocap",
  curl: "curl -fsSL https://dynocap.dev/install.sh | sh",
  source: './scripts/build-macos.sh\nexport PATH="$PWD/.build/release:$PATH"',
  placeholder: false,
};

export const setup = [
  {
    title: "Install DynoCap",
    text: "Homebrew installs the CLI and its companions, and this command trusts the formula. For a later short-name upgrade, run brew trust --formula baires/tap/dynocap. Prefer another route? Use curl or build from source.",
    command: installation.brew,
  },
  {
    title: "Prepare your project",
    text: "Replace the path with your project. Doctor builds the guest image, prepares the detected runtime, and checks the daemon.",
    command: "cd ~/code/my-app\ndynocap doctor --fix",
  },
];

// `at` places each median on a 0 to 1000 ms scale.
export const measurements = [
  {
    value: "11",
    unit: "ms",
    at: 1.1,
    label: "Next command in a running microVM",
    command: "dynocap exec",
    sample: "Median, after run returned",
  },
  {
    value: "299",
    unit: "ms",
    at: 29.9,
    label: "Fresh microVM, ready for commands",
    command: "dynocap run",
    sample: "Median of 6 runs",
  },
  {
    value: "491",
    unit: "ms",
    at: 49.1,
    label: "Small project copied in and ready",
    command: "dynocap clone",
    sample: "One-file directory, shell:1, 3 runs",
  },
  {
    value: "989",
    unit: "ms",
    at: 98.9,
    label: "This repository copied in and ready",
    command: "dynocap clone",
    sample: "387 files, shell:1, 2 runs",
  },
];

export const doors = [
  {
    title: "Your terminal",
    command: "Read the CLI reference",
    text: "Use clone, exec, shell, diff, and finish. Keep your editor and the terminal you already use.",
    href: "/docs/reference/cli/commands",
  },
  {
    title: "Your application",
    command: "Use the TypeScript SDK",
    text: "Create tasks, execute commands, and collect results from your own agent loop through the local daemon.",
    href: "/docs/how-to/integrate-typescript-sdk",
  },
];

export const boundary = [
  {
    host: "Your checkout",
    guest:
      "A copy in a disposable workspace. Your directory is never mounted into the guest.",
  },
  {
    host: "Your network",
    guest:
      "No network device at all, unless you choose filtered registry access or NAT for that task.",
  },
  {
    host: "Your kernel",
    guest:
      "A separate Linux kernel under Apple’s Virtualization framework, not a container sharing yours.",
  },
  {
    host: "Your decision",
    guest:
      "finish exports a patch and logs, then destroys the microVM. Nothing is applied until you apply it.",
  },
];

export const controls = [
  {
    flag: "--runtime node:24",
    title: "Toolchain",
    text: "Node, Python, Go, or a plain shell, detected from your project files and attached read-only.",
  },
  {
    flag: "--cpus 4 --memory 4096",
    title: "Resources",
    text: "Virtual CPUs and RAM for each task, so a heavy build gets room and a quick check stays small.",
  },
  {
    flag: "--network filtered",
    title: "Network",
    text: "Off by default. Filtered allows HTTPS to the runtime’s registry and Git host only. NAT opens outbound access when a task truly needs it.",
  },
  {
    flag: "--ttl 900",
    title: "Lifetime",
    text: "30 seconds to 24 hours, counted from creation. Activity never extends it, so nothing lingers.",
  },
];

export const runtimes = [
  { name: "node", version: "24" },
  { name: "node", version: "22" },
  { name: "python", version: "3.14" },
  { name: "go", version: "1.27" },
  { name: "shell", version: "1" },
];

export const nav = [
  { href: "/#speed", label: "Speed" },
  { href: "/#isolation", label: "Isolation" },
  { href: "/#agents", label: "Agents" },
  { href: "/#install", label: "Get started" },
  { href: "/docs", label: "Docs" },
  { href: site.repository, label: "GitHub" },
];

export const guides = [
  {
    title: "Boot a guest",
    text: "Check the Mac, build the CLI, and run one command in a Linux guest.",
    href: "/docs/tutorials/getting-started",
  },
  {
    title: "Run a project task",
    text: "Clone a repo into a sandbox, exec, look at the diff, then finish and keep the patch.",
    href: "/docs/tutorials/agent-task-workflow",
  },
  {
    title: "Call it from TypeScript",
    text: "Start a task from @dynocap/sdk, exec in the workspace, and collect the result.",
    href: "/docs/how-to/integrate-typescript-sdk",
  },
  {
    title: "Hand it to an agent",
    text: "Point Cursor, Claude, or Cline at the local MCP server.",
    href: "/docs/how-to/configure-mcp-server",
  },
];

export const quadrants = [
  {
    id: "tutorials",
    title: "Tutorials",
    text: "Build the CLI, then run a full task.",
  },
  {
    id: "how-to",
    title: "How-to guides",
    text: "Dependencies, egress, shells, the SDK, MCP, and doctor.",
  },
  {
    id: "reference",
    title: "Reference",
    text: "CLI contracts, JSON, the SDK, MCP tools, and the guest protocol.",
  },
  {
    id: "explanation",
    title: "Explanation",
    text: "The daemon, the isolation boundary, TTL, and how patches are made.",
  },
];
