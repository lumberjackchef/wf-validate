#!/usr/bin/env bash
# JAR-2563/JAR-590: the Deploy-via-SSH remote script, extracted from
# .github/workflows/deploy.yml. GitHub enforces a 21000-char cap on
# expressions inside workflow files; this script grew past it when the
# rolling deploy landed, failing every run at parse time with zero jobs.
# deploy.yml ships this file to the target host (sync step) and invokes it
# with a thin wrapper; DEPLOY_SHA / REGISTRY / REGISTRY_NAME (the values
# the inline version took from ${{ }} expressions) arrive through the
# ssh-action `envs:` forward list alongside PROD_DIR and the rest.
#
# Contract: run from $PROD_DIR as the deploy user, with
# DEPLOY_SHA REGISTRY REGISTRY_NAME PROD_DIR OBS_CONFIG_FILES
# BOUNDARY_ALLOW_PORTS DEPLOY_SERVICES in the environment.
set -e

# JAR-756: podman-compose needs the working directory that holds
# podman-compose.yml (synced from the repo by the step above).
# $PROD_DIR, forwarded via envs: above. /root/jarvis when
# DEPLOY_USER is root, which is what it was before JAR-768.
cd "$PROD_DIR"

# JAR-590: prod-2 widens its metrics binds to its VPC address so
# prod's Prometheus can scrape cross-host. Self-detect the VPC IP
# (eth1) rather than matching on host name: the exported value is
# consumed by podman-compose's ${METRICS_BIND_ADDR:-127.0.0.1}
# interpolation below. Prod keeps the loopback default.
# Only the SECOND droplet widens: prod's metrics stay loopback
# (its boundary admits nothing on 9090-9095, and its Prometheus is
# the scraper, not a scrapee). Matching the specific .7 address is
# deliberate: the firewall rule and this export name the same host.
# Prod explicitly keeps loopback (the pass-through guard requires
# the env to EXIST for dict-form compose keys; absent env = the
# JAR-1340 silent-omission crash class).
if [ "$(ip -o -4 addr show | awk '$4 ~ /^10\.108\.0\.7\// {print $4}' | cut -d/ -f1 | head -1)" = "10.108.0.7" ]; then
  export METRICS_BIND_ADDR="10.108.0.7"
  export HEALTH_BIND_ADDR="10.108.0.7"
  echo "JAR-590: metrics/liveness binds widened to 10.108.0.7"
else
  export METRICS_BIND_ADDR="127.0.0.1"
  export HEALTH_BIND_ADDR="127.0.0.1"
fi

# Fail-closed: validate the synced compose before pulling images
# or touching any container (JAR-756 review finding).
# podman-compose 1.0.6 on prod has no `config -q` (JAR-756
# integration run 31223117196); validate by discarding the
# merged output instead.
podman-compose config >/dev/null

echo "=== Deploying release $DEPLOY_SHA ==="

# Login to DOCR
doctl registry login

# Stage the rollback point: whatever is running now becomes
# :previous. || true only covers the very first deploy, when no
# :current image exists yet.
for service in ${DEPLOY_SERVICES:?DEPLOY_SERVICES must be forwarded via the step envs: list}; do
  podman tag $REGISTRY/$REGISTRY_NAME/$service:current \
             $REGISTRY/$REGISTRY_NAME/$service:previous 2>/dev/null || true
done

# Pull specific SHA-tagged images
for service in ${DEPLOY_SERVICES:?DEPLOY_SERVICES must be forwarded via the step envs: list}; do
  echo "Pulling $service:$DEPLOY_SHA..."
  podman pull $REGISTRY/$REGISTRY_NAME/$service:$DEPLOY_SHA
  # Tag as 'current' for easy rollback reference
  podman tag $REGISTRY/$REGISTRY_NAME/$service:$DEPLOY_SHA \
             $REGISTRY/$REGISTRY_NAME/$service:current
done

# Update compose file to use SHA-tagged images
export IMAGE_TAG=$DEPLOY_SHA

# Fetch secrets from Infisical (JAR-747, ADR-009). Fail-closed:
# fetch-secrets.py exits non-zero if Infisical is unreachable or
# returns zero secrets, aborting the deploy before compose runs.
python3 "$PROD_DIR/fetch-secrets.py" prod "$PROD_DIR/.env"

# JAR-1340: podman-compose.yml passes secrets through by NAME
# (`JWT_PRIVATE_KEY:` with no value), so podman reads each value
# from its own environment rather than having it interpolated onto
# the command line — where podman-compose echoes it into this log.
# That is why thirteen credentials, including the RSA key that signs
# session tokens, printed unmasked across 100 retained runs.
#
# `set -a` + `.` is the sh reader $PROD_DIR/.env was designed for
# (JAR-1029 quotes every value so that sourcing it and
# podman-compose's dotenv parser agree byte-for-byte). This is not a
# third parser; it is the one graph-sync.yml and backup-db.sh use.
#
# Sourcing is evaluation, and .env is machine-generated from
# Infisical. A secret that happened to be named IMAGE_TAG would
# silently replace the SHA this deploy is pinning — a green deploy
# of the wrong images. Refuse rather than discover it later.
for RESERVED in PROD_DIR IMAGE_TAG DEPLOY_USER OBS_CONFIG_FILES REGISTRY REGISTRY_NAME BOUNDARY_ALLOW_PORTS DEPLOY_SERVICES; do
  # The name is interpolated into an ERE below; refuse any
  # future reserved name carrying regex metacharacters so the
  # guard can never silently widen or narrow its match.
  case "$RESERVED" in
    *[![:upper:][:digit:]_]*) echo "FATAL: reserved name '$RESERVED' is not an ERE-safe identifier - keep reserved names to [A-Z0-9_]" >&2; exit 1 ;;
  esac
  # Also match `export X=` and leading-whitespace spellings: the
  # .env is sourced under set -a, so any of those forms would
  # clobber the workflow-supplied value just like a bare `X=`.
  if grep -qE "^[[:space:]]*(export[[:space:]]+)?${RESERVED}[[:space:]]*=" "$PROD_DIR/.env"; then
    echo "FATAL: $PROD_DIR/.env defines ${RESERVED}, which is one of this script's own" >&2
    echo "       control variables. Rename it in Infisical; sourcing would clobber the deploy." >&2
    exit 1
  fi
done

set -a
. "$PROD_DIR/.env"
set +a

# The GF_* aliases used to be five `export` lines RIGHT HERE, and
# that was the bug (core#717 review, MEDIUM-1): they existed only
# inside this run: block, so the documented manual path —
# `set -a; . ./.env; podman-compose up -d`, what a human runs during
# a restart or a recovery — got none of them. Grafana booted with no
# admin password and no SMTP alerting, silently, on exactly the path
# taken when something is already wrong.
#
# fetch-secrets.py now writes them into .env, so the `set -a` source
# above supplies them and both paths get the same environment. Same
# for DATABASE_URL / REDIS_URL, which it now composes rather than
# leaving to compose's ${VAR} interpolation (MEDIUM-2).

# Degraded-feature check (JAR-757 Path A): dashboard-only secrets
# (Clerk/Stripe webhook signing) are not deploy blockers — the
# services boot and the affected features fail loud at use. Print
# a visible warning per missing secret so the deploy log is the
# signal, never silence. AI_SERVICE_INTERNAL_KEY is included:
# its absence crash-loops the sidecar (health check catches it),
# and DO_INFERENCE_API_KEY absence degrades /v1/embed per call.
for K in CLERK_SECRET_KEY CLERK_WEBHOOK_SECRET STRIPE_WEBHOOK_SECRET AI_SERVICE_INTERNAL_KEY DO_INFERENCE_API_KEY GRAFANA_ADMIN_PASSWORD; do
  if ! grep -qE "^${K}=.+" "$PROD_DIR/.env"; then
    echo "  ⚠️ ${K} missing/empty — feature DEGRADED until provisioned in Infisical"
  fi
done

# JAR-456 liveness endpoints — THE single source for the health
# checks of ALL services: the pre-deploy pin assertion and the
# post-deploy health loop below both iterate this array (svc:ENV_KEY:port/path).
# Add a service's entry here when it ships an endpoint; nothing else.
LIVE_ENDPOINTS=('trip-core:HTTP_PORT:8080/v1/health' 'ai:AI_SERVICE_PORT:8081/v1/health' 'user-auth:HTTP_PORT:8082/health' 'ml:HTTP_PORT:8083/health' 'analytics:HTTP_PORT:8084/health' 'external-data:METRICS_PORT:9090/health')

# Assert every pin against the synced compose BEFORE any container
# is replaced. The parser lives in
# deployments/assert-liveness-pins.sh, shipped to $PROD_DIR by the
# compose-sync step above and executed in CI by
# deployments/liveness_sync_test.go against the real compose and
# mutation fixtures — the deploy runs exactly the code CI tests
# (OCR round-17: the parser previously lived inline here, where
# the yaml.v3-based CI guard never executed it, so a reformat that
# yaml still parsed — flow map, anchor — could pass CI green yet
# abort every deployment).
# Contract: compose must pin ports in
# block-style mappings (`KEY: "8083"` under the top-level
# `services:` section); list style (`- KEY=8083`), ${VAR}
# interpolation, or flow maps (`env: {KEY: "8083"}`) cannot
# match — fail-closed by design.
./assert-liveness-pins.sh podman-compose.yml "${LIVE_ENDPOINTS[@]}"

# JAR-1340, and this is the half that bites: a pass-through name
# that is NOT in the environment is not an error to podman — it
# OMITS the variable from the container, silently. An absent
# INTERNAL_GRPC_SECRET is what rolled the JAR-1330 deploy back, and
# an absent JWT_PRIVATE_KEY stops user-auth booting at all. Runs
# before any container is replaced, like the pin assertion above.
# Set-but-empty passes: that is today's behaviour, and the
# degraded-feature warning above is the existing policy for it.
./assert-env-passthrough.sh podman-compose.yml --check-exported

podman-compose up -d

# JAR-1326 review round 2: ONE rollback body, two callers — a
# health-check failure and a boundary violation must restore the
# exact same previously-blessed state, so a violating release can
# never survive as the next deploy's rollback point.
rollback_to_previous() {
  for service in ${DEPLOY_SERVICES:?DEPLOY_SERVICES must be forwarded via the step envs: list}; do
    # WARN (not silent) on a failed tag: a missing :previous for
    # any reason other than the genuine first-deploy edge must be
    # visible in the log when the rollback misbehaves later.
    if ! podman tag $REGISTRY/$REGISTRY_NAME/$service:previous \
               $REGISTRY/$REGISTRY_NAME/$service:current 2>/dev/null; then
      echo "WARN: no :previous image for $service (first deploy?) — rollback will not restore it"
    fi
  done
  # Restore the pre-deploy compose so the rollback re-applies
  # the config that was actually running (JAR-756 finding 2).
  # Only a MISSING backup is benign (first deploy); a real copy
  # error must fail the rollback loudly — continuing with the
  # just-failed compose would let the violating spec survive.
  if [ -f podman-compose.yml.previous ]; then
    cp podman-compose.yml.previous podman-compose.yml
  fi
  # JAR-458: same symmetry for the observability configs — a
  # rollback must re-apply the config set the previous
  # containers ran with, not the configs that shipped with the
  # failed deploy. Silent only on the first-deploy edge (no
  # .previous yet); a real copy error fails the rollback loudly.
  for f in $OBS_CONFIG_FILES; do
    if [ -f "observability/$f.previous" ]; then
      cp "observability/$f.previous" "observability/$f"
    fi
  done
  # --remove-orphans removes containers whose service is absent
  # from the restored compose (subsumes the old ai-only special
  # case, JAR-458): a NEW network-exposed service from a violating
  # deploy must not survive the rollback as an unrecognized
  # listener.
  if ! IMAGE_TAG=previous podman-compose up -d --remove-orphans; then
    echo "FATAL: rollback compose failed to start — inspect the fleet manually" >&2
    exit 1
  fi
}

# JAR-1326: verify the network boundary against the LIVE listener
# table IMMEDIATELY after the fleet comes up — before the health
# loop (which can run ~9 min on a wedged fleet) and BEFORE nginx
# switches traffic. Host networking means a violating bind is
# directly reachable on the droplet IP the moment the container
# starts, so the scan runs at the earliest possible instant.
# Scope of this gate: WHICH ports have non-loopback listeners.
# WHO can reach them is the cloud firewall's job (source-
# restricted tcp/22, public 80/443) — the two layers are
# complementary, and this scan cannot detect a mis-opened
# firewall source range; re-verify the firewall after any change.
# The rollback below means the violation can never survive as the
# next deploy's rollback point. The source-tree guard
# (TestNoServiceBindsAllInterfacesDirectly) catches one Go bind
# spelling; this catches every mechanism. Fail-closed: an
# unparseable or empty scan aborts the deploy. CI executes this
# exact script against a deliberately exposed 0.0.0.0 fixture
# (deployments/assert_external_binds_test.go).
# JAR-1326 (round-18): one enforcer, two call sites. On a
# violation: with a previous state, restore it and re-verify the
# restored release (it predates this gate); without one (first
# deploy), stop the fleet and verify it is dark. Either way the
# deploy ends red - a violating fleet is never served and never
# becomes the next rollback point.
# ROUND-38 STRUCTURAL SAFETY: enforce_boundary RETURNS non-zero and
# the bare top-level statements below let set -e terminate the
# rollout on it. Wrapping the call in $(), a pipeline, or `|| true`
# would both swallow the abort AND silently disable errexit for the
# whole function body (breaking its unchecked `cp` steps) - so the
# bare-statement convention is a structural requirement, not style.
# verify_restored_boundary (round-71): the restored release
# predates this gate, so re-scan it; a still-violating restore
# prints the FATAL and the caller's `|| exit 1` ends the deploy.
verify_restored_boundary() {
  if ! bash "$PROD_DIR/assert-external-binds.sh" "$BOUNDARY_ALLOW_PORTS"; then
    echo "FATAL: restored previous release still violates the boundary allowlist — inspect the host manually" >&2
    return 1
  fi
  return 0
}

enforce_boundary() {
  # Fail fast by name if the envs: forward ever drifts (round-35).
  local allow="${1:?BOUNDARY_ALLOW_PORTS must be forwarded via the step envs: list}"
  if bash "$PROD_DIR/assert-external-binds.sh" "$allow"; then
    return 0
  fi
  echo "=== BOUNDARY VIOLATION - Rolling back; the violating fleet is never served ==="
  if [ -f podman-compose.yml.previous ]; then
    rollback_to_previous
    verify_restored_boundary
    echo "Rolled back to previous deployment after boundary violation"
  else
    echo "FATAL: no pre-deploy backup (first deploy?) — no previous release to restore; stopping the fleet" >&2
    if ! podman-compose stop; then
      echo "FATAL: failed to stop the first-deploy fleet — refusing to leave the boundary violation live" >&2
      return 1
    fi
    if bash "$PROD_DIR/assert-external-binds.sh" "$allow"; then
      echo "First-deploy violating fleet stopped; boundary clear. Deploy aborted."
    else
      echo "FATAL: non-loopback listeners still present after first-deploy stop — inspect the host manually" >&2
    fi
  fi
  return 1
}
enforce_boundary "$BOUNDARY_ALLOW_PORTS"


# Health check: every service now has a curl-able liveness
# endpoint. trip-core :8080/v1/health; user-auth :8082/health
# (HTTP_PORT added JAR-757/F3, closing the blind spot where a
# crash-looping user-auth deployed "green"); ai :8081/v1/health;
# ml :8083/health and analytics :8084/health (JAR-456 — same
# blind spot closed for the remaining gRPC-only services);
# external-data :9090/health (rides the JAR-413 metrics server).
# Health check for ALL services from the SAME LIVE_ENDPOINTS list
# the pin assertion used — one list, two guards, no second copy.
echo "=== Running health checks ==="
ALL_HEALTHY=true
for entry in "${LIVE_ENDPOINTS[@]}"; do
  svc="${entry%%:*}"
  port_path="${entry#*:}"
  port_path="${port_path#*:}"
  echo "Checking ${svc}..."
  # Budgets per service (review round 15: 10 attempts cut the
  # fast-fail budget to ~11s and rolled back services that take
  # 11-31s to bind — cold PG pool, slow migrations):
  #   fast-fail (connection refused while booting): 30 x
  #     (~0.1s refuse + 1s sleep) ~= 33s — at or above the top
  #     of the documented 11-31s bind window, so no service
  #     that previously passed can now be rolled back while
  #     still booting (OCR round-17: the round-16 20-attempt
  #     loop gave ~21s and dropped binders in the 22-31s
  #     window that the original 30-attempt loop passed).
  #   wedged (accept queue up, handler dead; the exact case the
  #     curl timeouts target): 30 x (2s max-time + 1s sleep) =
  #     90s, so all six services cap at ~9.2 min — safely inside
  #     the deploy job's 15-minute timeout, so a fleet-wide
  #     failure still reaches the rollback block instead of the
  #     job being killed mid-loop.
  # Bash-native counter, not $(seq): if seq were missing the
  # substitution would expand empty, the loop would run zero
  # attempts, and the service would be reported healthy without
  # a single check — a fail-open the curl guards cannot catch.
  for ((i = 1; i <= 30; i++)); do
    # --connect-timeout/--max-time keep a wedged-but-listening
    # container (accept queue up, handler dead) from blocking the
    # attempt forever: the loop must reach its cap and set
    # ALL_HEALTHY=false so the rollback block actually runs.
    if curl -sf --connect-timeout 2 --max-time 2 "http://localhost:${port_path}" > /dev/null 2>&1; then
      echo "  ✅ ${svc} is healthy"
      break
    fi
    if [ "$i" -eq 30 ]; then
      echo "  ❌ ${svc} failed health check after 30 attempts (fast-fail budget ~33s, wedged worst case ~90s)"
      ALL_HEALTHY=false
    fi
    sleep 1
  done
done


if [ "$ALL_HEALTHY" = false ]; then
  echo "=== HEALTH CHECKS FAILED - Rolling back ==="
  # Health failures may be transient (single-service crash-loop),
  # so unlike a boundary violation the fleet is never stopped: with
  # a recoverable previous state we restore it; without one (first
  # deploy, or a silently-failed backup) the attempted release
  # stays up unserved, matching the pre-gate behavior.
  if [ -f podman-compose.yml.previous ]; then
    rollback_to_previous
    # The restored release predates this gate - re-verify its
    # boundary before calling the rollback done (round-62).
    verify_restored_boundary || exit 1
    echo "Rolled back to previous deployment"
  else
    echo "WARN: no pre-deploy compose backup (first deploy, or the backup copy failed silently) - leaving the attempted release running for inspection; nginx still serves the previous config from memory and proxies to these containers"
  fi
  exit 1
fi

# Settled-fleet re-scan: services with restart policies or
# ordered startup can bind AFTER the fleet-up scan, so the
# boundary is re-verified on the fully-settled fleet before
# nginx switches traffic. A violation here ends the deploy red.
# The allowlist source matches the enforcer's internal calls
# ($BOUNDARY_ALLOW_PORTS forwarded by envs: into this script).
enforce_boundary "$BOUNDARY_ALLOW_PORTS"

# Reload nginx (deploy user has a scoped NOPASSWD sudoers entry).
# No || true: if the reload fails, traffic may still hit the old
# release — the deploy must report failure, not success.
sudo nginx -s reload

# JAR-1245: podman-compose up -d above RECREATED any service
# whose image changed, killing that service's `podman logs -f`
# follower in the log-shipper unit. The unit self-heals via
# Restart=always, but restart it here so shipping resumes from
# clean followers immediately. Not fully silent: a missing unit
# is expected (hosts that never installed the shipper), but any
# OTHER failure is logged so a post-deploy log gap is
# diagnosable from this run's output. A non-login SSH session
# may lack XDG_RUNTIME_DIR — point it at the deploy user's
# runtime dir explicitly when unset.
# OCR run 33822261505: derive the fallback unconditionally from
# the runtime dir's existence - a session with XDG_RUNTIME_DIR
# already set but pointing at a dead dir gets the same retry as
# an unset one, and a live session is never restarted twice.
# OCR round-4 (run 33824695355): plain restart, not try-restart -
# try-restart is a silent SUCCESS no-op on a present-but-FAILED
# unit (shipper hit its start limit), which would leave shipping
# down with no WARN. restart revives failed units and still
# fails loudly on a missing unit (the WARN branch below).
first_out=""
if ! first_out=$(timeout 10s systemctl --user restart jarvis-log-ship.service 2>&1); then
  # OCR round-7: probe the unit FILE FIRST - it needs no bus -
  # so hosts that never installed the shipper get the benign
  # INFO even without a runtime dir, and WARN is reserved for
  # genuinely un-restartable installs. OCR round-7: every
  # systemctl call is bounded (timeout 10s) so a wedged user
  # manager can't hang the tail of an already-live deploy.
  if [ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/jarvis-log-ship.service" ]; then
    echo "INFO: jarvis-log-ship unit not installed on this host; skipping restart (expected on hosts without the shipper)"
  elif [ -d "/run/user/$(id -u)" ]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
    if ! restart_out=$(timeout 10s systemctl --user restart jarvis-log-ship.service 2>&1); then
      echo "WARN: could not restart jarvis-log-ship: ${restart_out:-${first_out:-unknown error}}; app-log shipping may lag one respawn"
    fi
  else
    echo "WARN: no user session bus at /run/user/$(id -u); could not restart jarvis-log-ship (${first_out:-unknown error}); app-log shipping may lag one respawn"
  fi
fi

# Tag successfully deployed images as 'deployed'. No || true: the
# images were just pulled, so a tagging failure is a real error.
# (:previous was staged from :current before the pull, so the next
# rollback point is already in place.)
for service in ${DEPLOY_SERVICES:?DEPLOY_SERVICES must be forwarded via the step envs: list}; do
  podman tag $REGISTRY/$REGISTRY_NAME/$service:$DEPLOY_SHA \
             $REGISTRY/$REGISTRY_NAME/$service:deployed
done

echo "=== Deployment of $DEPLOY_SHA completed successfully ==="
