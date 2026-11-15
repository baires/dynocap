// Pull request titles follow Conventional Commits. The bump comes from the title.
// fix is a patch, feat is a minor, and a bang is a breaking major.
// docs, test, refactor, perf, build, ci, chore, and revert do not ship a version.

export const SUPPORTED_TYPES = [
  "feat",
  "fix",
  "docs",
  "test",
  "refactor",
  "perf",
  "build",
  "ci",
  "chore",
  "revert",
];

const TYPES = new Set(SUPPORTED_TYPES);
const TITLE = /^([a-z]+)(\([a-z0-9-]+\))?(!)?:\s+(.+)$/;
const RELEASE_PR = /^chore: release v\d+\.\d+\.\d+$/;

export function validatePrTitle(title) {
  if (!title || title.trim() === "") {
    return { valid: false, reason: "PR title cannot be empty" };
  }
  const match = title.match(TITLE);
  if (!match) {
    if (!/^[a-z]+/.test(title)) {
      return {
        valid: false,
        reason: "PR title must start with a lowercase type",
      };
    }
    if (!title.includes(":")) {
      return {
        valid: false,
        reason: "PR title must include a colon after the type",
      };
    }
    return {
      valid: false,
      reason:
        "PR title must follow Conventional Commits format: type(scope): description",
    };
  }
  const [, type, , , description] = match;
  if (!TYPES.has(type)) {
    return {
      valid: false,
      reason: `Type "${type}" is not supported. Supported types: ${SUPPORTED_TYPES.join(", ")}`,
    };
  }
  if (!description || description.trim() === "") {
    return {
      valid: false,
      reason: "PR title must include a description after the colon",
    };
  }
  if (description.endsWith(".")) {
    return {
      valid: false,
      reason: "PR title description must not end with a period",
    };
  }
  return { valid: true };
}

// none < patch < minor < major. A bang outranks the type.
export function bumpFromTitle(title) {
  const match = title.match(TITLE);
  if (!match || !TYPES.has(match[1])) return "none";
  if (match[3] === "!") return "major";
  if (match[1] === "feat") return "minor";
  if (match[1] === "fix") return "patch";
  return "none";
}

const RANK = { none: 0, patch: 1, minor: 2, major: 3 };

export function highestBump(titles) {
  let best = "none";
  for (const title of titles) {
    const bump = bumpFromTitle(title);
    if (RANK[bump] > RANK[best]) best = bump;
  }
  return best;
}

export function nextVersion(current, bump) {
  const match = /^(\d+)\.(\d+)\.(\d+)$/.exec(current);
  if (!match)
    throw new Error(`version must be major.minor.patch, got ${current}`);
  const major = Number(match[1]);
  const minor = Number(match[2]);
  const patch = Number(match[3]);
  if (bump === "major") return `${major + 1}.0.0`;
  if (bump === "minor") return `${major}.${minor + 1}.0`;
  if (bump === "patch") return `${major}.${minor}.${patch + 1}`;
  return current;
}

export function replaceVersion(source, version) {
  const pattern = /public static let version = "[^"]+"/;
  if (!pattern.test(source)) throw new Error("DynoCapInfo.version not found");
  return source.replace(pattern, `public static let version = "${version}"`);
}

// Pull requests merged after the commit that set the current version.
// The release pull request itself is not another bump.
export function titlesSince(pulls, afterMs) {
  return pulls
    .filter((pull) => Date.parse(pull.mergedAt) > afterMs)
    .filter((pull) => pull.headRefName !== "release/next")
    .filter((pull) => !RELEASE_PR.test(pull.title))
    .map((pull) => pull.title);
}
