#!/usr/bin/env python3
"""
Render proper architecture diagrams for the four webhook template READMEs:
  - whatsapp-webhook/option-a-apex
  - whatsapp-webhook/option-b-node
  - teams-webhook/option-a-apex
  - teams-webhook/option-b-node

Each is a vertical flow showing the actual code path. Per-option (not shared)
because the Apex and Node implementations differ structurally (custom object
session store vs in-memory Map, etc.).

Run from the repo root:
    python3 scripts/render_diagrams.py

Requires: matplotlib. Install with `pip install matplotlib`.
"""
import matplotlib.pyplot as plt
import matplotlib.patches as patches
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch
from pathlib import Path

# Resolve from the script's location so this works from any clone.
REPO_ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = REPO_ROOT / "templates"

# Visual constants
NODE_FILL = "#FFF7E6"        # warm cream
NODE_EDGE = "#D97706"        # amber
ENDPOINT_FILL = "#E0F2FE"    # pale blue
ENDPOINT_EDGE = "#0369A1"    # blue
USER_FILL = "#DCFCE7"        # pale green
USER_EDGE = "#15803D"        # green
TEXT = "#1F2937"
ANNOTATION = "#4B5563"


def make_box(ax, x, y, w, h, label, fill, edge, fontsize=11, weight="normal"):
    box = FancyBboxPatch(
        (x - w / 2, y - h / 2), w, h,
        boxstyle="round,pad=0.02,rounding_size=0.06",
        linewidth=1.8,
        facecolor=fill,
        edgecolor=edge,
    )
    ax.add_patch(box)
    ax.text(x, y, label, ha="center", va="center",
            fontsize=fontsize, fontweight=weight, color=TEXT)
    return box


def arrow(ax, x1, y1, x2, y2, label=None, label_offset=(0.15, 0)):
    a = FancyArrowPatch(
        (x1, y1), (x2, y2),
        arrowstyle="-|>",
        mutation_scale=18,
        linewidth=1.6,
        color="#374151",
    )
    ax.add_patch(a)
    if label:
        mx, my = (x1 + x2) / 2, (y1 + y2) / 2
        ax.text(mx + label_offset[0], my + label_offset[1], label,
                ha="left", va="center", fontsize=9,
                color=ANNOTATION, style="italic")


def render_diagram(steps, splits, title, out_path, width=11, height=None):
    """
    steps: list of (label, kind) for the linear flow.
           kind ∈ {"user", "endpoint", "node"}
    splits: dict mapping (after_step_index) -> [(label, kind), ...]
            where the listed boxes appear side-by-side branching from that step
            and rejoining at the next step.
    """
    n_main = len(steps)
    if height is None:
        height = max(8, 1.6 * (n_main + (1 if splits else 0)))

    fig, ax = plt.subplots(figsize=(width, height), dpi=180)
    ax.set_xlim(0, width)
    ax.set_ylim(0, height)
    ax.set_aspect("auto")
    ax.axis("off")

    # Title
    ax.text(width / 2, height - 0.4, title, ha="center", va="top",
            fontsize=15, fontweight="bold", color=TEXT)

    # Compute y positions for main steps; reserve a row for each split block.
    y_top = height - 1.2
    y_bot = 0.7
    rows_used = n_main + sum(1 for _ in splits)
    row_h = (y_top - y_bot) / max(rows_used - 1, 1)

    # Walk through main steps, inserting split rows where needed.
    positions = []  # (label, kind, x, y) for main steps
    splits_drawn = []  # list of (split_y, items, prev_y, next_y)
    cur_y = y_top
    cx = width / 2

    i = 0
    while i < n_main:
        label, kind = steps[i]
        positions.append((label, kind, cx, cur_y))
        # If split follows this step, place split row beneath.
        if i in splits:
            split_y = cur_y - row_h
            splits_drawn.append((split_y, splits[i]))
            cur_y -= 2 * row_h
        else:
            cur_y -= row_h
        i += 1

    # Draw main step boxes.
    box_w = 4.3
    box_h = 0.85
    fills = {"user": (USER_FILL, USER_EDGE),
             "endpoint": (ENDPOINT_FILL, ENDPOINT_EDGE),
             "node": (NODE_FILL, NODE_EDGE)}

    for (label, kind, x, y) in positions:
        f, e = fills[kind]
        # Endpoints (user-facing) get pill-shape feel via slightly narrower
        w = box_w if kind == "node" else box_w
        make_box(ax, x, y, w, box_h, label, f, e, fontsize=10.5,
                 weight="bold" if kind != "node" else "normal")

    # Draw split rows between the matching main steps.
    for split_y, items in splits_drawn:
        # Place items horizontally centered.
        n = len(items)
        gap = width / (n + 1)
        for idx, (lbl, kind) in enumerate(items):
            x = gap * (idx + 1)
            f, e = fills.get(kind, fills["node"])
            make_box(ax, x, split_y, gap * 0.85, box_h, lbl, f, e,
                     fontsize=9.5)

    # Draw arrows along the main path, including through splits.
    # Build a list of "hops" between consecutive main rows. If a split exists
    # between i and i+1, route arrows through the split boxes.
    for i in range(len(positions) - 1):
        _, _, x1, y1 = positions[i]
        _, _, x2, y2 = positions[i + 1]
        if i in splits:
            # arrows from positions[i] down to each split item, then split
            # items down to positions[i+1].
            split_items = splits[i]
            n = len(split_items)
            gap = width / (n + 1)
            split_y = y1 - row_h
            for idx in range(n):
                sx = gap * (idx + 1)
                arrow(ax, x1, y1 - box_h / 2 - 0.02, sx, split_y + box_h / 2 + 0.02)
                arrow(ax, sx, split_y - box_h / 2 - 0.02, x2, y2 + box_h / 2 + 0.02)
        else:
            arrow(ax, x1, y1 - box_h / 2 - 0.02, x2, y2 + box_h / 2 + 0.02)

    plt.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(out_path, dpi=180, bbox_inches="tight",
                facecolor="white", edgecolor="none")
    plt.close()
    print(f"  wrote {out_path}")


# ─── Diagram 1: WhatsApp + Apex ────────────────────────────────────────────
render_diagram(
    steps=[
        ("WhatsApp User", "user"),
        ("Meta Cloud API", "endpoint"),
        ("Salesforce Site → Apex REST class", "node"),
        ("Convert to Meta WhatsApp format", "node"),
        ("POST to Meta Send API\n(via Named Credential)", "node"),
        ("WhatsApp User sees rich response", "user"),
    ],
    splits={
        2: [
            ("Session lookup\n(WhatsApp_Session__c)", "node"),
            ("Agent API call\n(Named Credential)", "node"),
        ],
    },
    title="WhatsApp + Salesforce-hosted webhook (Apex)",
    out_path=OUT_DIR / "whatsapp-webhook" / "option-a-apex" / "architecture.png",
)

# ─── Diagram 2: WhatsApp + Node ────────────────────────────────────────────
render_diagram(
    steps=[
        ("WhatsApp User", "user"),
        ("Meta Cloud API", "endpoint"),
        ("Node.js Express app (/webhook)", "node"),
        ("translateToWhatsApp()\n(convert response formats)", "node"),
        ("POST to Meta Send API\n(graph.facebook.com/v18.0)", "node"),
        ("WhatsApp User sees rich response", "user"),
    ],
    splits={
        2: [
            ("Session lookup\n(in-memory Map)", "node"),
            ("Salesforce OAuth\n(client_credentials)", "node"),
        ],
    },
    title="WhatsApp + Customer-hosted webhook (Node.js)",
    out_path=OUT_DIR / "whatsapp-webhook" / "option-b-node" / "architecture.png",
)

# ─── Diagram 3: Teams + Apex ───────────────────────────────────────────────
render_diagram(
    steps=[
        ("Teams User", "user"),
        ("Bot Framework\n(POST Activity)", "endpoint"),
        ("Salesforce Site → Apex REST class", "node"),
        ("Convert response → Adaptive Cards / Hero Cards", "node"),
        ("POST reply to serviceUrl\n(Bot Framework Connector)", "node"),
        ("Teams User sees rich response", "user"),
    ],
    splits={
        2: [
            ("JWT validation\n(Bot Framework claims)", "node"),
            ("Session lookup\n(Teams_Session__c)", "node"),
            ("Agent API call\n(Named Credential)", "node"),
        ],
    },
    title="Microsoft Teams + Salesforce-hosted webhook (Apex)",
    out_path=OUT_DIR / "teams-webhook" / "option-a-apex" / "architecture.png",
)

# ─── Diagram 4: Teams + Node ───────────────────────────────────────────────
render_diagram(
    steps=[
        ("Teams User", "user"),
        ("Bot Framework (POST /api/messages)", "endpoint"),
        ("Node.js Express app (/api/messages)", "node"),
        ("translateToTeams()\n(convert response formats)", "node"),
        ("POST to Bot Framework REST API\n(serviceUrl/v3/conversations/{id}/activities)", "node"),
        ("Teams User sees rich response", "user"),
    ],
    splits={
        2: [
            ("JWT validation\n(JWKS)", "node"),
            ("Session lookup\n(in-memory Map)", "node"),
            ("Salesforce OAuth\n(client_credentials)", "node"),
        ],
    },
    title="Microsoft Teams + Customer-hosted webhook (Node.js)",
    out_path=OUT_DIR / "teams-webhook" / "option-b-node" / "architecture.png",
)

print("\nDone. Four PNG diagrams written.")
