# Astro Starter Kit: Minimal

```sh
npm create astro@latest -- --template minimal
```

> 🧑‍🚀 **Seasoned astronaut?** Delete this file. Have fun!

## 🚀 Project Structure

Inside of your Astro project, you'll see the following folders and files:

```text
/
├── public/
├── src/
│   └── pages/
│       └── index.astro
└── package.json
```

Astro looks for `.astro` or `.md` files in the `src/pages/` directory. Each page is exposed as a route based on its file name.

There's nothing special about `src/components/`, but that's where we like to put any Astro/React/Vue/Svelte/Preact components.

Any static assets, like images, can be placed in the `public/` directory.

## 🧞 Commands

All commands are run from the root of the project, from a terminal:

| Command                   | Action                                           |
| :------------------------ | :----------------------------------------------- |
| `npm install`             | Installs dependencies                            |
| `npm run dev`             | Starts local dev server at `localhost:4321`      |
| `npm run build`           | Build your production site to `./dist/`          |
| `npm run preview`         | Preview your build locally, before deploying     |
| `npm run test:markdown`   | Build and test Markdown negotiation in Wrangler  |
| `npm run astro ...`       | Run CLI commands like `astro add`, `astro check` |
| `npm run astro -- --help` | Get help using the Astro CLI                     |

## Markdown for agents

Request any page with `Accept: text/markdown` to get its main content as
Markdown. HTML is the default. Both representations send `Vary: Accept`.
Follow redirects when requesting a URL without its trailing slash.

```sh
curl -fsSL -H 'Accept: text/markdown' https://dynocap.dev/docs/tutorials/getting-started
```

The same request works against Astro's dev server.

```sh
curl -fsS -H 'Accept: text/markdown' http://localhost:4321/docs/tutorials/getting-started
```

The Astro build generates Markdown alongside the HTML, and the Cloudflare Worker
selects the representation in production. Use Wrangler to test that setup locally.
Each docs page uses the same file for its direct `.md` URL and its negotiated
response. Find those URLs in `llms.txt`.

## API catalog

`/.well-known/api-catalog` is an [RFC 9727](https://www.rfc-editor.org/rfc/rfc9727)
linkset. It lists the CLI, the TypeScript SDK, and the MCP server. Each entry
links to an OpenAPI document under `/openapi/` and to the HTML reference.
Those interfaces run on the local machine. They are not HTTP routes on this host.

```sh
curl -fsS -D - https://dynocap.dev/.well-known/api-catalog
```

## 👀 Want to learn more?

Feel free to check [our documentation](https://docs.astro.build) or jump into our [Discord server](https://astro.build/chat).
