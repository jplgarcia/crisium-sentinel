# crisium-sentinel

Run [crisium](https://github.com/cartesi/machine-emulator/blob/v0.23.0/doc/recipes/crisium.lua) as a PRT
sentinel for an existing Cartesi application. You give it an Ethereum RPC, the application's address,
and a URL to the application's template, and you get one container. That container replays every epoch
from the chain, computes the honest claims itself, and reports what it sees through the anomaly handler in `handler/`: a JSON-lines log plus an optional
Discord or Slack webhook.

The sentinel signs nothing and needs no key. It does not talk to a rollups node or a sling: it reads
only `eth_*` methods from the RPC. That keeps it independent of the validators it watches.

## What it watches

These are crisium's anomalies. The handler adds a severity, the recipients, a summary and a suggested
action to each. On the webhook, each alarm is a colored embed (Discord) or attachment (Slack):
- **guardian** (red): every field, the full hashes and crisium's raw message;
- **operator** (orange) and **warn** (yellow): a compact card with short hashes and the next step;
- **self** (gray): log only, unless `CRISIUM_ALERTS_WEBHOOK_MIN=self`.

| Situation | Anomaly |
|---|---|
| A rival joins with a commitment different from the one crisium computed | `conflicting_claim` |
| A match of the honest commitment is lost | `lost_match` |
| A wrong result is staged (state hash or outputs root differs from the replay) | `staged_tournament_result_mismatch` |
| A sentry votes a different state, or has not voted | `sentry_claim_mismatch`, `sentry_claim_missing` |
| A move the honest side must make is still missing near its window's end, or the window closed | `deadline_near`, `missed_deadline` |
| A move without a window (staging, acceptance, cleanup) is overdue | `stalled_action` |
| The honest claim was never joined | `unjoined_claim` |
| The machine wrote an outputs root that differs from its outputs | `outputs_merkle_root_mismatch` |
| The replay stopped (halt, exception, cycle limit) | `execution_stopped` |
| An oversized output or a delegate-call voucher was emitted | `oversized_output`, `delegate_call_voucher` |

Not covered here:
- a stalled or lying RPC. A stalled RPC silences every anomaly above, so watch the healthcheck, and use
  your own node or a provider other than the validators';
- suspicious vouchers. That watchdog depends on the application;
- sequencer state.

## Parameters

| Variable | Required | Meaning |
|---|---|---|
| `RPC_URL` | yes | Ethereum JSON-RPC, `http://` or `https://`. It must serve `eth_getLogs` and `finalized` blocks. crisium's own client speaks plain HTTP only, so for `https://` the container runs a local TLS proxy (`sentinel/rpc-proxy.py`) that verifies the provider's certificate and never logs the URL. |
| `APPLICATION` | yes | The application contract. Its consensus, tournament factory and template hash are read from it. |
| `TEMPLATE_URL` | yes | A `.tar.gz` of the application's stored template machine (the directory with `config.json`), published by the application team. |
| `TEMPLATE_SHA256` | recommended | The tarball's SHA-256. If it differs, the container stops before running anything. |
| `LABEL` | no | Name in logs and alerts (default `sentinel`). |
| `CRISIUM_ALERTS_WEBHOOK` | no | Discord or Slack webhook. If empty, alerts go to the log only. Keep it in a secret, not in a file under version control. |
| `CRISIUM_ALERTS_WEBHOOK_MIN` | no | Lowest severity posted: `guardian`, `operator`, `warn` (default) or `self`. |
| `CRISIUM_ALERTS_WEBHOOK_FORMAT` | no | `discord` (default) or `slack`. |
| `CRISIUM_ALERTS_RUNBOOK` | no | A runbook URL added to each alarm; `{kind}` is replaced by the anomaly kind. |
| `CRISIUM_ALERTS_MENTION` | no | Text posted above guardian alarms, for example a Discord role mention `<@&ROLE_ID>`. |
| `WS_URL` | no | The provider's WebSocket endpoint, which pushes new heads, instead of polling. |
| `WARNING_BLOCKS`, `FIRST_EPOCH`, `POLL_INTERVAL` | no | crisium's `--warning-blocks`, `--first-epoch` and `--poll-interval`. |
| `CRISIUM_ARGS` | no | Any other crisium options, separated by spaces. |
| `STATUS_MAX_AGE` | no | Healthcheck limit, in seconds without a finished pass (default 300). |

Other handler variables (`CRISIUM_ALERTS_*`, listed at the top of `handler/crisium_alerts.lua`) pass
through. The entrypoint fills in four of them:
- `CRISIUM_ALERTS_SOURCE`;
- `CRISIUM_ALERTS_VERSION`;
- `CRISIUM_ALERTS_TEMPLATE_HASH`;
- `CRISIUM_ALERTS_PROVIDER`: the RPC host only, never the full URL, which may carry an API key.

## What happens at start

1. **Template.** The template is downloaded once per `TEMPLATE_URL` and checked against `TEMPLATE_SHA256`.
   A new URL replaces the template, the checkpoints and the state.
   Its `MARCHID` must be this image's emulator's (23 for v0.23.0). A template built for another release
   stops the container with both values, since crisium exists only in v0.23.0 and later.
2. **Preflight** (`sentinel/preflight.lua`):
   - reads the application's consensus, tournament factory and geometry;
   - stores the epoch-0 checkpoint from the template;
   - checks the checkpoint's hash against the application's `getTemplateHash()`. A different template
     stops the container with both hashes in the log.
3. **crisium.** It checks the emulator's uarch against the on-chain verifier, then replays from
   epoch 0 until it reaches the chain. On an application with many epochs this first catch-up takes a
   while; the healthcheck's start period is 30 minutes.

Everything it keeps lives in `/data` (template, checkpoints, state, `alerts.jsonl`, `status.json`). Mount a
volume there and a restart resumes where it stopped. crisium keeps only the newest finished epoch's files
(`--keep-epochs=1`), so the volume stays a few times the template's size.

The healthcheck (`sentinel/healthcheck.sh`) fails when `status.json` is older than `STATUS_MAX_AGE`. crisium
rewrites it after every pass, so a stuck process or an unreachable RPC turns the container unhealthy.

## Versions

The image pins one consistent set:
- **machine-emulator `v0.23.0`.** The release `.deb` is installed with its SHA-256 checked. crisium and
  its recipes come from the `machine-emulator` submodule at the same tag.
- **Dave contract artifacts `v3.0.0-alpha.8-test1`** (`DAVE_VERSION`). Some Dave releases ship only
  `IApplication.json` and `IInputBox.json`, while crisium loads `Application.json` and `InputBox.json`.
  The build copies the interfaces under those names when they are missing.
- **The handler:** `handler/crisium_alerts.lua`, in this repository.

The application must have been built for the same emulator (the same `MARCHID`). crisium refuses to
start if the emulator's uarch differs from the one the application's contracts verify against.

To move to another emulator release, update the submodule to its tag and set `EMULATOR_VERSION`.
Update its checksums too: `EMULATOR_SHA256_amd64` and `EMULATOR_SHA256_arm64`, from the release's asset
digests. For another Dave release, set `DAVE_VERSION` and `DAVE_ARTIFACTS_SHA256` (an empty value skips
the check).

```bash
git submodule update --init
docker build -t crisium-sentinel .
```

## Docker Compose (any host)

```bash
cp .env.example .env     # fill in RPC_URL, APPLICATION, TEMPLATE_URL, TEMPLATE_SHA256
docker compose up -d --build
docker compose logs -f sentinel
docker compose exec sentinel tail -f /data/alerts.jsonl
```

To watch several applications, run one project per application, each with its own env file:

```bash
docker compose -p app-a --env-file app-a.env up -d
```

This works the same on a VM (for example AWS EC2) or a laptop. Size it like this:
- **CPU:** 2 vCPUs;
- **memory:** the template's RAM plus a few GB;
- **disk:** a few times the template's size.

## Fly.io

`deploy/fly/fly.toml` is one Fly app per monitored application, with a volume at `/data`.

There is no image to build or push beforehand. `fly deploy` sends this folder to Fly's remote builder,
which builds the `Dockerfile` there, so you need neither Docker nor a registry on your machine. Run every
command from the repository root, in a clone that has its submodule: the image copies crisium from
`machine-emulator/doc/recipes`.

```bash
git clone --recurse-submodules https://github.com/jplgarcia/crisium-sentinel.git
cd crisium-sentinel
```

Then, once per monitored application (`crisium-sentinel-myapp` is an example name):

```bash
fly apps create crisium-sentinel-myapp
fly volumes create sentinel_data --size 20 --region iad -a crisium-sentinel-myapp
fly secrets set -a crisium-sentinel-myapp RPC_URL=... APPLICATION=0x... TEMPLATE_URL=... \
    TEMPLATE_SHA256=... CRISIUM_ALERTS_WEBHOOK=...
fly deploy . --config deploy/fly/fly.toml --dockerfile Dockerfile -a crisium-sentinel-myapp
```

`-a` overrides the `app` name in `fly.toml`. The volume's region must match `primary_region` in that file
(`iad` there). `fly logs -a crisium-sentinel-myapp` follows crisium; the alerts also go to your webhook.

The sentinel serves no ports, so the Fly config has no services. Adjust the region and the VM size in
`fly.toml`. Not yet tested on Fly: only the Docker Compose path ran end to end (see "Tested").

## Other platforms

The image only needs:
- the environment variables above;
- a persistent volume at `/data`;
- outbound HTTPS (the RPC, the template URL, the webhook).

On AWS ECS, use an EFS volume or an EBS-backed EC2 task for `/data`, and pass the secrets from Secrets
Manager. Run one task per application and never two against the same volume.

## Layout

| Path | What |
|---|---|
| `Dockerfile` | Image: emulator release, Dave artifacts, crisium recipes, handler, entrypoint |
| `sentinel/entrypoint.sh` | Downloads the template, runs the preflight, starts crisium |
| `sentinel/preflight.lua` | Epoch-0 checkpoint and template check |
| `sentinel/healthcheck.sh` | Healthy while `status.json` keeps being rewritten |
| `compose.yaml`, `.env.example` | Docker Compose deployment |
| `deploy/fly/fly.toml` | Fly.io deployment |
| `machine-emulator/` | Submodule: crisium and its recipes, at the emulator release |
| `handler/` | The anomaly handler (`crisium_alerts.lua`) and its tests (`sh handler/test.sh`, needs `lua5.4`, `python3`, `curl`) |

## Tested

2026-11-26, on a local anvil devnet (1 s blocks), with:
- the Go node alpha.14 branch built for emulator 0.23;
- Dave `v3.0.0-alpha.8-test1` contracts and an honest sling;
- an echo application deployed with `--prt` and a 60-block staging period.

The sentinel got only `RPC_URL`, `APPLICATION` and a `TEMPLATE_URL` served over HTTP. Results:
- **Wrong checksum:** a wrong `TEMPLATE_SHA256` stopped the container (exit 1) before anything ran.
- **Start:** the preflight matched the template against `getTemplateHash()` and stored the epoch-0
  checkpoint. crisium started, and the healthcheck turned healthy about 20 s later.
- **Restart:** a restart at block 307 kept the template and the checkpoint ("already present") and
  resumed.
- **Settlement:** epochs 0 and 1 were settled by the sling and finished in crisium. The only anomaly was
  `delegate_call_voucher` (the app emits one), and the container stayed healthy until the end (block 1681).
