"""GitOps flow + app stack diagram. Render: see scripts/render-diagrams.sh"""

import os

from diagrams import Cluster, Diagram, Edge
from diagrams.custom import Custom
from diagrams.onprem.database import PostgreSQL
from diagrams.onprem.gitops import Flux
from diagrams.onprem.monitoring import Grafana, Prometheus
from diagrams.onprem.network import Traefik

DOCS = os.path.dirname(os.path.abspath(__file__))
ICONS = os.path.join(DOCS, "icons")

FONT = "Adwaita Mono"
FG = "#e6edf3"
BG = "#0d1117"
CLUSTER_BG = "#161b22"
CLUSTER_BORDER = "#30363d"
EDGE = "#8b949e"

PLATFORM = "cluster/ — platform"
FILES = "apps/ — Files & Docs"
HOME = "apps/ — Home & Automation"
OBS = "apps/ — Observability"


def icon(name):
    return os.path.join(ICONS, f"{name}.png")


def dark(label):
    return Cluster(
        label,
        graph_attr={
            "bgcolor": CLUSTER_BG,
            "pencolor": CLUSTER_BORDER,
            "fontcolor": FG,
            "fontname": FONT,
            "margin": "20",
        },
    )


with Diagram(
    "bijouxlabs — GitOps flow",
    filename=os.path.join(DOCS, "appstack"),
    outformat="png",
    show=False,
    direction="TB",
    graph_attr={
        "fontsize": "20",
        "bgcolor": BG,
        "pad": "0.5",
        "fontname": FONT,
        "fontcolor": FG,
        "compound": "true",
        "ranksep": "1.2",
    },
    node_attr={"fontname": FONT, "fontcolor": FG},
    edge_attr={"color": EDGE, "fontname": FONT, "fontcolor": FG, "penwidth": "2"},
):
    gh = Custom("bijouxlabs repo\n(SOPS secrets)", icon("github-light"))
    flux = Flux("Flux CD")

    with dark(FILES):
        immich = Custom("Immich", icon("immich"))
        ocis = Custom("OCIS", icon("owncloud-light"))
        copyparty = Custom("Copyparty", icon("copyparty"))
        paperlessngx = Custom("PaperlessNGX", icon("paperless-ngx"))
        opengist = Custom("Opengist", icon("opengist"))
        karakeep = Custom("Karakeep", icon("karakeep-light"))

    with dark(HOME):
        homeassistant = Custom("Home Assistant", icon("home-assistant"))
        n8n = Custom("n8n", icon("n8n"))
        ollama = Custom("Ollama", icon("ollama"))
        qdrant = Custom("Qdrant", icon("qdrant"))
        homepage = Custom("Homepage", icon("homepage"))

    with dark(OBS):
        grafana = Grafana("Grafana")
        prometheus = Prometheus("Prometheus")
        uptimekuma = Custom("Uptime Kuma", icon("uptime-kuma"))
        radar = Custom("Radar", icon("radar"))

    with dark(PLATFORM):
        traefik = Traefik("Traefik")
        metallb = Custom("MetalLB (L2)", icon("metallb"))
        longhorn = Custom("Longhorn", icon("longhorn"))
        cilium = Custom("Cilium + Hubble", icon("cilium"))
        cnpg = PostgreSQL("CloudNative-PG")
        kubevip = Custom("kube-vip", icon("kubernetes"))
        certmgr = Custom("cert-manager", icon("cert-manager"))
        cfd = Custom("cloudflared", icon("cloudflare"))

    gh >> Edge(label="reconcile", fontcolor=FG) >> flux

    # Flux fans out to each app group; arrows clip at cluster borders (compound)
    flux >> Edge(style="dashed", lhead=f"cluster_{FILES}") >> ocis
    flux >> Edge(style="dashed", lhead=f"cluster_{HOME}") >> ollama
    flux >> Edge(style="dashed", lhead=f"cluster_{OBS}") >> prometheus

    # apps run on the platform layer → pushes the platform cluster to the bottom rank
    ocis >> Edge(ltail=f"cluster_{FILES}", lhead=f"cluster_{PLATFORM}") >> cilium
    ollama >> Edge(label="runs on", fontcolor=FG, ltail=f"cluster_{HOME}", lhead=f"cluster_{PLATFORM}") >> cnpg
    prometheus >> Edge(ltail=f"cluster_{OBS}", lhead=f"cluster_{PLATFORM}") >> certmgr

    karakeep >> Edge(label="local AI", fontcolor=FG, style="dotted") >> ollama
