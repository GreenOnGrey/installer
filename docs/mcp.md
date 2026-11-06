# MCP servers

Optional MCP servers for Nabu agents (`FTR.NAB.CMN-0006`). Each one is enabled by its own option in the config file, and all are off by default. The wizard lists them with the memory each one requests. The chart, images and server descriptions are released by the repository [mcps](https://github.com/GreenOnGrey/mcps), and `MCP_CHART_VERSION` in `config/versions.env` pins the version.

Servers are installed by the release `mcp-servers` in the namespace `mcp` and are available only to the Nabu `api` (through network policies, enforced by the stand's kindnet). Nothing is published outside.

| Option | Server | Memory (request / limit) | Image, disk |
|---|---|---|---|
| `MCP_DOCLING=true` | Document conversion: `docling-serve` (CPU, OCR `ru`, `en`) and `docling-mcp` | ~1.5 / 5 GiB | ~4.4 GB |
| `MCP_SEARCH=true` | Web search: SearXNG and `mcp-searxng` | ~0.4 / 0.8 GiB | ~0.3 GB |
| `MCP_YANDEX_MAIL=true` | Read-only Yandex Mail: our own server `imap-mcp` | ~0.06 / 0.25 GiB | ~0.1 GB |
| `MCP_DOCGEN=true` | Creating, editing and converting documents (`FTR.NAB.CHAT-0003`): our own server `docgen-mcp` and `doc-convert` (Gotenberg, which is LibreOffice and Chromium without network, and the `legacy` sidecar); it also turns on the DOCX/XLSX/PPTX preview in Nabu | ~0.9 / 4 GiB | ~2.5 GB |

## Turning a server off

`install` stores the MCP settings in the ConfigMap `installer/installer-config`, so a later `install` without them keeps the servers. Removing an option from the file does not turn a server off. Set `MCP_<NAME>=false` explicitly, and the next `install` removes the server.

## Memory

Before the deploy, `install` checks the memory budget (two thirds of the node memory, like the `resources` check). If the servers do not fit, it exits with code 2 before anything changes and says which `MK_MEMORY` is needed; on an existing cluster, how much memory is missing. The minikube profile with new memory is created anew (`uninstall`, then `install`). With document conversion on the default stand (12 GB), `MK_MEMORY=16g` is recommended.

## Parameters

`MCP_DOCLING_MAX_MB` is the document size limit of `docling-serve`, and `MCP_SEARCH_ENGINES` lists the SearXNG engines. Access keys are generated on the first `install` and kept in secrets of the namespace `mcp`. With `MCP_DOCGEN=true`, `install` creates the secret `nabu-docs-preview` in the namespace `nabu` (addresses and keys of `doc-convert` and `docgen`) and restarts the Nabu `api` if the secret changed. Without it the office file preview is off.

## Adding to the Nabu catalog

`./installer creds` prints addresses and keys. In the Nabu admin area → Catalog → MCP server:

- **Documents**: address `http://docling-mcp.mcp.svc:8080/mcp`, platform, header `Authorization: Bearer <key>`. After the check, allow `convert_document_into_docling_document`, `export_docling_document_to_markdown`, `get_overview_of_document_anchors`, `search_for_text_in_document_anchors`, `get_text_of_document_item_at_anchor`, and mark the conversion argument `source` as a space file. Do not allow the other tools (listing and changing the cache, working with the server's disk).
- **Documents: creation**: `http://docgen.mcp.svc:8000/mcp`, platform, `Authorization: Bearer <key>`. After the check, allow all six tools and mark the arguments (`creds` prints them as a ready list):

  | Tool | What it does | Space file | Result path |
  |---|---|---|---|
  | `render_document` | Markdown → DOCX, PDF or PPTX; styled after a sample DOCX | `reference`, `images` (list) | `dest` |
  | `render_spreadsheet` | XLSX from a description of sheets: types, formulas, frozen panes, charts | `template` | `dest` |
  | `fill_template` | Fills a DOCX or XLSX template with data (`{{ … }}`, loops `{%tr … %}`) | `template` | `dest` |
  | `edit_document` | Edits DOCX and PPTX (replaces text and keeps the styling) and XLSX (cells, rows, sheets) | `source` | `dest` |
  | `convert` | DOCX/XLSX/PPTX → PDF, DOC/XLS/PPT → OOXML, HTML or a `.zip` with `index.html` → PDF | `source` | `dest` |
  | `pdf_tools` | PDF: merging, splitting into parts (`.zip`), rotating and extracting pages | `sources` (list) | `dest` |

  The file limit is 25 MB and the result limit is 50 MB. Mark all six tools as writing only to the space: in mail threads they run without a confirmation (overwriting a file asks for one).
- **Web search**: `http://search.mcp.svc:3000/mcp`, platform, `Authorization: Bearer <key>`.
- **Yandex Mail**: `http://yandex-mail.mcp.svc:8000/mcp`, personal, OAuth: authorize `https://oauth.yandex.ru/authorize`, token `https://oauth.yandex.ru/token`, the ClientID and Client secret of the Yandex app, scopes `mail:imap_ro login:email`. All tools of this server only read. The entry is checked with the administrator's personal access, so connect it under Connections first. To make Yandex Mail a source of the communications memory, in the Nabu admin area → Communications memory, choose the adapter `mail` for the entry and turn on Source. The entry must allow `list_folders`, `search_messages` and `read_thread`. The `mail` adapter is common for IMAP mail: another provider with OAuth for IMAP is another deployment of `imap-mcp` with its own `IMAP_HOST`, `USERINFO_*` and `WEB_LINK`.

## The Yandex OAuth app for Yandex Mail

At [oauth.yandex.ru](https://oauth.yandex.ru), create an app of the type **For user authorization**. Do not use the type for API access or debugging: its Redirect URI is always `https://oauth.yandex.ru/verification_code` and cannot change, so the code shows on the Yandex page and never reaches Nabu. The app type cannot change after creation. The platform is Web services, and the Redirect URI is the OAuth callback of the entry from the Nabu catalog form (`https://<Nabu api>/api/v1/oauth/callback/<entry id>`). For data access, choose access to the email address (`login:email`) and, under other permissions, reading mail over IMAP (`mail:imap_ro`). With `mail:imap_ro`, Yandex itself forbids changing the mailbox. The server also opens folders read-only and does not mark messages as read. IMAP access to the mail must be on:

- *in the mailbox* (personal and in Yandex 360): the user opens the Yandex Mail settings, section Mail clients, block on allowing access to the mailbox through mail clients, and turns on access from the server imap.yandex.ru over IMAP and app passwords and OAuth tokens;
- *in a Yandex 360 organization*: an administrator can forbid employees mail clients or third-party apps through security policies at [admin.yandex.ru](https://admin.yandex.ru), and then must allow them (or the Nabu app). Item names depend on the plan and the console version, so check the Yandex 360 for Business help.

While access is off, the tools answer with an error saying what to turn on.
