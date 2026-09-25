# OpenStreetMap Full Stack Installer v2.1.5

![Version](https://img.shields.io/badge/version-2.1.5-blue.svg) ![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%20LTS-orange.svg) ![Debian](https://img.shields.io/badge/Debian-13-red.svg) ![Bash](https://img.shields.io/badge/Bash-install.sh-green.svg)

A single interactive `install.sh` for deploying a full self-hosted OpenStreetMap server stack on **Debian 13** (primary target) with **Ubuntu Server 24.04 LTS** as a secondary target.

The installer is intentionally verbose. It uses an ANSI terminal interface, a 12-stage installation progress bar, per-command logging, resumable large downloads, and dynamic country/region discovery from the official Geofabrik index.


## Architecture

The installer builds a native, multi-service OpenStreetMap platform on one Linux host:

```text
                           +----------------------+
                           |      Web Browser     |
                           +----------+-----------+
                                      |
                                HTTP / HTTPS
                                      |
                           +----------v-----------+
                           |       Apache         |
                           | reverse proxy / CGI  |
                           +--+--------+--------+--+
                              |        |        |
                    /tile/    |        |        | /overpass/api/
                              |        |        |
                       +------v--+ +---v-----+ +v----------------+
                       |mod_tile | |Nominatim| |   Overpass API   |
                       |renderd  | |  API/UI  | |dispatcher/areas |
                       +----+----+ +----+-----+ +--------+--------+
                            |           |                |
                         Mapnik      PostgreSQL       Overpass DB
                            |        + PostGIS            |
                            |           |                 |
                       +----v-----------v-----------------v----+
                       |          OpenStreetMap data           |
                       | Geofabrik extracts / planet.osm.pbf   |
                       +----------------+----------------------+
                                        |
                                  +-----v------+
                                  |    OSRM    |
                                  |  Routing   |
                                  +------------+
```

The included Leaflet portal uses the locally hosted services for map display, search, reverse geocoding, and routing.

---

## Requirements

### Supported operating systems

**Primary / recommended target**

- Ubuntu Server **24.04 LTS**, 64-bit, clean or dedicated installation.

**Secondary target**

- Debian **13**, 64-bit, supported on a best-effort basis.

The installer checks `/etc/os-release` before proceeding. Unsupported distributions are rejected.

This release is not intended for Windows, Windows Server, macOS, Alpine, RHEL, Rocky Linux, AlmaLinux, CentOS, or other distributions without adaptation.

### Privileges

You need:

- a user with `sudo` privileges;
- root access during installation;
- permission to install packages, create service accounts, create systemd units, modify Apache configuration, tune PostgreSQL, and create files under `/srv`, `/var/www`, `/var/log`, `/etc`, and `/usr/local/sbin`.

Run the installer with:

```bash
chmod +x install.sh
sudo ./install.sh
```

The script intentionally stops when it is not executed as root.

### Internet access

The initial installation requires outbound Internet access for:

- Ubuntu/Debian APT repositories;
- GitHub source repositories and release assets;
- Geofabrik extracts and its JSON index;
- OpenStreetMap planet and replication services;
- Nominatim-related Python packages;
- the official Overpass release tarball;
- Leaflet static assets;
- Let's Encrypt / Certbot when HTTPS is enabled.

A disconnected/offline installation is not currently supported.

### Automatically installed software

The installer attempts to install all required packages automatically. The package set includes, when available on the selected OS:

```text
ca-certificates curl wget aria2 jq pv rsync tar unzip bzip2 xz-utils gzip zip
sudo less git screen tmux htop iotop sysstat net-tools dnsutils lsof tree
dialog whiptail
build-essential gcc g++ make cmake ninja-build pkg-config autoconf automake
libtool expat libexpat1-dev zlib1g-dev liblz4-dev libbz2-dev
libxml2-dev libzip-dev libboost-all-dev libtbb-dev libicu-dev
libprotobuf-dev protobuf-compiler lua5.2 liblua5.2-dev
apache2 libapache2-mod-tile renderd
mapnik-utils python3-mapnik
python3 python3-dev python3-pip python3-venv virtualenv
python3-psycopg2 python3-psycopg python3-yaml
gdal-bin npm node-carto
postgresql postgresql-contrib postgis
postgresql-postgis postgresql-postgis-scripts
osm2pgsql osmium-tool
certbot python3-certbot-apache
bc acl cron logrotate
```

The installer also installs the Carto compiler through npm.

OSRM is used from the distribution package when available. If it is not available, the installer can build OSRM from source.

### Hardware sizing

OpenStreetMap workloads scale primarily with the size of the imported area, the number of services enabled, query concurrency, update frequency, and tile-cache growth.

The table below is a practical planning guide for this **combined full stack**:

| Deployment | CPU | RAM | Fast storage | Typical use |
|---|---:|---:|---:|---|
| Lab / small city | 2-4 cores | 8 GB | 50-100 GB SSD | Testing, development, small extracts |
| Small country | 4-8 cores | 16 GB | 150-300 GB SSD/NVMe | Recommended entry production size |
| Medium country | 8+ cores | 32 GB | 300-750 GB NVMe | Rendering + search + routing + Overpass |
| Large country / busy service | 12-16+ cores | 64 GB | 750 GB-1.5 TB NVMe | Higher concurrency and larger databases |
| Full planet | 16+ cores | **128 GB+ recommended** | **2 TB+ NVMe planning minimum for the combined stack** | Serious dedicated hardware |

These are planning recommendations rather than hard limits.

Upstream guidance provides useful lower-level reference points:

- Switch2OSM describes tile-serving hardware ranging from approximately **4 GB RAM and 10-20 GB storage for a city-sized extract** to around **24 GB RAM and 1 TB of fast storage for full-planet tile serving**.
- Current Nominatim documentation states that **2 GB RAM is the absolute minimum for installation**, recommends **128 GB RAM or more for a full-planet import**, and requires **at least 1 TB of disk** for a planet installation. Fast disks are essential and NVMe is recommended.
- The Overpass own-instance documentation recommends approximately **500 GB to 1 TB of disk** for a large/global deployment. Exact usage depends on whether metadata and attic/history data are retained.

Because this project can run **rendering, Nominatim, OSRM, Overpass and tile cache on the same server**, do not size the machine using only the minimum requirement of a single component.

### Why a planet deployment needs more storage

A full-stack system stores the same OpenStreetMap source data in multiple optimized forms:

- the downloaded `.osm.pbf`;
- PostgreSQL/PostGIS rendering tables;
- Nominatim search database;
- OSRM routing graph;
- Overpass database;
- renderd/mod_tile cache;
- temporary import data;
- update/replication state;
- backups and logs.

For that reason, a machine with exactly 1 TB free space may be sufficient for one individual component but is not a safe target for the **entire** planet-scale stack.

### Storage type

Recommended:

- NVMe SSD for production;
- enterprise or high-endurance SSD/NVMe for write-heavy systems;
- separate database/tile-cache volumes on larger installations;
- enough free space for imports and temporary conversion files;
- regular monitoring of free disk space.

Avoid conventional HDDs for serious planet-scale Nominatim/Overpass deployments. Avoid USB-attached consumer storage for production databases.

### RAM and swap

Swap can provide an emergency margin, but it is not a substitute for physical RAM.

For small test systems a modest swap file is useful. For large-country and planet imports, provision sufficient physical RAM instead of relying on swap.

### CPU

Rendering, imports, OSRM preprocessing, database indexing and source builds benefit from additional CPU cores.

The installer uses `nproc` in several operations to take advantage of available CPUs.

### Network and firewall

Typical inbound ports:

| Port | Protocol | Required for |
|---:|---|---|
| 22 | TCP | SSH administration |
| 80 | TCP | HTTP, Apache, Let's Encrypt HTTP challenge |
| 443 | TCP | HTTPS after Certbot configuration |

Internal/local services:

| Port / socket | Purpose |
|---|---|
| `127.0.0.1:5000` | OSRM backend, proxied by Apache |
| `/run/nominatim.sock` | Nominatim Gunicorn Unix socket |
| PostgreSQL local socket | PostgreSQL/PostGIS access |

Do **not** expose PostgreSQL or OSRM port 5000 directly to the Internet unless you explicitly require it and have appropriate firewall/authentication controls.

### DNS requirements

DNS is not required for local IP-based testing.

For the integrated Let's Encrypt option you need:

1. a public hostname;
2. an A/AAAA record pointing at the server;
3. inbound TCP 80/443 allowed;
4. a valid email address for certificate notices.

Example:

```text
maps.example.com -> YOUR_SERVER_PUBLIC_IP
```

### Recommended pre-flight checklist

Before running a large import:

```bash
cat /etc/os-release
nproc
free -h
df -h
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
ip addr
```

Confirm that:

- the OS is correct;
- the expected storage volume is mounted;
- enough disk space is free;
- RAM is sufficient for the chosen dataset;
- DNS is correct if HTTPS will be configured;
- the server has stable Internet connectivity;
- there is a backup/snapshot if this is not a disposable server.

### Full-planet warning

A planet deployment is a major database workload, not a normal package installation.

Nominatim alone can take multiple days to import the planet depending on hardware. Overpass and rendering add their own storage and I/O requirements.

Test this project first with a small Geofabrik extract before importing the full planet.

### Requirement references

- Switch2OSM hardware overview: https://switch2osm.org/serving-tiles/
- Ubuntu 24.04 tile server guide: https://switch2osm.org/serving-tiles/manually-building-a-tile-server-ubuntu-24-04-lts/
- Debian 13 tile server guide: https://switch2osm.org/serving-tiles/manually-building-a-tile-server-debian-13/
- Nominatim installation/hardware: https://nominatim.org/release-docs/latest/admin/Installation/
- Overpass own-instance setup: https://dev.overpass-api.de/overpass-doc/en/more_info/setup.html

---

## Repository layout

```text
OpenStreetMap-Full-Stack-Installer-v1.0.0/
├── install.sh
└── README.md
```

The project deliberately keeps deployment simple: the installer is self-contained and downloads/builds its runtime components as required.

---

## Quick start

```bash
git clone https://github.com/antonismor/OpenStreetMap-Full-Stack-Installer-v1.0.0.git
cd OpenStreetMap-Full-Stack-Installer-v1.0.0
chmod +x install.sh
sudo ./install.sh
```

Recommended initial menu sequence:

```text
1) FULL SOFTWARE INSTALL — all stack components
2) Full Auto Country Deployment — download + import everywhere
5) Health / service status
```

---

## Installed stack

- PostgreSQL + PostGIS + HStore
- osm2pgsql + osmium-tool
- OpenStreetMap Carto v5.9.0 classic rendering schema
- Mapnik
- renderd + mod_tile + Apache
- Raster tile endpoint: `/tile/{z}/{x}/{y}.png`
- Nominatim geocoding + reverse geocoding API
- Official Nominatim UI
- OSRM routing backend using the latest fetched stable OSRM release tag
- OSRM HTTP proxy under `/route/`
- Overpass API database, dispatcher, area dispatcher and area rules processor
- Overpass HTTP CGI endpoints under `/overpass/api/`
- Local Leaflet web portal under `/osm/`
- Search, reverse geocoding and click-to-route in the portal
- Dynamic Geofabrik country and region downloader
- Download-all-countries mode
- Full planet downloader + MD5 verification
- Resumable downloads using aria2, with curl fallback
- osm2pgsql replication initialization and optional systemd update timer
- Let's Encrypt / Certbot HTTPS menu
- Health-check command (`osm-health`)
- Nightly configuration backups
- Logrotate
- PostgreSQL tuning based on installed RAM
- systemd service management

## Country / data menu

The list is **not hard-coded**. Every time you open the downloader, `install.sh` refreshes:

`https://download.geofabrik.de/index-v1.json`

Available modes:

1. Countries only — ISO-3166 extracts
2. All Geofabrik extracts — countries, regions and subregions
3. Download ALL country extracts
4. Download the full OSM planet PBF
5. Show locally downloaded datasets

You can search by country/region name, ISO code or Geofabrik internal id.

## Full Auto Country Deployment

After the software stack is installed, select **Full Auto Country Deployment**. Pick a country once and the installer will use the same local PBF to populate:

- rendering database / raster tiles
- Nominatim
- OSRM
- Overpass API
- local Leaflet portal

This mode is intended for a clean initial deployment of one country. Do not use it to merge unrelated country imports into an already-populated Nominatim or Overpass database without planning the database layout first.

## Installation

```bash
chmod +x install.sh
sudo ./install.sh
```

Verbose command output is enabled by default. To keep the full log while suppressing command echo:

```bash
sudo env OSM_VERBOSE=0 ./install.sh
```

The full installer log is written to:

```text
/var/log/osm-fullstack/install-YYYYMMDD-HHMMSS.log
```

## Recommended first run

Run these menu options in order:

```text
1) FULL SOFTWARE INSTALL — all stack components
2) Full Auto Country Deployment — download + import everywhere
5) Health / service status
```

For manual control, use the Country / Region Download Manager first, then import a chosen local PBF independently into rendering, Nominatim, OSRM or Overpass from the Advanced menu.

## Main endpoints

After importing data:

| Function | Local path / endpoint |
|---|---|
| Web map portal | `/osm/` |
| Raster tiles | `/tile/{z}/{x}/{y}.png` |
| Nominatim search | `/nominatim/search` |
| Nominatim reverse | `/nominatim/reverse` |
| Nominatim UI | `/nominatim-ui/` |
| OSRM | `/route/route/v1/...` and other OSRM APIs |
| Overpass query | `/overpass/api/interpreter` |
| Overpass timestamp | `/overpass/api/timestamp` |
| Overpass status | `/overpass/api/status` |

## Services

Depending on which imports have been completed, the system manages:

```text
postgresql
apache2
renderd
nominatim.socket
nominatim.service
osrm.service
overpass-dispatcher.service
overpass-areas.service
overpass-rules.service
osm2pgsql-update.timer
```

Run:

```bash
sudo osm-health
```

to see service state, listening ports, Overpass HTTP readiness, disk usage and downloaded datasets.

## Storage and hardware warning

Country extracts can be practical on a normal dedicated server, but **full-planet deployments are a different class of workload**. Nominatim requires at least 2 GB RAM even for installation, while full-planet Nominatim and Overpass deployments require very large SSD/NVMe storage and substantially more memory for reasonable performance. The installer therefore requires explicit confirmation before downloading the full planet or every country extract.

Do not start a full-planet import without checking free disk space and RAM first.

## OpenStreetMap Carto version

The installer intentionally pins OpenStreetMap Carto to **v5.9.0** for the classic `osm2pgsql` schema used by the current Ubuntu 24.04 Switch2OSM path. It applies `indexes.sql`, `functions.sql`, downloads external data and fonts, and compiles `project.mml` to Mapnik XML.

## Overpass API

Overpass is built from the official latest release tarball. The installer keeps the complete `bin/` and `cgi-bin/` trees together, imports PBF data by streaming it through `osmium` to OSM XML/BZip2, and exposes the standard CGI endpoints through Apache.

## OSRM

If the operating system provides `osrm-backend`, it is used. Otherwise the installer builds OSRM from source using the newest fetched stable release tag and the current upstream vcpkg/CMake workflow. The default imported profile is `car.lua` and the server uses MLD.

## HTTPS

Use:

```text
Advanced imports / updates / HTTPS / maintenance
  -> Configure HTTPS with Certbot
```

You need a public DNS name already pointing at the server and a valid email address for Let's Encrypt.

## Validation performed on this package

The generated script has been checked with:

- `bash -n install.sh`
- root menu startup/exit test
- non-root startup test (clean `sudo ./install.sh` error)
- menu/runtime smoke tests
- dynamic country-menu parsing tests using a Geofabrik-shaped index sample

A real full-planet import is deliberately **not** performed as a packaging test because it is a destructive, storage-intensive, long-running server operation. Test first with a small Geofabrik extract on a clean VM before using production data.

## Upstream references

- Switch2OSM Ubuntu 24.04 tile-server guide: https://switch2osm.org/serving-tiles/manually-building-a-tile-server-ubuntu-24-04-lts/
- Geofabrik downloads: https://download.geofabrik.de/
- Geofabrik JSON index: https://download.geofabrik.de/index-v1.json
- Nominatim documentation: https://nominatim.org/release-docs/latest/
- OSRM backend: https://github.com/Project-OSRM/osrm-backend
- Overpass own-instance documentation: https://dev.overpass-api.de/overpass-doc/en/more_info/setup.html
- mod_tile: https://github.com/openstreetmap/mod_tile
- OpenStreetMap Carto: https://github.com/openstreetmap-carto/openstreetmap-carto

## Important operational note

This installer is designed to provide the major native components of a self-hosted OSM stack. OpenStreetMap is an ecosystem rather than one monolithic product; there are many additional specialist third-party projects that can be deployed separately. The script deliberately focuses on the complete core stack for raster maps, search, reverse geocoding, routing, Overpass queries, downloads, administration, HTTPS, health and maintenance.