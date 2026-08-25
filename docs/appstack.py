"""Render the complete bijouxlabs GitOps application map with Graphviz.

Run directly or through ``scripts/render-diagrams.sh``. The generated image is
written next to this file as ``appstack.png``.
"""

from __future__ import annotations

import html
import os
import subprocess
from dataclasses import dataclass

DOCS = os.path.dirname(os.path.abspath(__file__))
ICONS = os.path.join(DOCS, "icons")
OUTPUT = os.path.join(DOCS, "appstack.png")

FONT = "Adwaita Mono"
FG = "#e6edf3"
MUTED = "#8b949e"
BG = "#0d1117"
PANEL_BG = "#161b22"
PANEL_BORDER = "#30363d"
ACCENT = "#58a6ff"
ACCENT_DIM = "#1f6feb"
LOG_ACCENT = "#f59e0b"


@dataclass(frozen=True)
class App:
    label: str
    icon: str
    port: str
    subtitle: str = ""


def icon(name: str) -> str:
    return os.path.join(ICONS, f"{name}.png")


def app_cell(app: App) -> str:
    label = html.escape(app.label)
    if app.subtitle:
        label += (
            f'<BR/><FONT POINT-SIZE="8" COLOR="{MUTED}">'
            f"{html.escape(app.subtitle)}</FONT>"
        )
    # Graphviz's HTML parser rejects whitespace immediately around a nested
    # TABLE, so keep the opening/closing TD boundaries deliberately compact.
    return (
        f'<TD PORT="{app.port}" WIDTH="126" HEIGHT="112" FIXEDSIZE="TRUE" '
        f'ALIGN="CENTER" VALIGN="MIDDLE"><TABLE BORDER="0" CELLBORDER="0" '
        f'CELLSPACING="0" CELLPADDING="2"><TR><TD WIDTH="68" HEIGHT="72" '
        f'FIXEDSIZE="TRUE"><IMG SRC="{icon(app.icon)}" SCALE="TRUE"/>'
        f'</TD></TR><TR><TD HEIGHT="28"><FONT FACE="{FONT}" COLOR="{FG}" '
        f'POINT-SIZE="10">{label}</FONT></TD></TR></TABLE></TD>'
    )


def empty_cell() -> str:
    return '<TD WIDTH="126" HEIGHT="112" FIXEDSIZE="TRUE"></TD>'


def panel(
    node_id: str,
    title: str,
    rows: list[list[App]],
    *,
    footer: str = "",
) -> str:
    columns = max(len(row) for row in rows)
    body = []
    for row in rows:
        cells = [app_cell(app) for app in row]
        cells.extend(empty_cell() for _ in range(columns - len(cells)))
        body.append("<TR>" + "".join(cells) + "</TR>")

    footer_row = ""
    if footer:
        footer_row = f"""
        <TR><TD COLSPAN="{columns}" ALIGN="LEFT" BGCOLOR="{BG}"
            CELLPADDING="8"><FONT FACE="{FONT}" COLOR="{MUTED}"
            POINT-SIZE="9">{footer}</FONT></TD></TR>"""

    return f"""
  {node_id} [shape="box", style="rounded,filled", color="{PANEL_BORDER}",
    fillcolor="{PANEL_BG}", penwidth="1.4", margin="0.10", label=<
    <TABLE BORDER="0" CELLBORDER="0" CELLSPACING="0" CELLPADDING="5">
      <TR><TD COLSPAN="{columns}" ALIGN="LEFT" HEIGHT="30">
        <FONT FACE="{FONT}" COLOR="{ACCENT}" POINT-SIZE="13">
          {html.escape(title)}
        </FONT>
      </TD></TR>
      {''.join(body)}
      {footer_row}
    </TABLE>
  >];"""


def image_node(node_id: str, label: str, image: str) -> str:
    rendered_label = "<BR/>".join(html.escape(line) for line in label.split("\\n"))
    return f'''  {node_id} [shape="plain", label=<
    <TABLE BORDER="0" CELLBORDER="0" CELLSPACING="0" CELLPADDING="2">
      <TR><TD WIDTH="92" HEIGHT="92" FIXEDSIZE="TRUE"><IMG SRC="{icon(image)}" SCALE="TRUE"/></TD></TR>
      <TR><TD HEIGHT="32"><FONT FACE="{FONT}" COLOR="{FG}" POINT-SIZE="10">{rendered_label}</FONT></TD></TR>
    </TABLE>
  >];'''


knowledge = panel(
    "knowledge",
    "apps/ — Files & Knowledge",
    [
        [
            App("Immich", "immich", "immich"),
            App("OCIS", "owncloud-light", "ocis"),
            App("Copyparty", "copyparty", "copyparty"),
        ],
        [
            App("Paperless-ngx", "paperless-ngx", "paperless"),
            App("Opengist", "opengist", "opengist"),
            App("Karakeep", "karakeep-light", "karakeep"),
        ],
    ],
)

productivity = panel(
    "productivity",
    "apps/ — Productivity & Services",
    [
        [
            App("Actual Budget", "actualbudget", "actualbudget"),
            App("Vaultwarden", "vaultwarden-light", "vaultwarden"),
            App("Vikunja", "vikunja", "vikunja"),
        ],
        [
            App("ntfy", "ntfy", "ntfy"),
            App("Homepage", "homepage", "homepage"),
        ],
    ],
)

automation = panel(
    "automation",
    "apps/ — Home, Automation & AI",
    [
        [
            App("Home Assistant", "home-assistant", "homeassistant"),
            App("Ollama", "ollama", "ollama"),
            App("Qdrant", "qdrant", "qdrant"),
        ],
        [
            App("StefHQ", "stefhq", "stefhq"),
            App("Primecrunch", "primecrunch", "primecrunch", "paused in git"),
        ],
    ],
    footer=(
        f'<FONT COLOR="{FG}">StefHQ</FONT> → '
        f'<FONT COLOR="{FG}">Ollama</FONT> · local inference'
    ),
)

observability = panel(
    "observability",
    "apps/ — Observability & Logging",
    [
        [
            App("Grafana", "grafana", "grafana"),
            App("Prometheus", "prometheus", "prometheus"),
            App("Uptime Kuma", "uptime-kuma", "uptimekuma"),
        ],
        [
            App("Alloy", "alloy", "alloy"),
            App("Loki", "loki", "loki"),
            App("Radar", "radar", "radar"),
        ],
    ],
    footer=(
        f'<FONT COLOR="{LOG_ACCENT}">6× Proxmox hosts ─ RFC5424/TCP → '
        f'Alloy → Loki → Grafana</FONT><BR/>'
        "14× k3s nodes ─ pod logs → Alloy"
    ),
)

platform = panel(
    "platform",
    "cluster/ — Shared Platform",
    [[
        App("Traefik", "traefikproxy", "traefik"),
        App("MetalLB (L2)", "metallb", "metallb"),
        App("Longhorn", "longhorn", "longhorn"),
        App("Cilium + Hubble", "cilium", "cilium"),
        App("CloudNative-PG", "cloudnativepg", "cnpg"),
        App("kube-vip", "kubernetes", "kubevip"),
        App("cert-manager", "cert-manager", "certmanager"),
        App("cloudflared", "cloudflare", "cloudflared"),
    ]],
    footer="CoreDNS overrides · Goldilocks/VPA · declarative node topology",
)

source = "\n".join(
    [
        "digraph bijouxlabs {",
        f'''  graph [rankdir="TB", bgcolor="{BG}", pad="0.35", margin="0",
    fontname="{FONT}", fontcolor="{FG}", fontsize="20", labelloc="b",
    label="bijouxlabs — GitOps flow", outputorder="edgesfirst",
    splines="spline", nodesep="0.48", ranksep="0.62", dpi="150"];''',
        f'''  node [fontname="{FONT}", fontcolor="{FG}", fontsize="10"];''',
        f'''  edge [fontname="{FONT}", fontcolor="{FG}", fontsize="9",
    color="{MUTED}", penwidth="1.8", arrowsize="0.7"];''',
        image_node("repo", "bijouxlabs repo\\n(SOPS + age)", "github-light"),
        image_node("flux", "Flux CD", "flux"),
        knowledge,
        productivity,
        automation,
        observability,
        platform,
        f'''  station_top [shape="circle", label="", width="0.14", height="0.14",
    fixedsize="true", style="filled", color="{ACCENT}", fillcolor="{BG}",
    penwidth="3"];''',
        f'''  station_mid [shape="circle", label="", width="0.14", height="0.14",
    fixedsize="true", style="filled", color="{ACCENT}", fillcolor="{BG}",
    penwidth="3"];''',
        f'''  station_low [shape="circle", label="", width="0.14", height="0.14",
    fixedsize="true", style="filled", color="{ACCENT}", fillcolor="{BG}",
    penwidth="3"];''',
        "  { rank=same; knowledge; station_top; productivity; }",
        "  { rank=same; automation; station_mid; observability; }",
        "  knowledge -> station_top -> productivity [style=invis, weight=200];",
        "  automation -> station_mid -> observability [style=invis, weight=200];",
        "  knowledge -> automation [style=invis, weight=120];",
        "  productivity -> observability [style=invis, weight=120];",
        '  repo -> flux [label="reconcile", minlen="1"];',
        f'''  flux -> station_top [dir="none", color="{ACCENT}", penwidth="3"];''',
        f'''  station_top -> station_mid [dir="none", color="{ACCENT}",
    penwidth="3"];''',
        f'''  station_mid -> station_low [dir="none", color="{ACCENT}",
    penwidth="3"];''',
        f'''  station_top -> knowledge:e [dir="none", color="{ACCENT}",
    penwidth="3", constraint="false"];''',
        f'''  station_top -> productivity:w [dir="none", color="{ACCENT}",
    penwidth="3", constraint="false"];''',
        f'''  station_mid -> automation:e [dir="none", color="{ACCENT}",
    penwidth="3", constraint="false"];''',
        f'''  station_mid -> observability:w [dir="none", color="{ACCENT}",
    penwidth="3", constraint="false"];''',
        f'''  station_low -> platform:n [label="runs on", color="{ACCENT_DIM}",
    fontcolor="{ACCENT}", penwidth="3", minlen="1"];''',
        f'''  knowledge:karakeep:s -> automation:ollama:n [label="local AI",
    style="dotted", color="{MUTED}", constraint="false"];''',
        "}",
    ]
)

if os.environ.get("BIJOUXLABS_DUMP_DOT"):
    print(source)
    raise SystemExit(0)

subprocess.run(
    ["dot", "-Tpng", "-o", OUTPUT],
    input=source,
    text=True,
    check=True,
)
