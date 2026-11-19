const origin = "https://dynocap.dev";

const apis = [
  {
    anchor: `${origin}/docs/reference/cli/commands`,
    spec: `${origin}/openapi/cli.json`,
    doc: `${origin}/docs/reference/cli/commands`,
  },
  {
    anchor: `${origin}/docs/reference/sdk-api`,
    spec: `${origin}/openapi/sdk.json`,
    doc: `${origin}/docs/reference/sdk-api`,
  },
  {
    anchor: `${origin}/docs/reference/mcp-tools`,
    spec: `${origin}/openapi/mcp.json`,
    doc: `${origin}/docs/reference/mcp-tools`,
  },
];

// RFC 9264: link targets in a linkset are absolute. These interfaces run on the
// local machine; the anchor is the public reference for each one.
export const apiCatalog = {
  linkset: apis.map((api) => ({
    anchor: api.anchor,
    "service-desc": [{ href: api.spec, type: "application/openapi+json" }],
    "service-doc": [{ href: api.doc, type: "text/html" }],
  })),
};

export const apiCatalogBody = `${JSON.stringify(apiCatalog, null, 2)}\n`;

export const apiCatalogHeaders = {
  "Content-Type":
    'application/linkset+json; profile="https://www.rfc-editor.org/info/rfc9727"',
  Link: '</.well-known/api-catalog>; rel="api-catalog"',
  "X-Content-Type-Options": "nosniff",
};

function linkHeader(pathname, relation, type) {
  return `<${pathname}>; rel="${relation}"; type="${type}"`;
}

// RFC 9727 §3: the site root points at the API catalog. The other registered
// relations point at the machine-readable descriptions, the HTML references,
// and the agent index. Service docs use the slashless URL that returns 200.
export const homepageLinks = [
  linkHeader(
    "/.well-known/api-catalog",
    "api-catalog",
    "application/linkset+json"
  ),
  ...apis.flatMap((api) => [
    linkHeader(
      new URL(api.spec).pathname,
      "service-desc",
      "application/openapi+json"
    ),
    linkHeader(
      new URL(api.doc).pathname.replace(/\/$/, ""),
      "service-doc",
      "text/html"
    ),
  ]),
  linkHeader("/llms.txt", "describedby", "text/plain"),
];

export function appendHomepageLinks(headers, pathname) {
  if (pathname !== "/") return;
  for (const value of homepageLinks) headers.append("Link", value);
}
