# Diagrams

Editable draw.io sources for the three diagrams in [PRODUCT-DESIGN.md](../PRODUCT-DESIGN.md). The
same diagrams are embedded there as Mermaid code blocks, which GitHub renders directly.

| File | Shows |
| --- | --- |
| [architecture.drawio](architecture.drawio) | The hub org, the GitHub repository and the Salesforce orgs, and the two contracts between them (`workflow_dispatch` out, REST callbacks in) |
| [branching.drawio](branching.drawio) | `main` and the environment branches, a feature branch, the promotion branches cut from each target, and a release branch |
| [change-flow.drawio](change-flow.drawio) | One work item from commit to production release, as a sequence across developer, hub, Actions, git, org and reviewer |

## Editing

Open a `.drawio` file in [draw.io desktop](https://github.com/jgraph/drawio-desktop/releases) or at
<https://app.diagrams.net> (**File → Open from → Device**), or with the draw.io extension for VS Code.
The files are stored uncompressed, so changes show up in diffs. `.gitattributes` keeps them LF.

When you change a diagram, change the matching Mermaid block in PRODUCT-DESIGN.md too.

## Exporting PNGs

In draw.io desktop: **File → Export as → PNG…**, keep "Include a copy of my diagram" ticked if you
want the PNG to stay editable, and save it next to the source with the same name
(`architecture.png`, `branching.png`, `change-flow.png`). From the command line, draw.io desktop can
do the same:

```bash
drawio --export --format png --border 10 --output docs/diagrams/architecture.png docs/diagrams/architecture.drawio
```

(On Windows the executable is usually `"C:\Program Files\draw.io\draw.io.exe"`.) PNG exports are not
committed yet.
