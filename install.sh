#!/usr/bin/env bash
# ============================================================================
# OpenStreetMap Full Stack Installer
# Version: 2.1.4
# Target: Debian 13 (primary), Ubuntu Server 24.04 LTS (secondary)
# Components:
#   - PostgreSQL + PostGIS
#   - osm2pgsql + osmium-tool
#   - OpenStreetMap Carto + Mapnik
#   - renderd + mod_tile + Apache
#   - Nominatim (geocoding / reverse geocoding) + official Nominatim UI
#   - OSRM (routing)
#   - Overpass API (local OSM query engine) + HTTP CGI endpoints
#   - Leaflet web portal
#   - Geofabrik dynamic country/region downloader
#   - Planet downloader
#   - osm2pgsql replication updater + systemd timer
#   - Health checks, logs, system tuning, backups
#
# Run:
#   chmod +x install.sh
#   sudo ./install.sh
#
# Verbose is ON by default. Disable command echo with: OSM_VERBOSE=0 sudo ./install.sh
# ============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="2.1.5"
APP_NAME="OpenStreetMap Full Stack Installer"
OSM_VERBOSE="${OSM_VERBOSE:-1}"

BASE_DIR="${OSM_BASE_DIR:-/srv/osm}"
DATA_DIR="$BASE_DIR/data"
SRC_DIR="$BASE_DIR/src"
STATE_DIR="$BASE_DIR/state"
BACKUP_DIR="$BASE_DIR/backups"
WEB_DIR="/var/www/html/osm"
LOG_DIR="/var/log/osm-fullstack"
LOG_FILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
APACHE_PORT="${OSM_APACHE_PORT:-8080}"
TELEMETRY_USER="${OSM_TELEMETRY_USER:-osmtelemetry}"
TELEMETRY_HOME="${OSM_TELEMETRY_HOME:-/opt/osm-telemetry}"
TELEMETRY_PORT="${OSM_TELEMETRY_PORT:-9018}"
TELEMETRY_DB="${OSM_TELEMETRY_DB:-osmtelemetry}"

GIS_DB="${OSM_GIS_DB:-gis}"
GIS_USER="${OSM_GIS_USER:-_renderd}"
CARTO_DIR="$SRC_DIR/openstreetmap-carto"
CARTO_TAG="${OSM_CARTO_TAG:-v6.0.0}"
TILE_URI="${OSM_TILE_URI:-/tile/}"

NOM_USER="nominatim"
NOM_HOME="/srv/nominatim"
NOM_VENV="$NOM_HOME/nominatim-venv"
NOM_PROJECT="/srv/nominatim-project"
NOM_UI_DIR="/var/www/html/nominatim-ui"

OSRM_DATA="$BASE_DIR/osrm-data"
OSRM_SRC="$SRC_DIR/osrm-backend"
OSRM_PORT="${OSRM_PORT:-5000}"

OVERPASS_USER="overpass"
OVERPASS_ROOT="/srv/overpass"
OVERPASS_EXEC="$OVERPASS_ROOT/app"
OVERPASS_DB="$OVERPASS_ROOT/db"
OVERPASS_DIFF="$OVERPASS_ROOT/diffs"
OVERPASS_SRC="$SRC_DIR/overpass-api"

GEOFABRIK_INDEX="https://download.geofabrik.de/index-v1.json"
PLANET_PBF="https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf"
PLANET_MD5="https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf.md5"

TOTAL_STEPS=13
CURRENT_STEP=0

# ANSI colors
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
MAGENTA='\033[35m'
CYAN='\033[36m'
WHITE='\033[97m'
BG_BLUE='\033[44m'

# Initialise logging even when the user accidentally starts without sudo,
# so require_root() can still display a clean error instead of failing in /var/log.
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  LOG_DIR="${TMPDIR:-/tmp}/osm-fullstack-$(id -u)"
  LOG_FILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
fi
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE" || true
exec > >(tee -a "$LOG_FILE") 2>&1

banner() {
  clear || true
  printf "%b" "$CYAN$BOLD"
  cat <<'ART'
   ____                   ____  _                 _   __  __             
  / __ \ _ __   ___ _ __/ ___|| |_ _ __ ___  ___| |_|  \/  | __ _ _ __  
 / / _` | '_ \ / _ \ '_ \___ \| __| '__/ _ \/ _ \ __| |\/| |/ _` | '_ \ 
| | (_| | |_) |  __/ | | |__) | |_| | |  __/  __/ |_| |  | | (_| | |_) |
 \ \__,_| .__/ \___|_| |_|____/ \__|_|  \___|\___|\__|_|  |_|\__,_| .__/ 
  \____/|_|                                                       |_|      
ART
  printf "%b\n" "$RESET"
  printf "%b%s v%s%b\n" "$WHITE$BOLD" "$APP_NAME" "$SCRIPT_VERSION" "$RESET"
  printf "%bDebian 13 native OSM stack • Apache :%s backend for NPM • ANSI UI%b\n" "$DIM" "$APACHE_PORT" "$RESET"
  printf "%bLog: %s%b\n\n" "$DIM" "$LOG_FILE" "$RESET"
}

info()    { printf "%b[INFO ]%b %s\n" "$CYAN" "$RESET" "$*"; }
success() { printf "%b[ OK  ]%b %s\n" "$GREEN" "$RESET" "$*"; }
warn()    { printf "%b[WARN ]%b %s\n" "$YELLOW" "$RESET" "$*"; }
error()   { printf "%b[FAIL ]%b %s\n" "$RED" "$RESET" "$*" >&2; }

pause() {
  printf "\n%bPress ENTER to continue...%b" "$DIM" "$RESET"
  read -r _ || true
}

on_error() {
  local exit_code=$?
  local line=${BASH_LINENO[0]:-unknown}
  error "Command failed at line $line with exit code $exit_code"
  error "See full log: $LOG_FILE"
  exit "$exit_code"
}
trap on_error ERR

run() {
  if [[ "$OSM_VERBOSE" == "1" ]]; then
    printf "%b+%b %s\n" "$MAGENTA" "$RESET" "$(printf '%q ' "$@")"
  fi
  "$@"
}

as_user() {
  local user="$1"; shift
  if [[ "$OSM_VERBOSE" == "1" ]]; then
    printf "%b+ sudo -u %s --%b %s\n" "$MAGENTA" "$user" "$RESET" "$(printf '%q ' "$@")"
  fi
  sudo -H -u "$user" -- "$@"
}

step_bar() {
  local label="$1"
  CURRENT_STEP=$((CURRENT_STEP + 1))
  local pct=$((CURRENT_STEP * 100 / TOTAL_STEPS))
  local width=40
  local filled=$((pct * width / 100))
  local empty=$((width - filled))
  printf "\n%b[%02d/%02d]%b %-42s [" "$BOLD$BLUE" "$CURRENT_STEP" "$TOTAL_STEPS" "$RESET" "$label"
  printf "%b" "$GREEN"
  printf '%*s' "$filled" '' | tr ' ' '█'
  printf "%b" "$DIM"
  printf '%*s' "$empty" '' | tr ' ' '░'
  printf "%b] %3d%%%b\n" "$RESET" "$pct" "$RESET"
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    error "Run this installer as root: sudo ./install.sh"
    exit 1
  fi
}

load_os_release() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  else
    error "/etc/os-release not found. Unsupported operating system."
    exit 1
  fi

  case "${ID:-}" in
    ubuntu)
      if [[ "${VERSION_ID:-}" != "24.04" ]]; then
        warn "Secondary Ubuntu target is 24.04 LTS; detected Ubuntu ${VERSION_ID:-unknown}."
      fi
      ;;
    debian)
      if [[ "${VERSION_ID:-}" != "13" ]]; then
        warn "Primary tested Debian target is Debian 13; detected Debian ${VERSION_ID:-unknown}."
      fi
      ;;
    *)
      error "Unsupported distribution: ${PRETTY_NAME:-unknown}. Use Ubuntu 24.04 LTS for full native install."
      exit 1
      ;;
  esac
}

hardware_report() {
  local ram_gb cpu disk_gb
  ram_gb=$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
  cpu=$(nproc)
  disk_gb=$(df -BG "$BASE_DIR" 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}' || true)
  printf "%bSystem:%b %s\n" "$BOLD" "$RESET" "${PRETTY_NAME:-unknown}"
  printf "%bCPU:%b    %s logical cores\n" "$BOLD" "$RESET" "$cpu"
  printf "%bRAM:%b    %s GiB\n" "$BOLD" "$RESET" "$ram_gb"
  [[ -n "$disk_gb" ]] && printf "%bFree:%b   %s GiB on %s\n" "$BOLD" "$RESET" "$disk_gb" "$BASE_DIR"
}

ensure_dirs() {
  run mkdir -p "$BASE_DIR" "$DATA_DIR" "$SRC_DIR" "$STATE_DIR" "$BACKUP_DIR" "$OSRM_DATA" "$WEB_DIR"
  run chmod 755 "$BASE_DIR" "$DATA_DIR" "$SRC_DIR" "$STATE_DIR" "$WEB_DIR"
}

apt_install_available() {
  local wanted=() pkg
  for pkg in "$@"; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      wanted+=("$pkg")
    else
      warn "APT package not available on this OS release, skipping: $pkg"
    fi
  done
  if ((${#wanted[@]})); then
    DEBIAN_FRONTEND=noninteractive run apt-get install -y --no-install-recommends "${wanted[@]}"
  fi
}


configure_apache_backend_port() {
  info "Configuring Apache backend for Nginx Proxy Manager on TCP ${APACHE_PORT}..."

  if [[ -f /etc/apache2/ports.conf && ! -f /etc/apache2/ports.conf.osm-original ]]; then
    run cp -a /etc/apache2/ports.conf /etc/apache2/ports.conf.osm-original
  fi
  if [[ -f /etc/apache2/sites-available/000-default.conf && ! -f /etc/apache2/sites-available/000-default.conf.osm-original ]]; then
    run cp -a /etc/apache2/sites-available/000-default.conf /etc/apache2/sites-available/000-default.conf.osm-original
  fi

  if grep -Eq '^[[:space:]]*Listen[[:space:]]+80([[:space:]]|$)' /etc/apache2/ports.conf; then
    run sed -ri "s/^[[:space:]]*Listen[[:space:]]+80([[:space:]]*)$/Listen ${APACHE_PORT}\1/" /etc/apache2/ports.conf
  elif ! grep -Eq "^[[:space:]]*Listen[[:space:]]+${APACHE_PORT}([[:space:]]|$)" /etc/apache2/ports.conf; then
    printf '\nListen %s\n' "$APACHE_PORT" >> /etc/apache2/ports.conf
  fi

  if [[ -f /etc/apache2/sites-available/000-default.conf ]]; then
    run sed -ri "s#<VirtualHost[[:space:]]+\*:80>#<VirtualHost *:${APACHE_PORT}>#g" /etc/apache2/sites-available/000-default.conf
  fi

  run apache2ctl configtest
  run systemctl restart apache2
  success "Apache backend ready on http://SERVER:${APACHE_PORT}/"
}

install_packages() {
  step_bar "System packages and build tools"
  run apt-get update
  apt_install_available \
    ca-certificates curl wget aria2 jq pv rsync tar unzip bzip2 xz-utils gzip zip sudo less \
    git screen tmux htop iotop sysstat net-tools dnsutils lsof tree dialog whiptail \
    build-essential g++ gcc make cmake ninja-build pkg-config autoconf automake libtool \
    expat libexpat1-dev zlib1g-dev liblz4-dev libbz2-dev libxml2-dev libzip-dev \
    libboost-all-dev libtbb-dev libicu-dev libprotobuf-dev protobuf-compiler \
    lua5.1 liblua5.1-0-dev lua5.4 liblua5.4-dev \
    apache2 libapache2-mod-tile renderd \
    mapnik-utils python3-mapnik python3-psycopg2 python3-psycopg python3-yaml python3-requests \
    python3 python3-dev python3-pip python3-venv virtualenv \
    gdal-bin npm node-carto \
    postgresql postgresql-contrib postgis postgresql-postgis postgresql-postgis-scripts \
    osm2pgsql osmium-tool \
    bc acl cron logrotate

  if apt-cache show osrm-backend >/dev/null 2>&1; then
    apt_install_available osrm-backend
  fi

  run npm install -g carto
  run systemctl enable --now apache2
  configure_apache_backend_port
  success "Base packages installed."
}

create_service_users() {
  step_bar "Service users and directories"

  id "$GIS_USER" >/dev/null 2>&1 || run useradd --system --user-group --home-dir "$BASE_DIR" --shell /usr/sbin/nologin "$GIS_USER"
  id "$NOM_USER" >/dev/null 2>&1 || run useradd --user-group -d "$NOM_HOME" -s /bin/bash -m "$NOM_USER"
  id "$OVERPASS_USER" >/dev/null 2>&1 || run useradd --user-group -d "$OVERPASS_ROOT" -s /bin/bash -m "$OVERPASS_USER"
  id "$TELEMETRY_USER" >/dev/null 2>&1 || run useradd --system --user-group --home-dir "$TELEMETRY_HOME" --shell /usr/sbin/nologin "$TELEMETRY_USER"

  run mkdir -p "$NOM_HOME" "$NOM_PROJECT" "$OVERPASS_ROOT" "$OVERPASS_DB" "$OVERPASS_DIFF" "$TELEMETRY_HOME" "$BASE_DIR/updates" /var/cache/renderd/tiles
  run chown -R "$NOM_USER:$NOM_USER" "$NOM_HOME" "$NOM_PROJECT"
  run chown -R "$OVERPASS_USER:$OVERPASS_USER" "$OVERPASS_ROOT"
  run chown -R "$GIS_USER:$GIS_USER" /var/cache/renderd
  run chmod a+x "$NOM_HOME"
  success "Service users prepared."
}

setup_postgres() {
  step_bar "PostgreSQL / PostGIS databases"
  run systemctl enable --now postgresql

  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$GIS_USER'" | grep -q 1; then
    run sudo -u postgres createuser "$GIS_USER"
  fi
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$GIS_DB'" | grep -q 1; then
    run sudo -u postgres createdb -E UTF8 -O "$GIS_USER" "$GIS_DB"
  fi

  run sudo -u postgres psql -d "$GIS_DB" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS postgis;"
  run sudo -u postgres psql -d "$GIS_DB" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS hstore;"
  run sudo -u postgres psql -d "$GIS_DB" -v ON_ERROR_STOP=1 -c "ALTER TABLE IF EXISTS geometry_columns OWNER TO \"$GIS_USER\";" || true
  run sudo -u postgres psql -d "$GIS_DB" -v ON_ERROR_STOP=1 -c "ALTER TABLE IF EXISTS spatial_ref_sys OWNER TO \"$GIS_USER\";" || true

  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$NOM_USER'" | grep -q 1; then
    run sudo -u postgres createuser -s "$NOM_USER"
  fi
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='www-data'" | grep -q 1; then
    run sudo -u postgres createuser www-data
  fi

  tune_postgres
  success "PostgreSQL/PostGIS ready."
}

tune_postgres() {
  local mem_kb mem_mb shared_mb cache_mb maint_mb
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  mem_mb=$((mem_kb / 1024))
  shared_mb=$((mem_mb / 4))
  cache_mb=$((mem_mb * 3 / 5))
  maint_mb=$((mem_mb / 8))
  ((shared_mb < 128)) && shared_mb=128
  ((maint_mb < 128)) && maint_mb=128
  ((maint_mb > 4096)) && maint_mb=4096

  info "Applying conservative PostgreSQL tuning for ${mem_mb} MiB RAM."
  run sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER SYSTEM SET shared_buffers='${shared_mb}MB';"
  run sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER SYSTEM SET effective_cache_size='${cache_mb}MB';"
  run sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER SYSTEM SET maintenance_work_mem='${maint_mb}MB';"
  run sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER SYSTEM SET work_mem='16MB';"
  run sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER SYSTEM SET max_wal_size='4GB';"
  run sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER SYSTEM SET checkpoint_timeout='15min';"
  run sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER SYSTEM SET random_page_cost='1.1';"
  run sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER SYSTEM SET jit=off;"
  run systemctl restart postgresql
}

install_carto() {
  step_bar "OpenStreetMap Carto / Mapnik style"

  if [[ ! -d "$CARTO_DIR/.git" ]]; then
    run rm -rf "$CARTO_DIR"
    run git clone https://github.com/openstreetmap-carto/openstreetmap-carto.git "$CARTO_DIR"
  fi

  # Keep the tree owned by the rendering user. This also makes reruns safe
  # from Git's dubious-ownership protection.
  run chown -R "$GIS_USER:$GIS_USER" "$CARTO_DIR"

  as_user "$GIS_USER" git -C "$CARTO_DIR" fetch --all --tags --prune
  as_user "$GIS_USER" git -C "$CARTO_DIR" checkout --detach "$CARTO_TAG"

  [[ -f "$CARTO_DIR/openstreetmap-carto-flex.lua" ]] || {
    error "Carto v6 flex configuration is missing: $CARTO_DIR/openstreetmap-carto-flex.lua"
    return 1
  }

  # Carto v6 requires CartoCSS >=1.2 and Mapnik API >=3.0.22.
  as_user "$GIS_USER" bash -lc "cd '$CARTO_DIR' && carto -a '3.0.22' project.mml > mapnik.xml"

  # v6 replaced the old get-fonts.sh helper with get-fonts.py.
  if [[ -f "$CARTO_DIR/scripts/get-fonts.py" ]]; then
    as_user "$GIS_USER" bash -lc "cd '$CARTO_DIR' && python3 scripts/get-fonts.py" ||       warn "Font helper returned an error; continuing so the installer can finish."
  fi

  if [[ -f "$CARTO_DIR/scripts/get-external-data.py" ]]; then
    run mkdir -p "$CARTO_DIR/data"
    run chown -R "$GIS_USER:$GIS_USER" "$CARTO_DIR/data"
  fi

  success "OpenStreetMap Carto ${CARTO_TAG} flex style prepared."
}

configure_rendering() {
  step_bar "renderd / mod_tile / Apache"

  local mapnik_plugins
  mapnik_plugins=$(find /usr/lib -type d -path '*/mapnik/*/input' 2>/dev/null | head -n1 || true)
  [[ -z "$mapnik_plugins" ]] && mapnik_plugins="/usr/lib/mapnik/3.1/input"

  cat > /etc/renderd.conf <<EOF_RENDERD
[renderd]
num_threads=$(nproc)
tile_dir=/var/cache/renderd/tiles
stats_file=/run/renderd/renderd.stats

[mapnik]
plugins_dir=$mapnik_plugins
font_dir=/usr/share/fonts/truetype
font_dir_recurse=true

[osm]
URI=$TILE_URI
TILEDIR=/var/cache/renderd/tiles
XML=$CARTO_DIR/mapnik.xml
HOST=localhost
TILESIZE=256
MAXZOOM=20
EOF_RENDERD

  run mkdir -p /var/cache/renderd/tiles /run/renderd
  run chown -R "$GIS_USER:$GIS_USER" /var/cache/renderd /run/renderd

  # The Ubuntu package uses _renderd. If our variable differs, override systemd user safely.
  run mkdir -p /etc/systemd/system/renderd.service.d
  cat > /etc/systemd/system/renderd.service.d/override.conf <<EOF_RENDERD_UNIT
[Service]
User=$GIS_USER
Group=$GIS_USER
Environment=G_MESSAGES_DEBUG=all
EOF_RENDERD_UNIT

  if [[ ! -f /etc/apache2/conf-available/renderd.conf ]]; then
    run curl -fL --retry 4 --progress-bar \
      -o /etc/apache2/conf-available/renderd.conf \
      https://raw.githubusercontent.com/openstreetmap/mod_tile/python-implementation/etc/apache2/renderd.conf
  fi

  run a2enmod tile proxy proxy_http headers rewrite expires deflate cgi
  run a2enconf renderd

  cat > /etc/apache2/conf-available/osm-fullstack.conf <<'EOF_APACHE'
# OpenStreetMap Full Stack endpoints
ProxyPreserveHost On
ProxyPass        /nominatim unix:/run/nominatim.sock|http://localhost/
ProxyPassReverse /nominatim unix:/run/nominatim.sock|http://localhost/

ProxyPass        /route/ http://127.0.0.1:5000/
ProxyPassReverse /route/ http://127.0.0.1:5000/

# Overpass API CGI endpoints: interpreter, timestamp, status, kill_my_queries.
# Keep both the project-prefixed endpoint and the conventional /api/ endpoint.
ScriptAlias /overpass/api/ /srv/overpass/app/cgi-bin/
ScriptAlias /api/ /srv/overpass/app/cgi-bin/
<Directory /srv/overpass/app/cgi-bin>
    AllowOverride None
    Options +ExecCGI -MultiViews +SymLinksIfOwnerMatch
    Require all granted
</Directory>

Alias /nominatim-ui/ /var/www/html/nominatim-ui/
<Directory /var/www/html/nominatim-ui>
    Options FollowSymLinks
    AllowOverride None
    Require all granted
    DirectoryIndex search.html index.html
</Directory>

<Directory /var/www/html/osm>
    Options FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>

Header always set X-Content-Type-Options "nosniff"
Header always set Referrer-Policy "strict-origin-when-cross-origin"
EOF_APACHE

  run a2enconf osm-fullstack
  run apache2ctl configtest
  run systemctl daemon-reload
  run systemctl enable renderd apache2
  run systemctl restart renderd apache2 || true
  success "Raster tile stack configured at ${TILE_URI}{z}/{x}/{y}.png"
}

install_nominatim_ui() {
  info "Installing latest stable Nominatim UI..."
  local api="https://api.github.com/repos/osm-search/nominatim-ui/releases/latest"
  local meta url asset tmp unpack dist
  tmp=$(mktemp -d)

  if meta=$(curl -fsSL --retry 4 "$api"); then
    url=$(jq -r '.assets[]? | select(.name | test("\\.(tar\\.gz|tgz)$")) | .browser_download_url' <<<"$meta" | head -n1)
    if [[ -z "$url" || "$url" == "null" ]]; then
      url=$(jq -r '.assets[]? | select(.name | endswith(".zip")) | .browser_download_url' <<<"$meta" | head -n1)
    fi
  else
    url=""
  fi

  if [[ -z "$url" || "$url" == "null" ]]; then
    warn "Could not discover a Nominatim UI release asset. The API remains fully installed; skipping optional debug UI."
    rm -rf "$tmp"
    return 0
  fi

  asset="$tmp/$(basename "$url")"
  run curl -fL --retry 4 --progress-bar -o "$asset" "$url"
  unpack="$tmp/unpack"
  run mkdir -p "$unpack"
  case "$asset" in
    *.tar.gz|*.tgz) run tar -xzf "$asset" -C "$unpack" ;;
    *.zip) run unzip -q "$asset" -d "$unpack" ;;
    *) warn "Unknown Nominatim UI asset format: $asset"; rm -rf "$tmp"; return 0 ;;
  esac

  dist=$(find "$unpack" -type d -name dist -print -quit || true)
  if [[ -z "$dist" ]]; then
    warn "Nominatim UI release did not contain a dist directory. Skipping UI."
    rm -rf "$tmp"
    return 0
  fi

  run rm -rf "$NOM_UI_DIR"
  run mkdir -p "$NOM_UI_DIR"
  run cp -a "$dist"/. "$NOM_UI_DIR"/
  run mkdir -p "$NOM_UI_DIR/theme"
  cat > "$NOM_UI_DIR/theme/config.theme.js" <<'EOF_NOM_UI'
Nominatim_Config.Nominatim_API_Endpoint='/nominatim/';
EOF_NOM_UI
  run chown -R www-data:www-data "$NOM_UI_DIR"
  run chmod -R a+rX "$NOM_UI_DIR"
  rm -rf "$tmp"
  success "Nominatim UI installed at /nominatim-ui/."
}

install_nominatim() {
  step_bar "Nominatim geocoder"

  if [[ ! -x "$NOM_VENV/bin/python" ]]; then
    as_user "$NOM_USER" virtualenv "$NOM_VENV"
  fi
  as_user "$NOM_USER" "$NOM_VENV/bin/pip" install --upgrade pip wheel setuptools
  as_user "$NOM_USER" "$NOM_VENV/bin/pip" install --upgrade nominatim-db nominatim-api falcon gunicorn uvicorn "psycopg[binary]" osmium

  run mkdir -p "$NOM_PROJECT"
  run chown -R "$NOM_USER:$NOM_USER" "$NOM_PROJECT"

  local nom_osm2pgsql
  nom_osm2pgsql="$(command -v osm2pgsql || true)"
  [[ -n "$nom_osm2pgsql" && -x "$nom_osm2pgsql" ]] || {
    error "Nominatim requires an executable osm2pgsql binary."
    return 1
  }

  # Nominatim's project directory must contain persistent configuration.
  # Explicitly set the system osm2pgsql path. Leaving this unresolved can
  # become Path('') == '.' in Python and fail with PermissionError on '.'.
  cat > "$NOM_PROJECT/.env" <<EOF_NOM_ENV
NOMINATIM_DATABASE_DSN=pgsql:dbname=nominatim
NOMINATIM_DATABASE_WEBUSER=www-data
NOMINATIM_OSM2PGSQL_BINARY=$nom_osm2pgsql
NOMINATIM_IMPORT_STYLE=extratags
EOF_NOM_ENV
  run chown "$NOM_USER:$NOM_USER" "$NOM_PROJECT/.env"
  run chmod 640 "$NOM_PROJECT/.env"

  cat > /etc/systemd/system/nominatim.socket <<'EOF_NOM_SOCKET'
[Unit]
Description=Gunicorn socket for Nominatim

[Socket]
ListenStream=/run/nominatim.sock
SocketUser=www-data
SocketGroup=www-data
SocketMode=0660

[Install]
WantedBy=sockets.target
EOF_NOM_SOCKET

  cat > /etc/systemd/system/nominatim.service <<EOF_NOM_SERVICE
[Unit]
Description=Nominatim geocoding API
After=network.target postgresql.service
Requires=nominatim.socket

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=$NOM_PROJECT
ExecStart=$NOM_VENV/bin/gunicorn -b unix:/run/nominatim.sock -w 4 --worker-class asgi --protocol http --worker-connections 1000 "nominatim_api.server.falcon.server:run_wsgi()"
ExecReload=/bin/kill -s HUP \$MAINPID
PrivateTmp=true
TimeoutStopSec=10
KillMode=mixed
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_NOM_SERVICE

  run systemctl daemon-reload
  run systemctl enable --now nominatim.socket
  # Do not force-start nominatim.service before a database has been imported.
  install_nominatim_ui
  success "Nominatim software, API socket and UI installed. Import a country to activate the API."
}

install_osrm() {
  step_bar "OSRM routing engine"

  if command -v osrm-extract >/dev/null 2>&1; then
    success "OSRM is already installed: $(command -v osrm-extract)"
    return
  fi

  info "APT OSRM not found; building current OSRM backend from source with vcpkg."
  if [[ ! -d "$OSRM_SRC/.git" ]]; then
    run git clone --recursive https://github.com/Project-OSRM/osrm-backend.git "$OSRM_SRC"
  else
    run git -C "$OSRM_SRC" fetch --all --tags --prune
  fi
  local osrm_tag
  osrm_tag=$(git -C "$OSRM_SRC" tag --sort=-v:refname | head -n1)
  [[ -n "$osrm_tag" ]] || { error "Could not determine latest stable OSRM tag."; return 1; }
  info "Using latest fetched stable OSRM release: $osrm_tag"
  run git -C "$OSRM_SRC" checkout --detach "$osrm_tag"
  run git -C "$OSRM_SRC" submodule update --init --recursive

  local vcpkg="$SRC_DIR/vcpkg"
  if [[ ! -d "$vcpkg/.git" ]]; then
    run git clone https://github.com/microsoft/vcpkg.git "$vcpkg"
    run "$vcpkg/bootstrap-vcpkg.sh" -disableMetrics
  fi

  # Current upstream OSRM requires CMake >= 3.29.
  local cmake_version
  cmake_version=$(cmake --version | awk 'NR==1{print $3}')
  if [[ "$(printf '%s\n' 3.29 "$cmake_version" | sort -V | head -n1)" != "3.29" ]]; then
    warn "System CMake $cmake_version is older than 3.29. Installing a recent cmake in /opt/osm-cmake-venv."
    run python3 -m venv /opt/osm-cmake-venv
    run /opt/osm-cmake-venv/bin/pip install --upgrade pip cmake
    export PATH="/opt/osm-cmake-venv/bin:$PATH"
  fi

  (
    cd "$OSRM_SRC"
    export VCPKG_ROOT="$vcpkg"
    run cmake --preset ci-linux
    run cmake --build --preset ci-linux -j"$(nproc)"
    run cmake --install build
  )
  success "OSRM backend installed."
}

install_overpass() {
  step_bar "Overpass API engine"

  run mkdir -p "$OVERPASS_ROOT" "$OVERPASS_DB" "$OVERPASS_DIFF" "$OVERPASS_EXEC"
  if [[ -x "$OVERPASS_EXEC/bin/dispatcher" \
     && -x "$OVERPASS_EXEC/bin/update_database" \
     && -x "$OVERPASS_EXEC/cgi-bin/interpreter" \
     && -x "$OVERPASS_EXEC/cgi-bin/timestamp" ]]; then
    success "Overpass is already installed and CGI endpoints are complete; keeping existing binaries."
    return 0
  fi
  if [[ -x "$OVERPASS_EXEC/bin/dispatcher" || -x "$OVERPASS_EXEC/bin/update_database" ]]; then
    warn "Existing Overpass installation is incomplete (missing CGI/runtime files); rebuilding it safely."
  fi
  run chown -R "$OVERPASS_USER:$OVERPASS_USER" "$OVERPASS_ROOT"

  if [[ ! -d "$OVERPASS_SRC" ]]; then
    run mkdir -p "$OVERPASS_SRC"
  fi

  # Use the official latest release tarball to avoid unstable development branches.
  local tarball="$OVERPASS_SRC/osm-3s_latest.tar.gz"
  run curl -fL --retry 4 --progress-bar -o "$tarball" https://dev.overpass-api.de/releases/osm-3s_latest.tar.gz
  run rm -rf "$OVERPASS_SRC/build-src"
  run mkdir -p "$OVERPASS_SRC/build-src"
  run tar -xzf "$tarball" -C "$OVERPASS_SRC/build-src" --strip-components=1
  run chown -R "$OVERPASS_USER:$OVERPASS_USER" "$OVERPASS_SRC" "$OVERPASS_ROOT"

  as_user "$OVERPASS_USER" bash -lc "cd '$OVERPASS_SRC/build-src' && ./configure CXXFLAGS='-O2' --prefix='$OVERPASS_EXEC' --enable-lz4"
  as_user "$OVERPASS_USER" bash -lc "cd '$OVERPASS_SRC/build-src' && make -j'$(nproc)'"
  as_user "$OVERPASS_USER" bash -lc "cd '$OVERPASS_SRC/build-src' && make install"

  # Upstream recommends keeping bin/ and cgi-bin/ together. In particular,
  # helper scripts such as init_osm3s.sh are not guaranteed to be copied by
  # make install. Copy the complete built directories so no runtime endpoint
  # or maintenance helper is missing.
  run mkdir -p "$OVERPASS_EXEC/bin" "$OVERPASS_EXEC/cgi-bin"
  if [[ -d "$OVERPASS_SRC/build-src/bin" ]]; then
    run cp -a "$OVERPASS_SRC/build-src/bin/." "$OVERPASS_EXEC/bin/"
  fi
  if [[ -d "$OVERPASS_SRC/build-src/cgi-bin" ]]; then
    run cp -a "$OVERPASS_SRC/build-src/cgi-bin/." "$OVERPASS_EXEC/cgi-bin/"
  fi
  run chown -R "$OVERPASS_USER:$OVERPASS_USER" "$OVERPASS_EXEC"
  run chmod -R a+rX "$OVERPASS_EXEC/bin" "$OVERPASS_EXEC/cgi-bin"
  for cgi in interpreter timestamp status kill_my_queries; do
    [[ -f "$OVERPASS_EXEC/cgi-bin/$cgi" ]] && run chmod 755 "$OVERPASS_EXEC/cgi-bin/$cgi"
  done
  [[ -x "$OVERPASS_EXEC/cgi-bin/interpreter" ]] || { error "Overpass CGI interpreter was not installed."; return 1; }
  [[ -x "$OVERPASS_EXEC/cgi-bin/timestamp" ]] || { error "Overpass CGI timestamp endpoint was not installed."; return 1; }

  # Keep rules for area generation.
  if [[ -d "$OVERPASS_SRC/build-src/rules" ]]; then
    run rm -rf "$OVERPASS_DB/rules"
    run cp -a "$OVERPASS_SRC/build-src/rules" "$OVERPASS_DB/rules"
    run chown -R "$OVERPASS_USER:$OVERPASS_USER" "$OVERPASS_DB/rules"
  fi

  success "Overpass binaries installed. Database import remains data-dependent."
}

install_web_portal() {
  step_bar "Leaflet web portal"
  run mkdir -p "$WEB_DIR/vendor/images"
  run curl -fL --retry 4 --progress-bar -o "$WEB_DIR/vendor/leaflet.css" https://unpkg.com/leaflet@1.9.4/dist/leaflet.css
  run curl -fL --retry 4 --progress-bar -o "$WEB_DIR/vendor/leaflet.js" https://unpkg.com/leaflet@1.9.4/dist/leaflet.js
  run curl -fL --retry 4 --progress-bar -o "$WEB_DIR/vendor/images/marker-icon.png" https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon.png
  run curl -fL --retry 4 --progress-bar -o "$WEB_DIR/vendor/images/marker-icon-2x.png" https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon-2x.png
  run curl -fL --retry 4 --progress-bar -o "$WEB_DIR/vendor/images/marker-shadow.png" https://unpkg.com/leaflet@1.9.4/dist/images/marker-shadow.png

  cat > "$WEB_DIR/index.html" <<'EOF_WEB'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>OpenStreetMap Full Stack</title>
  <link rel="stylesheet" href="/osm/vendor/leaflet.css">
  <style>
    html,body,#map{height:100%;margin:0}
    .panel{position:absolute;z-index:1000;top:12px;left:55px;background:#fff;padding:12px;border-radius:9px;box-shadow:0 2px 12px #0004;font-family:Arial,sans-serif;min-width:355px;max-width:430px}
    .panel input{width:235px;padding:5px}.panel button,.panel a{cursor:pointer;margin:3px 2px;padding:4px 7px}.muted{color:#555;font-size:12px}.status{margin-top:5px;font-size:12px}
  </style>
</head>
<body>
<div class="panel">
  <b>OpenStreetMap Full Stack</b><br>
  <input id="q" placeholder="Search place/address"><button onclick="searchPlace()">Search</button><br>
  <button onclick="beginRoute()">Route: pick A → B</button><button onclick="clearRoute()">Clear route</button><br>
  <span class="muted">Right-click map = reverse geocode. Route uses local OSRM.</span><br>
  <a href="/nominatim-ui/" target="_blank">Nominatim UI</a>
  <a href="/overpass/api/timestamp" target="_blank">Overpass timestamp</a>\n  <a href="/telemetry/" target="_blank">Live telemetry</a>
  <div id="status" class="status">Raster tiles • Nominatim • OSRM • Overpass • Telemetry</div>
</div>
<div id="map"></div>
<script src="/osm/vendor/leaflet.js"></script>
<script>
const map=L.map('map').setView([37.98,23.72],6);
L.tileLayer('/tile/{z}/{x}/{y}.png',{maxZoom:20,attribution:'© OpenStreetMap contributors'}).addTo(map);
let searchMarker=null, routeMode=false, routePts=[], routeMarkers=[], routeLine=null;
const statusEl=document.getElementById('status');
function setStatus(t){statusEl.textContent=t;}
async function searchPlace(){
  const q=document.getElementById('q').value.trim(); if(!q)return;
  setStatus('Searching…');
  try{
    const r=await fetch('/nominatim/search?q='+encodeURIComponent(q)+'&format=jsonv2&limit=1');
    const j=await r.json(); if(!j.length){setStatus('No result');return;}
    const p=j[0]; map.setView([+p.lat,+p.lon],15);
    if(searchMarker)map.removeLayer(searchMarker);
    searchMarker=L.marker([+p.lat,+p.lon]).addTo(map).bindPopup(p.display_name).openPopup();
    setStatus(p.display_name);
  }catch(e){setStatus('Nominatim API is not ready: '+e.message);}
}
function beginRoute(){clearRoute();routeMode=true;setStatus('Routing mode: click START, then DESTINATION.');}
function clearRoute(){routeMode=false;routePts=[];routeMarkers.forEach(m=>map.removeLayer(m));routeMarkers=[];if(routeLine){map.removeLayer(routeLine);routeLine=null;}setStatus('Route cleared.');}
async function drawRoute(){
  const a=routePts[0],b=routePts[1];
  const url=`/route/route/v1/driving/${a.lng},${a.lat};${b.lng},${b.lat}?overview=full&geometries=geojson&steps=true`;
  setStatus('Calculating route…');
  try{
    const r=await fetch(url); const j=await r.json();
    if(j.code!=='Ok'||!j.routes?.length){setStatus('No route: '+(j.message||j.code||'unknown error'));return;}
    const rt=j.routes[0];
    routeLine=L.geoJSON(rt.geometry,{weight:6,opacity:.75}).addTo(map);
    map.fitBounds(routeLine.getBounds(),{padding:[25,25]});
    setStatus(`Route: ${(rt.distance/1000).toFixed(1)} km • ${Math.round(rt.duration/60)} min`);
  }catch(e){setStatus('OSRM is not ready: '+e.message);}
}
map.on('click',e=>{
  if(!routeMode)return;
  routePts.push(e.latlng);
  const label=routePts.length===1?'A':'B';
  routeMarkers.push(L.marker(e.latlng).addTo(map).bindPopup(label).openPopup());
  if(routePts.length===2){routeMode=false;drawRoute();}
});
map.on('contextmenu',async e=>{
  setStatus('Reverse geocoding…');
  try{
    const r=await fetch(`/nominatim/reverse?lat=${e.latlng.lat}&lon=${e.latlng.lng}&format=jsonv2`);
    const j=await r.json(); L.popup().setLatLng(e.latlng).setContent(j.display_name||'No address').openOn(map); setStatus(j.display_name||'No address');
  }catch(err){setStatus('Reverse geocoding unavailable: '+err.message);}
});
document.getElementById('q').addEventListener('keydown',e=>{if(e.key==='Enter')searchPlace();});
</script>
</body>
</html>
EOF_WEB

  run chown -R www-data:www-data "$WEB_DIR"
  success "Web portal: http://SERVER:${APACHE_PORT}/osm/"
}


install_telemetry() {
  step_bar "Live telemetry backend"

  run mkdir -p "$TELEMETRY_HOME" /etc/osm-telemetry "$BASE_DIR/updates"

  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$TELEMETRY_USER'" | grep -q 1; then
    run sudo -u postgres createuser "$TELEMETRY_USER"
  fi
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$TELEMETRY_DB'" | grep -q 1; then
    run sudo -u postgres createdb -O "$TELEMETRY_USER" "$TELEMETRY_DB"
  fi

  if [[ ! -f /etc/osm-telemetry/token ]]; then
    umask 077
    openssl rand -hex 32 > /etc/osm-telemetry/token
  fi

  if [[ ! -x "$TELEMETRY_HOME/venv/bin/python" ]]; then
    run python3 -m venv "$TELEMETRY_HOME/venv"
  fi
  run "$TELEMETRY_HOME/venv/bin/pip" install --upgrade pip wheel
  run "$TELEMETRY_HOME/venv/bin/pip" install --upgrade fastapi "uvicorn[standard]" "psycopg[binary]"

  cat > "$TELEMETRY_HOME/server.py" <<'PY_TELEMETRY'
import os
from datetime import datetime, timezone
from typing import Optional
import psycopg
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

DB=os.environ["OSM_TELEMETRY_DB"]
TOKEN=os.environ["OSM_TELEMETRY_TOKEN"]
app=FastAPI(title="OpenStreetMap Live Telemetry",version="1.0.0")
SCHEMA="""CREATE TABLE IF NOT EXISTS telemetry_points(
 id BIGSERIAL PRIMARY KEY, device_id TEXT NOT NULL, display_name TEXT,
 latitude DOUBLE PRECISION NOT NULL, longitude DOUBLE PRECISION NOT NULL,
 accuracy_m DOUBLE PRECISION, altitude_m DOUBLE PRECISION,
 speed_mps DOUBLE PRECISION, heading_deg DOUBLE PRECISION, battery_pct INTEGER,
 recorded_at TIMESTAMPTZ NOT NULL, received_at TIMESTAMPTZ NOT NULL DEFAULT NOW());
CREATE INDEX IF NOT EXISTS telemetry_device_time_idx
ON telemetry_points(device_id,recorded_at DESC);"""

def auth(v: Optional[str]):
    if v != f"Bearer {TOKEN}": raise HTTPException(status_code=401,detail="Unauthorized")

class Point(BaseModel):
    device_id:str=Field(min_length=1,max_length=128)
    display_name:Optional[str]=Field(default=None,max_length=128)
    latitude:float=Field(ge=-90,le=90)
    longitude:float=Field(ge=-180,le=180)
    accuracy_m:Optional[float]=Field(default=None,ge=0)
    altitude_m:Optional[float]=None
    speed_mps:Optional[float]=Field(default=None,ge=0)
    heading_deg:Optional[float]=Field(default=None,ge=0,le=360)
    battery_pct:Optional[int]=Field(default=None,ge=0,le=100)
    recorded_at:Optional[datetime]=None

@app.on_event("startup")
def startup():
    with psycopg.connect(DB) as conn:
        with conn.cursor() as cur: cur.execute(SCHEMA)
        conn.commit()

@app.get("/health")
def health(): return {"status":"ok","time":datetime.now(timezone.utc).isoformat()}

@app.post("/api/telemetry")
def ingest(p:Point,authorization:Optional[str]=Header(default=None)):
    auth(authorization); when=p.recorded_at or datetime.now(timezone.utc)
    with psycopg.connect(DB) as conn:
        with conn.cursor() as cur:
            cur.execute("""INSERT INTO telemetry_points
            (device_id,display_name,latitude,longitude,accuracy_m,altitude_m,speed_mps,heading_deg,battery_pct,recorded_at)
            VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING id""",
            (p.device_id,p.display_name,p.latitude,p.longitude,p.accuracy_m,p.altitude_m,p.speed_mps,p.heading_deg,p.battery_pct,when))
            rid=cur.fetchone()[0]
        conn.commit()
    return {"ok":True,"id":rid}

@app.get("/api/devices")
def devices(authorization:Optional[str]=Header(default=None)):
    auth(authorization)
    with psycopg.connect(DB) as conn:
        with conn.cursor() as cur:
            cur.execute("""SELECT DISTINCT ON(device_id) device_id,COALESCE(display_name,device_id),
            latitude,longitude,accuracy_m,battery_pct,recorded_at,received_at
            FROM telemetry_points ORDER BY device_id,recorded_at DESC""")
            rows=cur.fetchall()
    return [{"device_id":r[0],"display_name":r[1],"latitude":r[2],"longitude":r[3],
             "accuracy_m":r[4],"battery_pct":r[5],"recorded_at":r[6],"received_at":r[7]} for r in rows]

@app.get("/",response_class=HTMLResponse)
def page():
    return """<!doctype html><html><head><meta charset="utf-8"><title>OSM Live Telemetry</title>
<link rel="stylesheet" href="/osm/vendor/leaflet.css"><style>html,body,#map{height:100%;margin:0}
#p{position:absolute;z-index:1000;top:12px;left:55px;background:#fff;padding:12px;border-radius:9px;font:14px Arial}</style>
</head><body><div id="p"><b>OSM Live Telemetry</b><br><input id="t" type="password" placeholder="Telemetry token">
<button onclick="load()">Refresh</button><span id="s"></span></div><div id="map"></div>
<script src="/osm/vendor/leaflet.js"></script><script>
const m=L.map('map').setView([38.5,23.7],6);L.tileLayer('/tile/{z}/{x}/{y}.png',{maxZoom:20,attribution:'© OpenStreetMap contributors'}).addTo(m);
const ms={};async function load(){const t=document.getElementById('t').value;
const r=await fetch('/telemetry/api/devices',{headers:{Authorization:'Bearer '+t}});
if(!r.ok){document.getElementById('s').textContent=' auth/error';return;}const ds=await r.json();
ds.forEach(d=>{const p=[d.latitude,d.longitude],x='<b>'+d.display_name+'</b><br>'+d.latitude+', '+d.longitude;
if(ms[d.device_id])ms[d.device_id].setLatLng(p).bindPopup(x);else ms[d.device_id]=L.marker(p).addTo(m).bindPopup(x);});
document.getElementById('s').textContent=' '+ds.length+' device(s)';}setInterval(load,10000);
</script></body></html>"""
PY_TELEMETRY

  cat > /etc/osm-telemetry/env <<EOF_TELEMETRY_ENV
OSM_TELEMETRY_DB=postgresql://$TELEMETRY_USER@/$TELEMETRY_DB
OSM_TELEMETRY_TOKEN=$(cat /etc/osm-telemetry/token)
EOF_TELEMETRY_ENV
  run chmod 600 /etc/osm-telemetry/env
  run chown -R "$TELEMETRY_USER:$TELEMETRY_USER" "$TELEMETRY_HOME"

  cat > /etc/systemd/system/osm-telemetry.service <<EOF_TELEMETRY_SERVICE
[Unit]
Description=OpenStreetMap consent-based telemetry API
After=network-online.target postgresql.service
Wants=network-online.target
[Service]
Type=simple
User=$TELEMETRY_USER
Group=$TELEMETRY_USER
WorkingDirectory=$TELEMETRY_HOME
EnvironmentFile=/etc/osm-telemetry/env
ExecStart=$TELEMETRY_HOME/venv/bin/uvicorn server:app --host 127.0.0.1 --port $TELEMETRY_PORT
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF_TELEMETRY_SERVICE

  cat > /etc/apache2/conf-available/osm-telemetry.conf <<EOF_TELEMETRY_APACHE
ProxyPass        /telemetry/ http://127.0.0.1:$TELEMETRY_PORT/
ProxyPassReverse /telemetry/ http://127.0.0.1:$TELEMETRY_PORT/
EOF_TELEMETRY_APACHE
  run a2enmod proxy proxy_http headers
  run a2enconf osm-telemetry
  run systemctl daemon-reload
  run systemctl enable --now osm-telemetry.service
  run apache2ctl configtest
  run systemctl restart apache2

  cat > "$BASE_DIR/updates/telemetry-agent-manifest.example.json" <<'EOF_TELEMETRY_MANIFEST'
{"product":"OpenStreetMapTelemetryClient","channel":"final","version":"1.0.0",
"package":"OpenStreetMapTelemetryClient.apk","sha256":"REPLACE_WITH_SIGNED_APK_SHA256",
"rollback":true,"privacy":"Device-owner consent and Android location permissions are required."}
EOF_TELEMETRY_MANIFEST

  success "Telemetry: http://SERVER:${APACHE_PORT}/telemetry/"
  success "Telemetry token: /etc/osm-telemetry/token"
}

setup_housekeeping() {
  step_bar "Logging / backups / housekeeping"

  cat > /etc/logrotate.d/osm-fullstack <<EOF_LOGROTATE
$LOG_DIR/*.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF_LOGROTATE

  cat > /usr/local/sbin/osm-backup-configs.sh <<EOF_BACKUP
#!/usr/bin/env bash
set -Eeuo pipefail
OUT="$BACKUP_DIR/config-\$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "\$OUT" \
  /etc/renderd.conf \
  /etc/apache2/conf-available/osm-fullstack.conf \
  /etc/systemd/system/nominatim.service \
  /etc/systemd/system/nominatim.socket \
  /etc/systemd/system/osm-telemetry.service \
  /etc/osm-telemetry \
  "$NOM_PROJECT" 2>/dev/null || true
find "$BACKUP_DIR" -type f -name 'config-*.tar.gz' -mtime +30 -delete
printf 'Backup: %s\n' "\$OUT"
EOF_BACKUP
  run chmod +x /usr/local/sbin/osm-backup-configs.sh

  cat > /etc/cron.d/osm-fullstack-backup <<'EOF_CRON'
17 3 * * * root /usr/local/sbin/osm-backup-configs.sh >> /var/log/osm-fullstack/backup.log 2>&1
EOF_CRON

  success "Log rotation and nightly config backups enabled."
}

setup_health_command() {
  step_bar "Health-check command"

  cat > /usr/local/sbin/osm-health <<'EOF_HEALTH'
#!/usr/bin/env bash
set -u
G='\033[32m'; R='\033[31m'; Y='\033[33m'; Z='\033[0m'
APACHE_PORT="@@APACHE_PORT@@"
check_service(){ if systemctl is-active --quiet "$1"; then printf "${G}[UP]${Z}   %-22s\n" "$1"; else printf "${R}[DOWN]${Z} %-22s\n" "$1"; fi; }
check_port(){ if ss -lntup 2>/dev/null | grep -q ":$1 "; then printf "${G}[LISTEN]${Z} port %s\n" "$1"; else printf "${Y}[CLOSED]${Z} port %s\n" "$1"; fi; }
echo "OpenStreetMap Full Stack Health"
echo "--------------------------------"
check_service postgresql
check_service apache2
check_service renderd
check_service nominatim.socket
systemctl list-unit-files | grep -q '^osrm\.service' && check_service osrm || true
systemctl list-unit-files | grep -q '^overpass' && check_service overpass-dispatcher || true
systemctl list-unit-files | grep -q '^osm-telemetry\.service' && check_service osm-telemetry || true
if systemctl is-active --quiet overpass-dispatcher 2>/dev/null; then
  printf "%-30s" "Overpass HTTP API"
  if curl -fsS --max-time 8 "http://127.0.0.1:${APACHE_PORT}/overpass/api/timestamp" >/dev/null 2>&1; then
    printf "\033[32mOK\033[0m\n"
  else
    printf "\033[33mNOT READY\033[0m\n"
  fi
fi
check_port "$APACHE_PORT"
check_port 5000
check_port 9018
printf '\nDisk:\n'; df -h /srv/osm 2>/dev/null || true
printf '\nData files:\n'; find /srv/osm/data -maxdepth 1 -type f -printf '%f  %s bytes\n' 2>/dev/null | sort || true
EOF_HEALTH
  run sed -i "s|@@APACHE_PORT@@|$APACHE_PORT|g" /usr/local/sbin/osm-health
  run chmod +x /usr/local/sbin/osm-health
  success "Health command installed: osm-health"
}

finish_full_install() {
  step_bar "Final service reload"
  run systemctl daemon-reload
  run apache2ctl configtest
  run systemctl restart apache2
  run systemctl enable --now renderd || true
  success "Software stack installation finished. Apache backend: http://SERVER:${APACHE_PORT}/"
  success "Use Nginx Proxy Manager for public 80/443 and TLS."
}

full_install() {
  TOTAL_STEPS=13
  CURRENT_STEP=0
  banner
  hardware_report
  printf "\n%bThis installs the complete software stack. Large OSM datasets are NOT downloaded until you select them.%b\n" "$YELLOW" "$RESET"
  sleep 1

  ensure_dirs
  install_packages
  create_service_users
  setup_postgres
  install_carto
  configure_rendering
  install_nominatim
  install_osrm
  install_overpass
  install_web_portal
  install_telemetry
  setup_housekeeping
  setup_health_command
  finish_full_install

  printf "\n%bFULL STACK SOFTWARE INSTALL COMPLETE%b\n" "$GREEN$BOLD" "$RESET"
  printf "Next: choose 'Country / Region Download Manager' or 'Full Auto Country Deployment'.\n"
  pause
}

refresh_geofabrik_index() {
  local idx="$STATE_DIR/geofabrik-index.json"
  run mkdir -p "$STATE_DIR"
  info "Refreshing Geofabrik index..."
  run curl -fL --retry 4 --progress-bar -o "$idx.tmp" "$GEOFABRIK_INDEX"
  jq -e '.type == "FeatureCollection" and (.features|length > 0)' "$idx.tmp" >/dev/null
  run mv "$idx.tmp" "$idx"
  REFRESHED_INDEX="$idx"
}

country_rows() {
  local idx="$1"
  jq -r '
    .features[]
    | select(.properties["iso3166-1:alpha2"] != null)
    | select(.properties.urls.pbf != null)
    | [
        .properties.name,
        (.properties["iso3166-1:alpha2"]|join(",")),
        (.properties.parent // "-"),
        .properties.id,
        .properties.urls.pbf,
        (.properties.urls.updates // "")
      ] | @tsv' "$idx" | sort -f
}

all_region_rows() {
  local idx="$1"
  jq -r '
    .features[]
    | select(.properties.urls.pbf != null)
    | [
        .properties.name,
        (.properties["iso3166-1:alpha2"] // [] | join(",")),
        (.properties.parent // "-"),
        .properties.id,
        .properties.urls.pbf,
        (.properties.urls.updates // "")
      ] | @tsv' "$idx" | sort -f
}

sanitize_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+|-+$//g'
}

download_url() {
  local url="$1" out="$2"
  run mkdir -p "$(dirname "$out")"
  info "Download: $url"
  info "Target:   $out"
  if command -v aria2c >/dev/null 2>&1; then
    run aria2c --continue=true --max-connection-per-server=4 --split=4 --min-split-size=16M \
      --console-log-level=notice --summary-interval=5 --file-allocation=none \
      --dir="$(dirname "$out")" --out="$(basename "$out")" "$url"
  else
    run curl -fL --retry 6 --retry-delay 3 -C - --progress-bar -o "$out" "$url"
  fi
  success "Downloaded $(du -h "$out" | awk '{print $1}') -> $out"
}

select_row_interactive() {
  local mode="${1:-countries}"
  local idx tmp choice line count
  SELECTED_ROW=""
  refresh_geofabrik_index
  idx="$REFRESHED_INDEX"
  tmp=$(mktemp)
  if [[ "$mode" == "all" ]]; then
    all_region_rows "$idx" > "$tmp"
  else
    country_rows "$idx" > "$tmp"
  fi
  count=$(wc -l < "$tmp")

  while true; do
    banner
    printf "%bGeofabrik %s menu%b — %s entries\n\n" "$BOLD" "$mode" "$RESET" "$count"
    printf "  1) Search by country/region name\n"
    printf "  2) Search by ISO code / internal id\n"
    printf "  3) List all entries (paged)\n"
    printf "  0) Back\n\n"
    read -rp "Selection: " choice
    case "$choice" in
      1)
        read -rp "Name contains: " choice
        mapfile -t matches < <(awk -F'\t' -v q="$choice" 'index(tolower($1),tolower(q)) {print}' "$tmp")
        ;;
      2)
        read -rp "ISO or id: " choice
        mapfile -t matches < <(awk -F'\t' -v q="$choice" 'index(tolower($2),tolower(q)) || index(tolower($4),tolower(q)) {print}' "$tmp")
        ;;
      3)
        nl -w4 -s') ' "$tmp" | less -S
        read -rp "Enter exact list number: " choice
        line=$(sed -n "${choice}p" "$tmp" || true)
        [[ -n "$line" ]] && { SELECTED_ROW="$line"; rm -f "$tmp"; return 0; }
        warn "Invalid selection."
        continue
        ;;
      0) rm -f "$tmp"; return 1 ;;
      *) warn "Invalid selection."; continue ;;
    esac

    if ((${#matches[@]} == 0)); then
      warn "No matches."
      pause
      continue
    fi

    printf "\n"
    local i=1
    for line in "${matches[@]}"; do
      IFS=$'\t' read -r n iso parent id url upd <<<"$line"
      printf "%3d) %-38s ISO:%-8s parent:%s\n" "$i" "$n" "${iso:--}" "$parent"
      ((i++))
      ((i > 80)) && { warn "Showing first 80 matches; refine your search."; break; }
    done
    read -rp "Select number: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#matches[@]} && choice <= 80)); then
      SELECTED_ROW="${matches[$((choice-1))]}"
      rm -f "$tmp"
      return 0
    fi
    warn "Invalid selection."
  done
}

download_all_countries() {
  banner
  printf "%bDOWNLOAD ALL COUNTRY EXTRACTS%b\n\n" "$BOLD$CYAN" "$RESET"
  warn "This can consume a very large amount of disk and bandwidth. Each country is stored as a separate PBF."
  read -rp "Type ALL COUNTRIES to continue: " confirm
  [[ "$confirm" == "ALL COUNTRIES" ]] || { warn "Cancelled."; return; }

  refresh_geofabrik_index
  local idx="$REFRESHED_INDEX"
  local name iso parent id url updates slug out
  local total current=0
  total=$(country_rows "$idx" | wc -l)
  while IFS=$'\t' read -r name iso parent id url updates; do
    ((current+=1))
    slug=$(sanitize_slug "$id")
    out="$DATA_DIR/${slug}-latest.osm.pbf"
    printf "\n%b[%d/%d]%b %s (%s)\n" "$BOLD$BLUE" "$current" "$total" "$RESET" "$name" "$iso"
    if [[ -s "$out" ]]; then
      info "Already exists; aria2/curl resume check will reuse it: $out"
    fi
    download_url "$url" "$out"
  done < <(country_rows "$idx")
  success "All $total Geofabrik ISO country extracts have been processed."
}


download_greece_dataset() {
  refresh_geofabrik_index

  local idx="$REFRESHED_INDEX"
  local row name iso parent id url updates slug out

  row=$(country_rows "$idx" | awk -F'\t' '$2 ~ /(^|,)GR(,|$)/ {print; exit}')
  [[ -n "$row" ]] || {
    error "Greece was not found in the Geofabrik index."
    return 1
  }

  IFS=$'\t' read -r name iso parent id url updates <<<"$row"

  slug=$(sanitize_slug "$id")
  out="$DATA_DIR/${slug}-latest.osm.pbf"

  download_url "$url" "$out"

  [[ -s "$out" ]] || {
    error "Greece PBF is missing or empty after download: $out"
    return 1
  }

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$slug" "$out" "$url" "$updates" \
    > "$STATE_DIR/last-dataset.tsv"

  GREECE_PBF="$out"
  success "Greece dataset ready: $GREECE_PBF"
}

extract_city_bbox() {
  banner
  printf "%bCITY / CUSTOM AREA EXTRACT%b\n\n" "$BOLD$CYAN" "$RESET"
  printf "Create a smaller .osm.pbf from an existing downloaded dataset.\n"
  printf "Bounding box format: west,south,east,north\n\n"

  local source name bbox slug out

  source=$(choose_local_pbf) || return

  read -rp "Area/city name: " name
  read -rp "Bounding box: " bbox

  [[ -n "$name" && -n "$bbox" ]] || {
    warn "Area name and bounding box are required."
    return
  }

  slug=$(sanitize_slug "$name")
  out="$DATA_DIR/${slug}.osm.pbf"

  run osmium extract \
    --overwrite \
    --strategy=complete_ways \
    --bbox "$bbox" \
    "$source" \
    -o "$out"

  [[ -s "$out" ]] || {
    error "Custom extract was not created correctly: $out"
    return 1
  }

  success "Custom extract created: $out"
  pause
}

full_greece_deployment() {
  require_root
  load_os_release
  ensure_dirs

  TOTAL_STEPS=18
  CURRENT_STEP=0

  banner
  hardware_report

  printf "\n%bFULL GREECE DEPLOYMENT%b\n" "$BOLD$CYAN" "$RESET"
  printf "Fresh VM deployment:\n"
  printf "  • PostgreSQL/PostGIS\n"
  printf "  • OpenStreetMap Carto + Mapnik\n"
  printf "  • renderd + mod_tile + Apache backend :%s\n" "$APACHE_PORT"
  printf "  • Nominatim\n"
  printf "  • OSRM\n"
  printf "  • Overpass API\n"
  printf "  • Leaflet portal\n"
  printf "  • Live telemetry backend\n"
  printf "  • Greece dataset and all imports\n\n"

  read -rp "Type GREECE to continue: " confirm
  if [[ "$confirm" != "GREECE" ]]; then
    warn "Cancelled."
    TOTAL_STEPS=13
    return
  fi

  install_packages
  create_service_users
  setup_postgres
  install_carto
  configure_rendering
  install_nominatim
  install_osrm
  install_overpass
  install_web_portal
  install_telemetry
  setup_housekeeping
  setup_health_command

  step_bar "Download Greece dataset"
  download_greece_dataset

  step_bar "Import Greece -> rendering"
  import_render_db "$GREECE_PBF"

  step_bar "Import Greece -> Nominatim"
  import_nominatim "$GREECE_PBF"

  step_bar "Import Greece -> OSRM"
  import_osrm "$GREECE_PBF"

  step_bar "Import Greece -> Overpass"
  import_overpass "$GREECE_PBF"

  finish_full_install

  TOTAL_STEPS=13
  success "Full Greece deployment completed."
  pause
}

download_country_menu() {
  while true; do
    local row name iso parent id url updates slug out c

    banner
    printf "%bCOUNTRY / REGION DOWNLOAD MANAGER%b\n\n" "$BOLD$CYAN" "$RESET"
    printf "  1) Countries only (ISO-3166 list)\n"
    printf "  2) All Geofabrik extracts (countries, states, regions)\n"
    printf "  3) City/custom-area extract from existing PBF\n"
    printf "  4) Download ALL country extracts (very large)\n"
    printf "  5) Download full planet PBF\n"
    printf "  6) Show downloaded datasets\n"
    printf "  0) Back\n\n"

    read -rp "Selection: " c

    case "$c" in
      1|2)
        if [[ "$c" == "1" ]]; then
          select_row_interactive countries || continue
        else
          select_row_interactive all || continue
        fi

        row="$SELECTED_ROW"
        IFS=$'\t' read -r name iso parent id url updates <<<"$row"

        slug=$(sanitize_slug "$id")
        out="$DATA_DIR/${slug}-latest.osm.pbf"

        banner
        printf "%bSelected:%b %s (%s)\n" "$BOLD" "$RESET" "$name" "${iso:--}"
        printf "%bURL:%b      %s\n" "$BOLD" "$RESET" "$url"
        printf "%bUpdates:%b  %s\n" "$BOLD" "$RESET" "${updates:-not-advertised}"
        printf "%bTarget:%b   %s\n\n" "$BOLD" "$RESET" "$out"

        download_url "$url" "$out"

        printf '%s\t%s\t%s\t%s\t%s\n' \
          "$name" "$slug" "$out" "$url" "$updates" \
          > "$STATE_DIR/last-dataset.tsv"

        pause
        ;;
      3)
        extract_city_bbox
        ;;
      4)
        download_all_countries
        pause
        ;;
      5)
        download_planet
        pause
        ;;
      6)
        banner
        find "$DATA_DIR" \
          -maxdepth 1 \
          -type f \
          -printf '%TY-%Tm-%Td %TH:%TM  %10s  %f\n' \
          | sort
        pause
        ;;
      0)
        return
        ;;
      *)
        warn "Invalid selection."
        ;;
    esac
  done
}

download_planet() {
  banner
  printf "%bWARNING:%b Full-planet PBF is extremely large and downstream imports can require hundreds of GB to >1 TB.\n" "$YELLOW$BOLD" "$RESET"
  read -rp "Type PLANET to continue: " confirm
  [[ "$confirm" == "PLANET" ]] || { warn "Cancelled."; return; }
  local out="$DATA_DIR/planet-latest.osm.pbf"
  download_url "$PLANET_PBF" "$out"
  run curl -fL --retry 4 --progress-bar -o "$out.md5" "$PLANET_MD5"
  (cd "$DATA_DIR" && md5sum -c "$(basename "$out").md5") || warn "Planet MD5 check failed; verify manually."
  printf 'Planet\tplanet\t%s\t%s\t%s\n' "$out" "$PLANET_PBF" "https://planet.openstreetmap.org/replication/minute/" > "$STATE_DIR/last-dataset.tsv"
}

choose_local_pbf() {
  local -a files
  mapfile -t files < <(find "$DATA_DIR" -maxdepth 1 -type f -name '*.osm.pbf' | sort)
  if ((${#files[@]} == 0)); then
    warn "No .osm.pbf files found in $DATA_DIR"
    return 1
  fi
  printf "\nAvailable datasets:\n" >&2
  local i=1 f
  for f in "${files[@]}"; do
    printf "%3d) %-55s %8s\n" "$i" "$(basename "$f")" "$(du -h "$f" | awk '{print $1}')" >&2
    ((i++))
  done
  local choice
  read -rp "Select dataset: " choice
  [[ "$choice" =~ ^[0-9]+$ ]] && ((choice>=1 && choice<=${#files[@]})) || return 1
  printf '%s\n' "${files[$((choice-1))]}"
}

osm_cache_mb() {
  local mem_mb cache
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  cache=$((mem_mb * 2 / 3))
  ((cache < 512)) && cache=512
  ((cache > 32768)) && cache=32768
  printf '%s\n' "$cache"
}

reset_gis_db() {
  info "Resetting rendering database '$GIS_DB'..."
  run systemctl stop renderd || true
  run sudo -u postgres dropdb --if-exists "$GIS_DB"
  run sudo -u postgres createdb -E UTF8 -O "$GIS_USER" "$GIS_DB"
  run sudo -u postgres psql -d "$GIS_DB" -c "CREATE EXTENSION postgis; CREATE EXTENSION hstore;"
}

import_render_db() {
  local pbf="${1:-}"
  [[ -n "$pbf" ]] || pbf=$(choose_local_pbf) || return

  [[ -f "$CARTO_DIR/openstreetmap-carto-flex.lua" ]] || {
    error "Carto v6 flex style missing. Run full software install first."
    return 1
  }

  [[ -s "$pbf" ]] || {
    error "OSM PBF is missing or empty: $pbf"
    return 1
  }

  banner
  printf "%bRENDERING DATABASE IMPORT — CARTO v6 FLEX%b\nDataset: %s\n\n" "$BOLD$CYAN" "$RESET" "$pbf"

  read -rp "Recreate GIS database '$GIS_DB'? [y/N]: " yn
  [[ "$yn" =~ ^[Yy]$ ]] && reset_gis_db

  local cache threads
  cache=$(osm_cache_mb)
  threads=$(nproc)
  ((threads > 8)) && threads=8

  # OpenStreetMap Carto v6 uses osm2pgsql flex backend.
  as_user "$GIS_USER" osm2pgsql \
    -O flex \
    -S "$CARTO_DIR/openstreetmap-carto-flex.lua" \
    -d "$GIS_DB" \
    --create \
    -C "$cache" \
    --number-processes "$threads" \
    "$pbf"

  # Required/official Carto v6 database objects.
  [[ -f "$CARTO_DIR/indexes.sql" ]] &&     as_user "$GIS_USER" psql -v ON_ERROR_STOP=1 -d "$GIS_DB" -f "$CARTO_DIR/indexes.sql"

  [[ -f "$CARTO_DIR/functions.sql" ]] &&     as_user "$GIS_USER" psql -v ON_ERROR_STOP=1 -d "$GIS_DB" -f "$CARTO_DIR/functions.sql"

  [[ -f "$CARTO_DIR/common-values.sql" ]] &&     as_user "$GIS_USER" psql -v ON_ERROR_STOP=1 -d "$GIS_DB" -f "$CARTO_DIR/common-values.sql"

  if [[ -f "$CARTO_DIR/scripts/get-external-data.py" ]]; then
    run mkdir -p "$CARTO_DIR/data"
    run chown -R "$GIS_USER:$GIS_USER" "$CARTO_DIR/data"
    as_user "$GIS_USER" bash -lc "cd '$CARTO_DIR' && python3 scripts/get-external-data.py"
  fi

  # Compile the v6 style for renderd/Mapnik.
  as_user "$GIS_USER" bash -lc "cd '$CARTO_DIR' && carto -a '3.0.22' project.mml > mapnik.xml"

  run systemctl restart renderd apache2

  if command -v osm2pgsql-replication >/dev/null 2>&1; then
    as_user "$GIS_USER" osm2pgsql-replication init -d "$GIS_DB" --osm-file "$pbf" ||       warn "Replication init failed; configure it later if needed."
  fi

  success "Rendering import complete using OpenStreetMap Carto v6 flex backend."
}

import_nominatim() {
  local pbf="${1:-}"
  [[ -n "$pbf" ]] || pbf=$(choose_local_pbf) || return
  [[ -x "$NOM_VENV/bin/nominatim" ]] || { error "Nominatim is not installed. Run full software install first."; return 1; }

  banner
  printf "%bNOMINATIM IMPORT%b\nDataset: %s\n\n" "$BOLD$CYAN" "$RESET" "$pbf"
  read -rp "Drop an existing 'nominatim' database before import? [y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    run systemctl stop nominatim.service || true
    run sudo -u postgres dropdb --if-exists nominatim
  fi

  run chown -R "$NOM_USER:$NOM_USER" "$NOM_PROJECT"

  [[ -s "$NOM_PROJECT/.env" ]] || {
    error "Nominatim project configuration is missing: $NOM_PROJECT/.env"
    return 1
  }

  local nom_osm2pgsql
  nom_osm2pgsql="$(command -v osm2pgsql || true)"
  [[ -n "$nom_osm2pgsql" && -x "$nom_osm2pgsql" ]] || {
    error "osm2pgsql is missing or not executable."
    return 1
  }

  grep -q "^NOMINATIM_OSM2PGSQL_BINARY=$nom_osm2pgsql$" "$NOM_PROJECT/.env" || {
    error "Nominatim project has an invalid osm2pgsql binary setting."
    return 1
  }

  info "Nominatim project: $NOM_PROJECT"
  info "Nominatim osm2pgsql: $nom_osm2pgsql"
  as_user "$NOM_USER" bash -lc "cd '$NOM_PROJECT' && '$NOM_VENV/bin/nominatim' import --project-dir '$NOM_PROJECT' --osm-file '$pbf'"

  # The API runs as www-data. Grant read/query access explicitly so Apache/
  # Gunicorn does not hit PostgreSQL "insufficient permissions" errors.
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='www-data'" | grep -q 1; then
    run sudo -u postgres createuser www-data
  fi
  run sudo -u postgres psql -d nominatim -v ON_ERROR_STOP=1 -c 'GRANT CONNECT ON DATABASE nominatim TO "www-data";'
  run sudo -u postgres psql -d nominatim -v ON_ERROR_STOP=1 -c 'GRANT USAGE ON SCHEMA public TO "www-data";'
  run sudo -u postgres psql -d nominatim -v ON_ERROR_STOP=1 -c 'GRANT SELECT ON ALL TABLES IN SCHEMA public TO "www-data";'
  run sudo -u postgres psql -d nominatim -v ON_ERROR_STOP=1 -c 'GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "www-data";' || true
  run sudo -u postgres psql -d nominatim -v ON_ERROR_STOP=1 -c 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO "www-data";' || true

  run systemctl daemon-reload
  run systemctl enable --now nominatim.socket nominatim.service
  success "Nominatim import complete. Endpoint: /nominatim/search and /nominatim/reverse"
}

osrm_profile_path() {
  local profile
  for profile in \
    /usr/share/osrm/profiles/car.lua \
    /usr/local/share/osrm/profiles/car.lua \
    "$OSRM_SRC/profiles/car.lua"; do
    [[ -f "$profile" ]] && { printf '%s\n' "$profile"; return 0; }
  done
  return 1
}

import_osrm() {
  local pbf="${1:-}"
  [[ -n "$pbf" ]] || pbf=$(choose_local_pbf) || return
  command -v osrm-extract >/dev/null 2>&1 || { error "OSRM is not installed."; return 1; }

  local slug profile target base
  slug=$(sanitize_slug "$(basename "$pbf" .osm.pbf)")
  profile=$(osrm_profile_path) || { error "Could not find OSRM car.lua profile."; return 1; }
  target="$OSRM_DATA/$slug"
  run mkdir -p "$target"
  run cp -f "$pbf" "$target/input.osm.pbf"

  banner
  printf "%bOSRM ROUTING IMPORT%b\nDataset: %s\nProfile: %s\n\n" "$BOLD$CYAN" "$RESET" "$pbf" "$profile"
  (
    cd "$target"
    run osrm-extract -p "$profile" input.osm.pbf
    run osrm-partition input.osrm
    run osrm-customize input.osrm
  )
  base="$target/input.osrm"

  cat > /etc/systemd/system/osrm.service <<EOF_OSRM_SERVICE
[Unit]
Description=OSRM routing server
After=network.target

[Service]
Type=simple
ExecStart=$(command -v osrm-routed) --algorithm mld --port $OSRM_PORT $base
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF_OSRM_SERVICE
  run systemctl daemon-reload
  run systemctl enable --now osrm.service
  success "OSRM routing active through /route/ (Apache proxy) and localhost:$OSRM_PORT."
}

import_overpass() {
  local pbf="${1:-}"
  [[ -n "$pbf" ]] || pbf=$(choose_local_pbf) || return
  [[ -x "$OVERPASS_EXEC/bin/update_database" ]] || { error "Overpass is not installed."; return 1; }

  local xmlbz2="$OVERPASS_ROOT/import.osm.bz2"
  banner
  printf "%bOVERPASS DATABASE IMPORT%b\nDataset: %s\n\n" "$BOLD$CYAN" "$RESET" "$pbf"
  warn "Overpass uses its own database format. The PBF will be streamed to OSM XML and bzip2-compressed first."
  read -rp "Erase existing Overpass DB? [y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    run systemctl stop overpass-dispatcher overpass-areas overpass-rules 2>/dev/null || true
    run rm -rf "$OVERPASS_DB"
    run mkdir -p "$OVERPASS_DB"
    run chown -R "$OVERPASS_USER:$OVERPASS_USER" "$OVERPASS_DB"
  fi

  info "Converting PBF -> OSM XML.bz2 (streaming, verbose)..."
  as_user "$OVERPASS_USER" bash -lc "osmium cat '$pbf' -f osm | pv | bzip2 -c > '$xmlbz2'"
  as_user "$OVERPASS_USER" "$OVERPASS_EXEC/bin/init_osm3s.sh" "$xmlbz2" "$OVERPASS_DB" "$OVERPASS_EXEC"

  [[ -d "$OVERPASS_SRC/build-src/rules" ]] && {
    run rm -rf "$OVERPASS_DB/rules"
    run cp -a "$OVERPASS_SRC/build-src/rules" "$OVERPASS_DB/rules"
    run chown -R "$OVERPASS_USER:$OVERPASS_USER" "$OVERPASS_DB/rules"
  }

  configure_overpass_services
  run apache2ctl configtest
  run systemctl reload apache2
  success "Overpass database imported. HTTP API: /overpass/api/interpreter ; CLI: sudo -u overpass $OVERPASS_EXEC/bin/osm3s_query --db-dir=$OVERPASS_DB"
}

configure_overpass_services() {
  cat > /etc/systemd/system/overpass-dispatcher.service <<EOF_OP_DISPATCH
[Unit]
Description=Overpass API OSM dispatcher
After=network.target

[Service]
Type=simple
User=$OVERPASS_USER
Group=$OVERPASS_USER
ExecStart=$OVERPASS_EXEC/bin/dispatcher --osm-base --db-dir=$OVERPASS_DB --allow-duplicate-queries=yes
ExecStop=$OVERPASS_EXEC/bin/dispatcher --terminate
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF_OP_DISPATCH

  cat > /etc/systemd/system/overpass-areas.service <<EOF_OP_AREAS
[Unit]
Description=Overpass API areas dispatcher
After=overpass-dispatcher.service

[Service]
Type=simple
User=$OVERPASS_USER
Group=$OVERPASS_USER
ExecStart=$OVERPASS_EXEC/bin/dispatcher --areas --db-dir=$OVERPASS_DB --allow-duplicate-queries=yes
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF_OP_AREAS

  cat > /etc/systemd/system/overpass-rules.service <<EOF_OP_RULES
[Unit]
Description=Overpass API area rules processor
After=overpass-areas.service

[Service]
Type=simple
User=$OVERPASS_USER
Group=$OVERPASS_USER
Nice=19
IOSchedulingClass=best-effort
IOSchedulingPriority=7
ExecStart=$OVERPASS_EXEC/bin/rules_delta_loop.sh $OVERPASS_DB
Restart=on-failure
RestartSec=20

[Install]
WantedBy=multi-user.target
EOF_OP_RULES

  run systemctl daemon-reload
  run systemctl enable --now overpass-dispatcher.service
  sleep 2
  run chmod 666 "$OVERPASS_DB"/osm3s_* 2>/dev/null || true
  run systemctl enable --now overpass-areas.service overpass-rules.service || warn "Area services may need the base dispatcher to finish startup first."
}

setup_replication_timer() {
  banner
  if ! command -v osm2pgsql-replication >/dev/null 2>&1; then
    error "osm2pgsql-replication is not installed by the packaged osm2pgsql version."
    return 1
  fi

  local pbf
  pbf=$(choose_local_pbf) || return
  as_user "$GIS_USER" osm2pgsql-replication init -d "$GIS_DB" --osm-file "$pbf"

  cat > /etc/systemd/system/osm2pgsql-update.service <<EOF_REPL_SVC
[Unit]
Description=Update OpenStreetMap rendering database
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=oneshot
User=$GIS_USER
Group=$GIS_USER
ExecStart=$(command -v osm2pgsql-replication) update -d $GIS_DB -- --number-processes $(nproc) -C $(osm_cache_mb)
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=6
EOF_REPL_SVC

  cat > /etc/systemd/system/osm2pgsql-update.timer <<'EOF_REPL_TIMER'
[Unit]
Description=Run OSM replication update every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF_REPL_TIMER

  run systemctl daemon-reload
  run systemctl enable --now osm2pgsql-update.timer
  success "Rendering replication timer enabled every 5 minutes."
  pause
}

stack_prereqs_ready() {
  local missing=0
  command -v osm2pgsql >/dev/null 2>&1 || { warn "Missing osm2pgsql"; missing=1; }
  [[ -x "$NOM_VENV/bin/nominatim" ]] || { warn "Missing Nominatim"; missing=1; }
  command -v osrm-extract >/dev/null 2>&1 || { warn "Missing OSRM"; missing=1; }
  [[ -x "$OVERPASS_EXEC/bin/update_database" ]] || { warn "Missing Overpass API"; missing=1; }
  [[ -f "$CARTO_DIR/openstreetmap-carto.style" ]] || { warn "Missing OpenStreetMap Carto"; missing=1; }
  if ((missing)); then
    error "Full software stack is not installed yet. Run main menu option 1 first."
    return 1
  fi
}

full_auto_country_deployment() {
  stack_prereqs_ready || { pause; return; }
  local row name iso parent id url updates slug pbf
  select_row_interactive countries || return
  row="$SELECTED_ROW"
  IFS=$'\t' read -r name iso parent id url updates <<<"$row"
  slug=$(sanitize_slug "$id")
  pbf="$DATA_DIR/${slug}-latest.osm.pbf"

  banner
  printf "%bFULL AUTO COUNTRY DEPLOYMENT%b\n\n" "$BOLD$CYAN" "$RESET"
  printf "Country: %s (%s)\nDataset: %s\n\n" "$name" "$iso" "$pbf"
  printf "This will deploy:\n"
  printf "  • Raster rendering DB + Mapnik/mod_tile\n"
  printf "  • Nominatim geocoding/reverse geocoding\n"
  printf "  • OSRM car routing\n"
  printf "  • Overpass local query database\n"
  printf "  • Leaflet portal and health services\n\n"
  read -rp "Type DEPLOY to continue: " confirm
  [[ "$confirm" == "DEPLOY" ]] || { warn "Cancelled."; return; }

  [[ -f "$pbf" ]] || download_url "$url" "$pbf"
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$slug" "$pbf" "$url" "$updates" > "$STATE_DIR/last-dataset.tsv"

  import_render_db "$pbf"
  import_nominatim "$pbf"
  import_osrm "$pbf"
  import_overpass "$pbf"

  success "Full country deployment completed for $name."
  pause
}

ssl_menu() {
  banner
  printf "%bAPACHE HTTPS / LET'S ENCRYPT%b\n\n" "$BOLD$CYAN" "$RESET"
  read -rp "Public DNS name pointing to this server (example: maps.example.com): " domain
  [[ -n "$domain" ]] || return
  read -rp "Email for Let's Encrypt notices: " email
  [[ -n "$email" ]] || return
  run certbot --apache -d "$domain" --non-interactive --agree-tos -m "$email" --redirect
  success "HTTPS enabled for $domain"
  pause
}


npm_backend_info() {
  banner
  printf "%bNGINX PROXY MANAGER BACKEND%b\n\n" "$BOLD$CYAN" "$RESET"
  printf "Scheme:       http\nForward Host: this VM's LAN IP\nForward Port: %s\n\n" "$APACHE_PORT"
  printf "Endpoints:\n  /osm/\n  /tile/\n  /nominatim/\n  /route/\n  /overpass/api/\n  /telemetry/\n\n"
  printf "Public 80/443 and TLS stay on Nginx Proxy Manager.\n"
  pause
}

health_screen() {
  banner
  if command -v osm-health >/dev/null 2>&1; then
    osm-health
  else
    warn "Health helper not installed yet."
    systemctl --no-pager --full status postgresql apache2 renderd 2>/dev/null || true
  fi
  printf "\n%bRecent renderd logs:%b\n" "$BOLD" "$RESET"
  journalctl -u renderd -n 15 --no-pager 2>/dev/null || true
  pause
}

advanced_menu() {
  while true; do
    banner
    printf "%bADVANCED / MAINTENANCE%b\n\n" "$BOLD$CYAN" "$RESET"
    printf "  1) Import selected PBF -> Rendering DB\n"
    printf "  2) Import selected PBF -> Nominatim\n"
    printf "  3) Import selected PBF -> OSRM\n"
    printf "  4) Import selected PBF -> Overpass\n"
    printf "  5) Configure rendering replication timer\n"
    printf "  6) Show Nginx Proxy Manager backend settings\n"
    printf "  7) Backup configuration now\n"
    printf "  8) Restart all installed services\n"
    printf "  0) Back\n\n"
    read -rp "Selection: " c
    case "$c" in
      1) import_render_db; pause ;;
      2) import_nominatim; pause ;;
      3) import_osrm; pause ;;
      4) import_overpass; pause ;;
      5) setup_replication_timer ;;
      6) npm_backend_info ;;
      7) /usr/local/sbin/osm-backup-configs.sh 2>/dev/null || warn "Backup helper not installed."; pause ;;
      8)
        for s in postgresql apache2 renderd nominatim.socket nominatim.service osrm.service overpass-dispatcher.service overpass-areas.service overpass-rules.service osm-telemetry.service; do
          systemctl list-unit-files | grep -q "^${s}" && run systemctl restart "$s" || true
        done
        success "Installed services restarted."; pause ;;
      0) return ;;
      *) warn "Invalid selection." ;;
    esac
  done
}

main_menu() {
  require_root
  load_os_release
  ensure_dirs

  while true; do
    banner
    hardware_report
    printf "\n%bMAIN MENU%b\n\n" "$BOLD$CYAN" "$RESET"
    printf "  %b1)%b FULL SOFTWARE INSTALL — all components, no dataset import\n" "$GREEN" "$RESET"
    printf "  %b2)%b FULL GREECE DEPLOYMENT — fresh VM, everything + Greece\n" "$GREEN" "$RESET"
    printf "  3) Full Auto Country Deployment — selected country + all imports\n"
    printf "  4) Maps / Country / Region / City / Planet manager\n"
    printf "  5) Advanced imports / updates / NPM / maintenance\n"
    printf "  6) Health / service status\n"
    printf "  7) Show installer log\n"
    printf "  8) Toggle verbose / quiet\n"
    printf "  0) Exit\n\n"
    read -rp "Selection: " choice
    case "$choice" in
      1) full_install ;;
      2) full_greece_deployment ;;
      3) full_auto_country_deployment ;;
      4) download_country_menu ;;
      5) advanced_menu ;;
      6) health_screen ;;
      7) less +G "$LOG_FILE" ;;
      8) if [[ "$OSM_VERBOSE" == "1" ]]; then OSM_VERBOSE=0; else OSM_VERBOSE=1; fi ;;
      0) banner; printf "%bBye.%b\n" "$GREEN" "$RESET"; exit 0 ;;
      *) warn "Invalid selection."; sleep 1 ;;
    esac
  done
}

main_menu "$@"
