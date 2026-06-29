# Networking diagrams

draw.io (diagrams.net) diagrams of how Batocera Swarm asset sync works in each
Edge mode. Each file has **two pages**: an **Architecture** view (who talks to
whom, the planes, the data paths) and a **Transfer sequence** (numbered
step-by-step flow).

| File (`enable_edge`) | Shows |
|---|---|
| [`edge-off-lan-direct-p2p.drawio`](edge-off-lan-direct-p2p.drawio) — **Edge OFF** | **No Edge.** Outbound-only control plane; the selector has only `[LAN-direct → direct-public]`. Full P2P on the same LAN; cross-network only to a **port-forwarded** drone (the auto-on reachability probe). No relay, no hole-punch. |
| [`edge-on-holepunch-relay-p2p.drawio`](edge-on-holepunch-relay-p2p.drawio) — **Edge ON** | **Edge deployed.** Every drone holds a persistent **outbound mux** to the Edge. Control plane only mints transfer tokens. Data moves Drone↔Drone over the best tier `LAN → direct-public → hole-punch → relay` (fall-through); the Edge **relays only as a last resort** and never carries bytes on the other tiers. No router config. |

## Opening / editing

- **VS Code:** install the *Draw.io Integration* extension (`hediet.vscode-drawio`)
  and open the `.drawio` file — it renders and edits inline.
- **Browser / desktop:** open at <https://app.diagrams.net> (File → Open) or the
  draw.io desktop app. The files are plain (uncompressed) mxGraph XML, so they
  diff and merge in git.
- **Export** (PNG/SVG for docs): in draw.io, File → Export as → PNG/SVG, or
  `drawio --export --format svg --page-index 0 edge-on-holepunch-relay-p2p.drawio`.

All cells use an explicit dark font on a white page background, so they stay
readable in both light and dark draw.io themes.

## Colour key (both files)

- **Blue** — control plane (Overmind HTTPS): authorize / mint token; never carries ROM bytes.
- **Orange** — the Edge and the persistent outbound mux / relay legs.
- **Green (thick)** — a direct P2P data path (LAN-direct or hole-punched UDP); the Edge carries no bytes.
- **Red dashed** — a path that only works with port-forwarding (`enable_edge=false`).
- **Purple dashed** — lean DB writes (presence, `transfer_sessions`).
- **Grey dashed boxes** — home networks behind NAT.

## See also

- Networking overview + when the Edge is needed: [`../CLAUDE.md`](../CLAUDE.md)
  (Federation overview + AWS Terraform / deploy + cost).
- Code-level depth: the `drone-edge-networking` and `overmind-edge-networking`
  skills in `batocera.drone/` and `batocera.overmind/`.
- Cross-repo relay proof: `.github/tests/test_edge_relay_integration.py`.
