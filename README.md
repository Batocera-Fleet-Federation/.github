# Batocera Fleet Federation
![Batocera Fleet Federation](./main.jpeg)

Batocera Fleet Federation is a lightweight, self-hosted platform for managing, monitoring, and automating one or many Batocera retro gaming systems.

Inspired by the StarCraft Zerg hierarchy, the ecosystem is built around three primary components:

- **Overmind** — centralized fleet management and orchestration
- **Drone** — lightweight agent running on Batocera devices
- **Hive Mind** *(planned)* — future peer-to-peer federation layer

The project brings modern infrastructure management concepts to retro gaming environments by providing centralized visibility, remote diagnostics, metadata validation, artwork integrity checks, and secure remote management capabilities.

---

# Core Components

## Overmind

The Overmind is the centralized management platform for the Federation ecosystem.

It provides:
- Fleet-wide dashboards
- ROM and metadata visibility
- Artwork validation
- Health monitoring
- Remote diagnostics
- Administrative APIs
- PostgreSQL-backed persistence
- Multi-device orchestration

The Overmind acts as the control plane for managing connected Batocera systems.

---

## Drone

The Drone is a lightweight agent installed directly on Batocera systems.

It is responsible for:
- Reporting system health and telemetry
- Scanning ROM inventories
- Validating metadata and artwork
- Hosting local APIs
- Supporting remote diagnostics
- Secure communication with the Overmind

Each Batocera machine becomes a manageable node within the Federation ecosystem.

---

## Hive Mind (Planned)

The Hive Mind is the planned peer-to-peer federation layer.

Future goals include:
- Drone-to-drone communication
- Distributed synchronization
- Shared metadata propagation
- Federated discovery
- Reduced dependency on centralized infrastructure

---

# Goals

Batocera Fleet Federation aims to solve common operational challenges for Batocera power users and arcade builders, including:

- Managing multiple Batocera systems
- Detecting broken gamelist entries
- Identifying missing artwork or metadata
- Simplifying remote administration
- Centralizing visibility into ROM collections
- Automating maintenance workflows
- Supporting large-scale retro gaming deployments

The platform is designed to remain lightweight and compatible with low-resource gaming hardware.

---

# Features

Current and planned features include:

- Fleet management dashboard
- Secure token-based authentication
- PostgreSQL persistence
- Lightweight local Drone databases
- ROM inventory scanning
- Metadata validation
- Missing artwork detection
- REST APIs
- Health endpoints
- Remote diagnostics
- IPv4/IPv6 support
- Batocera-native integrations
- Future P2P federation support

---

# Installation

## Drone

Install on a Batocera system:

```bash
curl -fsSL https://raw.githubusercontent.com/Batocera-Fleet-Federation/batocera.drone/main/scripts/run_now.sh | bash