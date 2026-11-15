// Assumptions:
// - Production URL is a stand-in (https://microvm.dev) until a host is chosen. placeholder: true.
// - Release-facing install paths are intentional placeholders until launch: Homebrew tap and curl installer.
// - The curl URL assumes the production domain will serve /install.sh. placeholder: true.
// - Source build remains the path that works today: ./scripts/build-macos.sh.
// - @microvm/sdk and @microvm/mcp ship in this repository. They are not on the public npm registry.
// - Timings are medians from docs/research/boot-time.md, one Apple Silicon Mac, 13 Nov 2026.
//   They apply after the daemon is up and the guest image or runtime is already prepared.

export const site = {
  name: "MicroVM",
  role: "Local Linux VMs",
  url: "https://microvm.dev",
  placeholder: true,
  description:
    "Local Linux sandboxes for coding agents and developers on macOS. Copy a project, run code, review the diff, and export a patch with the CLI, SDK, or MCP.",
  license: "Apache-2.0",
  licenseHref: "https://www.apache.org/licenses/LICENSE-2.0",
};

export const hero = {
  title: "Give your code agent a Linux sandbox.",
  lede: "Copy in a project. Run code in an isolated Linux guest on your Mac. Review the patch before it touches your checkout.",
};

export const workflow = [
  {
    title: "Copy your project",
    command: "microvm clone . demo",
    text: "Imports the current directory into a disposable workspace.",
  },
  {
    title: "Run code inside",
    command: "microvm exec demo -- uname -a",
    text: "Runs in the Linux guest. Output returns to your terminal.",
  },
  {
    title: "Review the changes",
    command: "microvm diff demo",
    text: "Shows the patch for anything you or your agent changed.",
  },
  {
    title: "Export and clean up",
    command: "microvm finish demo",
    text: "Saves the patch and logs, then destroys the sandbox.",
  },
];

export const installation = {
  brew: "brew install microvm/tap/microvm",
  curl: "curl -fsSL https://microvm.dev/install.sh | sh",
  source:
    'npm ci\n./scripts/build-macos.sh\nexport PATH="$PWD/.build/release:$PATH"',
  placeholder: true,
};

export const setup = [
  {
    title: "Install MicroVM",
    text: "Homebrew installs the CLI and its companions. Prefer another route? Use curl or build from source.",
    command: installation.brew,
  },
  {
    title: "Prepare your project",
    text: "Replace the path with your project. Doctor builds the guest image, prepares the detected runtime, and checks the daemon.",
    command: "cd ~/code/my-app\nmicrovm doctor --fix",
  },
];

export const measurements = [
  {
    value: "299",
    unit: "ms",
    label: "Raw sandbox ready",
    command: "microvm run",
    sample: "Median of 6 runs",
  },
  {
    value: "491",
    unit: "ms",
    label: "Small project copied and ready",
    command: "microvm clone",
    sample: "One-file directory, shell:1, 3 runs",
  },
  {
    value: "989",
    unit: "ms",
    label: "This repository copied and ready",
    command: "microvm clone",
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

export const guarantees = [
  {
    title: "Offline by default",
    text: "The default sandbox has no network device. Opt into filtered registry access or NAT when the task needs it.",
  },
  {
    title: "Your checkout stays on the host",
    text: "The workspace is imported. The host directory is never mounted into the guest.",
  },
  {
    title: "A fixed lifetime",
    text: "The default TTL is 30 minutes from creation, including boot. Work inside the guest does not extend it.",
  },
  {
    title: "A patch you can read",
    text: "finish writes the patch and the logs, then destroys the guest. Apply the patch when you choose.",
  },
];

export const runtimes = [
  { name: "node", version: "24" },
  { name: "python", version: "3.14" },
  { name: "go", version: "1.27" },
  { name: "shell", version: "1" },
];

export const nav = [
  { href: "/#install", label: "Get started" },
  { href: "/#agents", label: "MCP and skills" },
  { href: "/#performance", label: "Performance" },
  { href: "/docs", label: "Docs" },
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
    text: "Start a task from @microvm/sdk, exec in the workspace, and collect the result.",
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
