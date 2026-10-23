# Confluent Unified Stream Manager (USM) Demo - CP 8.3 on CFK 3.3 / EKS

A self-contained demo that runs **Confluent Platform 8.3 (KRaft)** on **AWS EKS**
with **Confluent for Kubernetes (CFK) 3.3**, and surfaces it in **Confluent Cloud**
through **Unified Stream Manager (USM)**: brokers, topics, consumer groups,
connectors (running on CP Connect) and Kafka Streams apps all show up in the
Confluent Cloud UI - side by side with a **Confluent Cloud Enterprise cluster**
that CP mirrors data into over a **source-initiated cluster link**, with
**Schema Linking** keeping the Avro schemas (and their IDs) in sync - PrivateLink
only, nothing exposed publicly.

Everything is code: Terraform for AWS + Confluent Cloud, CFK custom resources
for the platform, and a few shell scripts to glue them together.

```
                         AWS VPC                                               Confluent Cloud
 ┌──────────────────────────────────────────────────────────────┐        ┌───────────────────────────────┐
 │ EKS                                                           │        │ Environment usm-demo          │
 │  ns confluent: CFK operator                                   │        │ (Advanced governance)         │
 │  ns usm:                                                      │        │                               │
 │   KRaftController x3 ─┐                                       │        │  USM: CP Kafka / CP Connect   │
 │   Kafka x3 ───────────┼─ telemetry/metadata ─► USM Agent ─────┼─┐      │  Kafka Streams view           │
 │   Connect x2 ─────────┘                                       │ │      │                               │
 │     ├ datagen-users     → users                               │ ├VPCE─►│  Enterprise cluster           │
 │     ├ datagen-pageviews → pageviews (Avro, CP SR)             │ │(Priv-│   ├ users, pageviews,         │
 │     ├ datagen-clickstream → clickstream (Avro, GUID hdr)      │ │ Link)│   │ clickstream (mirrors)     │
 │     └ s3-sink-users     users → S3 ──► S3 bucket (Pod Ident.) │ │      │   ├ orders ◄─ managed Datagen │
 │   Kafka ── cluster link cp-to-cloud (source-initiated) ───────┼─┤      │   └ consumer groups           │
 │   Schema Registry (CP)                                        │ │      │     ccloud-demo-consumer      │
 │   ks-validate (Kafka Streams WordCount) + feeder              │ │      └───────────────────────────────┘
 │   persistent-consumer (SASL) on users                         │ │
 │   Schema Registry ── schema exporters ────────────► CCloud SR ┼─┤
 │   ccloud-consumer ── reads users + orders from CCloud ────────┼─┤
 │   ccloud-avro-consumer ── decodes pageviews via CCloud SR ────┼─┤
 │   ccloud-clickstream-consumer ── clickstream via GUID ────────┼─┘
 │  ns flink (optional): CMF + Flink, drop-gender SQL job        │
 └──────────────────────────────────────────────────────────────┘
```

## What gets created

| Layer | Resources |
|---|---|
| **AWS** (Terraform) | VPC (3 AZ, single NAT), EKS 1.35 + managed node group (4× m5.xlarge), EBS CSI + Pod Identity, S3 bucket + IAM role for the S3 sink connector |
| **PrivateLink** (Terraform) | CCloud ingress PrivateLink **gateway** → AWS interface **VPC endpoint** → CCloud **access point** → Route53 private zone `*.<access-point-domain>` |
| **Confluent Cloud** (Terraform) | Environment with **Advanced** Stream Governance, USM service account with `UsmAgent` + `DataSteward` roles, Cloud resource management API key for the agent |
| **CCloud cluster** (Terraform) | **Enterprise** Kafka cluster (private, behind the same access point), `cloud-app` service account + Kafka and Schema Registry API keys (`DataSteward` for Schema Linking) |
| **CFK** (`k8s/cfk`) | KRaftController ×3, Kafka ×3 (`cp-server:8.3.0`), Connect ×2, Schema Registry, **USMAgent**, KafkaTopics, **Control Center** (next-gen 2.6, with its Prometheus + Alertmanager) |
| **Connectors** (`k8s/connectors`) | `Connector` CRs: Datagen *users* (JSON), Datagen *pageviews* (Avro), Datagen *clickstream* (Avro, schema ID in record headers), S3 sink |
| **Apps** (`k8s/apps`) | `ks-validate` stateful Kafka Streams app + feeder, SASL persistent consumer |
| **Flink** (optional, `k8s/flink`) | Flink operator + CMF (Helm), CFK `FlinkEnvironment`, `drop-gender` SQL statement |
| **USM registration** (`scripts/register-usm.sh`) | Registers the CP Kafka and Connect clusters through the USM REST API |
| **Hybrid** (`k8s/ccloud`, `scripts/deploy-ccloud.sh`) | CFK `KafkaRestClass`es, source-initiated `ClusterLink` pair mirroring `users`/`pageviews`/`clickstream` into CCloud, CFK-managed cloud topic `orders`, **Schema Linking** (`SchemaExporter`s CP SR → CCloud SR: `pageviews-value` classic, `clickstream-value` in its own context), fully-managed **Datagen** connector → `orders`, `ccloud-consumer` + `ccloud-avro-consumer` + `ccloud-clickstream-consumer` on EKS |

## Prerequisites

- `terraform` ≥ 1.6, `aws` CLI v2, `kubectl`, `helm` v3+, `jq`, `envsubst` (gettext), `curl`
- AWS credentials with admin-level access to create VPC/EKS/IAM (e.g. `aws sso login`)
- A Confluent Cloud org with USM available, a payment method on file, and a
  **Cloud resource management API key** owned by an `OrganizationAdmin`

## Quick start

```bash
cp .env.example .env               # add CONFLUENT_CLOUD_API_KEY / _SECRET
make up                            # ~30 min end-to-end, asks for sudo once at the end (for /etc/hosts update)
                                   # Control Center: http://localhost:9021
make status
```

`make up` runs seven steps you can also run individually:

| Step | Command | What it does |
|---|---|---|
| 1 | `make infra` | `terraform apply` + writes a dedicated kubeconfig to `./.kubeconfig` |
| 2 | `make cp` | Installs CFK, creates secrets from Terraform outputs, deploys CP + USM Agent + Control Center |
| 3 | `make register` | Registers the CP Kafka cluster and Connect cluster with USM |
| 4 | `make workloads` | Deploys the connectors and the Kafka Streams / consumer apps |
| 5 | `make ccloud` | Cluster link + Schema Linking CP → CCloud, managed Datagen connector, cloud consumers, Console proxy |
| 6 | `make c3` | Control Center for the CP cluster on `http://localhost:9021` (background port-forward; `make c3-stop`) |
| 7 | `make console` | Lets the Cloud Console in your browser reach the private cluster (see [Browsing the private cluster](#browsing-the-private-cluster-in-the-cloud-console)) - the only step that asks for sudo, so it runs last |

Optional: `make flink` adds CMF + Flink and the `drop-gender` job (`users` → `users-redacted`).

To use kubectl against the demo cluster: `export KUBECONFIG=$PWD/.kubeconfig`.

### Configuration

Override defaults with `terraform/terraform.tfvars` (see `terraform.tfvars.example`)
or `.env`:

| Variable | Default | |
|---|---|---|
| `DEMO_REGION` / `region` | `us-east-1` | AWS region; CCloud gateway + USM metadata region follow it |
| `DEMO_NAME` / `name` | `usm-demo` | Prefix for EKS cluster, CCloud environment, etc. |
| `node_instance_type`, `node_count` | `m5.xlarge`, `4` | Size for the full footprint incl. Flink |
| `tags` | `{}` | Extra AWS tags (e.g. your org's mandatory owner/cost tags). Applied to every resource, including EKS nodes and the EBS volumes behind Kafka PVCs |

## Demo walkthrough

1. **Confluent Cloud → Environments → `usm-demo`** - the CP cluster appears next
   to cloud clusters, with broker/partition/throughput metrics.
2. **Topics** - `users` … `streams-wordcount-output` with live throughput.
3. **Connectors** - `datagen-users`, `datagen-pageviews`, `datagen-clickstream`, `s3-sink-users`
   running on the *self-managed* Connect cluster, with task status and throughput.
   Check the S3 bucket (`terraform -chdir=terraform output s3_sink_bucket`) for files.
4. **Consumer groups / lag** - `users-persistent-consumer`, `connect-s3-sink-users`, `ks-validate`.
5. **Kafka Streams** - `ks-validate` with thread/state, RocksDB, e2e latency and
   processor metrics.
6. **Hybrid** - open the `usm-demo-cloud` Enterprise cluster in the same
   environment: `users`/`pageviews`/`clickstream` are **mirror topics** fed from the CP cluster by
   the `cp-to-cloud` cluster link, `orders` is produced by a fully-managed Datagen
   connector, and `ccloud-demo-consumer` (running on EKS) consumes both - one
   pane of glass for self-managed and cloud.
7. **Schema Linking** - in the environment's **Schema Registry**, `pageviews-value`
   shows up in IMPORT (read-only) mode with the **same schema ID** as in the CP
   Schema Registry, so the mirrored Avro `pageviews` messages decode with the Cloud SR
   (`kubectl -n usm logs deploy/ccloud-avro-consumer`).
8. **Schema IDs in headers** - `clickstream` is a separate pipeline whose records
   carry the schema GUID in the `__value_schema_id` header (no payload prefix).
   Its schema is exported with `contextType: AUTO`, so in the Cloud SR it sits in
   its own context and has no matching integer ID, yet
   `kubectl -n usm logs deploy/ccloud-clickstream-consumer` decodes it: the GUID
   resolves across contexts and registries. Background and tests:
   [docs/schema-id-in-headers.md](docs/schema-id-in-headers.md).

> The Enterprise cluster is private-only. Without `make console` the Cloud
> Console can't reach its endpoints: mirror topics show as plain topics (no
> link icon) and the message browser doesn't load. See below.

## Browsing the private cluster in the Cloud Console

The Console loads part of each page (mirror/link state, messages, schemas)
straight from the cluster's private REST endpoint, so your browser needs a path
into the VPC. `make console` builds one without exposing anything publicly:

```
browser ─► /etc/hosts: lkc-…/lsrc-… → 127.0.0.1
        ─► pf: 127.0.0.1:443 → 127.0.0.1:18443
        ─► kubectl port-forward ─► console-proxy pod (ns usm)
        ─► NGINX ssl_preread: SNI host, resolved via the VPC's Route53 private zone
        ─► PrivateLink ─► Enterprise cluster / Schema Registry
```

- `console-proxy` (`k8s/ccloud/60-console-proxy.yaml`, deployed by `make ccloud`)
  passes TLS through untouched: no certificates, Confluent's TLS ends in your
  browser. It only forwards to `*.aws.accesspoint.glb.confluent.cloud` and has
  no Service, so it's reachable only via `kubectl port-forward`.
- The port-forward runs in the background (restarted if it drops), pid/log in
  `.console-proxy.pid` / `.console-proxy.log`.
- macOS won't let a normal user bind 443, and kubectl can't run under `sudo`
  (EKS credentials are in your SSO session), so `scripts/console-proxy-local.sh`
  adds a pf redirect 443 → 18443 plus the two `/etc/hosts` entries. It runs with
  `sudo` only when the private endpoint isn't already reachable.
- `make console` is idempotent: re-run it after a reboot (pf rules don't
  survive) or when your AWS SSO session was renewed.
- `make console-stop` stops the forward and removes the hosts entries and pf
  rule; `make down` does the same.

## Consuming the topics

Everything is private, so consume from pods inside EKS
(`export KUBECONFIG=$PWD/.kubeconfig` first).

```bash
# CP: users (JSON users) - any topic works via the internal listener
kubectl -n usm exec kafka-0 -c kafka -- \
  kafka-console-consumer --bootstrap-server localhost:9071 --topic users --max-messages 5

# CP: pageviews (Avro pageviews) decoded with the CP Schema Registry
kubectl -n usm exec schemaregistry-0 -c schemaregistry -- \
  kafka-avro-console-consumer --bootstrap-server kafka.usm.svc.cluster.local:9071 \
  --topic pageviews --max-messages 5 --formatter-property schema.registry.url=http://localhost:8081

# Confluent Cloud: orders (managed Datagen) or the users mirror
kubectl -n usm exec deploy/ccloud-consumer -- bash -c \
  'kafka-console-consumer --bootstrap-server "$BOOTSTRAP" --command-config /tmp/client.properties \
   --topic orders --from-beginning --max-messages 5'

# Confluent Cloud: pageviews mirror decoded with the Cloud Schema Registry (Schema Linking)
kubectl -n usm exec deploy/ccloud-avro-consumer -- bash -c \
  'kafka-avro-console-consumer --bootstrap-server "$BOOTSTRAP" --command-config /tmp/client.properties \
   --topic pageviews --max-messages 5 \
   --formatter-property schema.registry.url="$SR_URL" \
   --formatter-property basic.auth.credentials.source=USER_INFO \
   --formatter-property basic.auth.user.info="$SR_API_KEY:$SR_API_SECRET"'
```

The cloud pods already hold the credentials (`ccloud-client` secret) and a
`/tmp/client.properties`, so you can reuse them for any other cloud topic.
Leave off `--group` for ad-hoc reads so you don't disturb the demo consumer groups.

## How USM is wired (and why)

- **PrivateLink is mandatory.** The USM Agent only talks to Confluent Cloud over
  a private connection. Terraform builds the full chain and computes the agent's
  front-door URL: `https://api-<ap-id>.<region>.aws.accesspoint.glb.confluent.cloud:443`.
- **Telemetry is CFK-native.** `dependencies.usmAgentClient.clientMetricsEnabled: true`
  on Kafka/KRaft makes CFK configure the telemetry exporter and the
  KIP-714/KIP-1076 client-metrics subscription (including `org.apache.kafka.stream.*`).
  No broker `configOverrides` and no client-side config needed.
- **CP 8.3 brokers are needed for the Kafka Streams page.** 8.2.x skips the
  String gauges (`stream.state`, `thread.state`, `application.id`).
- **Kafka Streams details** need `metrics.recording.level=DEBUG` and a *stateful*
  topology (RocksDB) - `ks-validate` uses `count()` on purpose, and runs on a
  `cp-kafka` image (RocksDB needs `libstdc++`, which `apache/kafka` images lack).
- **Connect metrics workaround.** CP Connect 8.1.2-8.3.0 doesn't emit all
  metrics USM needs; `k8s/cfk/30-connect.yaml` sets the documented
  `confluent.telemetry.exporter._usm.metrics.include` override.
- **No authorizer.** The source runbook used the `simple` authorizer with
  `allow.everyone.if.no.acl.found=true`, which also required `User:ANONYMOUS` as
  a super user so KRaft controllers could re-form quorum after a cold restart.
  Since that grants nothing, this demo leaves authorization off. If you add an
  authorizer, include `User:ANONYMOUS` in `superUsers` on Kafka **and** KRaft.
- **Register Connect before creating connectors.** USM learns about a connector
  from the metadata event emitted when it is created; connectors created earlier
  are rejected with `USM resource not found (Connector)`. That's why `make workloads`
  runs after `make register` (fix for an existing setup: delete and re-apply the
  `Connector` CRs).
- **Don't name the CCloud credential secret `<agent-name>-ccloud-credential`.**
  CFK generates a secret with exactly that name for the agent's Envoy config and
  will overwrite yours (the CR then fails with `required key [basic.txt] missing`).
  This repo uses `ccloud-usm-agent-credential`.
- **Cloud cluster over the same PrivateLink.** Enterprise clusters are
  private-only and are reachable through the environment's ingress PrivateLink
  access point - the one Terraform already built for USM. Its endpoint for our
  access point is `lkc-<id>-<ap-id>.<region>.aws.accesspoint.glb.confluent.cloud`.
- **Source-initiated cluster link.** CCloud can't reach CP on EKS, so the CP
  brokers dial out: a `Destination`-mode `ClusterLink` CR (created first,
  declares the mirror topics) plus a `Source`-mode CR carrying the CCloud
  credentials, which the Kafka CR's `passwordEncoder` encrypts.
- **Schema Linking with `contextType: NONE`.** Mirrored records carry the CP
  schema ID in their header bytes, so the schema must exist in the Cloud SR's
  *default* context under the *same* ID. `NONE` exports subjects as-is (the
  default `AUTO` would put them in a `.lsrc-…` context instead), and the exporter
  sets them to IMPORT mode so the IDs are preserved. The CP SR needs
  `enableSchemaExporter: true` plus a `passwordEncoder` for the stored credentials.
  With schema IDs in record headers (GUIDs) instead of the payload prefix,
  neither `NONE` nor matching IDs are needed: see
  [docs/schema-id-in-headers.md](docs/schema-id-in-headers.md).
- **Only ship the CA you need to the link.** The link's TLS truststore is stored
  in the link config (max 32 KB), so a full CA bundle is rejected. CCloud chains
  to Let's Encrypt, so the script ships just the ISRG roots.
- **Terraform runs outside the VPC.** The provider normally checks a new Kafka
  API key against the cluster's REST endpoint, which is private-only here -
  hence `disable_wait_for_ready = true` - and cloud topics/links are managed by
  CFK from inside EKS instead of Terraform.
- **Control Center next to USM.** C3 next-gen (2.x) ships its own Prometheus
  and Alertmanager; `dependencies.metricsClient` on Kafka and KRaft makes CFK
  add a second telemetry exporter (`_c3`, OTLP to C3's Prometheus on 9090) next
  to the USM one (`_usm`), so both get broker metrics. Adding it to a running
  cluster rolls the controllers and brokers. Without a license C3 runs as a
  30-day trial.
- **Registration via REST.** `confluent usm kafka|connect register` needs an
  interactive login; the script calls the same `/usm/v1` API with the Cloud API key.

## Security notes

- No credentials live in the repo. `.env`, `*.tfvars`, Terraform state and the
  generated `.kubeconfig` are git-ignored.
- SASL passwords are generated by Terraform (`random_password`) and pushed into
  Kubernetes secrets by `scripts/deploy-cp.sh`.
- Connect gets S3 access through **EKS Pod Identity** - no AWS keys.
- The `cloud-app` service account is `CloudClusterAdmin` on the Enterprise
  cluster to keep the demo short - scope it down for anything real.
- Terraform state is local and **contains secrets** (API keys, passwords). For
  anything beyond a personal demo use a remote, encrypted backend.
- The internal listener (9071) is PLAINTEXT and unauthenticated inside the
  cluster - fine for a demo, not for production.
- `make console` edits `/etc/hosts` and loads a pf rule on your laptop (both
  tagged/removed by `make console-stop`). The in-cluster proxy has no Service and
  only forwards to Confluent access-point hostnames.

## Troubleshooting

- **`VpcLimitExceeded`** - the demo creates its own VPC. Pick a region with
  headroom (`region = "eu-west-1"` in `terraform.tfvars`) or raise the quota.
  If a run fails part-way, `terraform destroy` *with the same region* before
  switching regions, or you'll orphan resources.

```bash
export KUBECONFIG=$PWD/.kubeconfig
kubectl -n usm get kafka,kraftcontroller,connect,schemaregistry,usmagent,connector
kubectl -n usm logs usm-agent-0                       # agent → CCloud connectivity
kubectl confluent cluster usmagent usm-agent-validz   # needs the CFK kubectl plugin
```

- **Agent can't reach Confluent Cloud** - check DNS from inside the cluster:
  `kubectl run -it --rm dns --image=busybox -- nslookup <front-door host>`. It should
  resolve to private IPs in the VPC (Route53 private zone → VPC endpoint).
- **Mirror topics without the link icon / message browser won't load** - the
  browser can't reach the private cluster. Run `make console` and hard-refresh.
  If it reports the endpoint unreachable, check `.console-proxy.log` (expired
  AWS SSO session is the usual cause).
- **Cluster link `ERROR`** - `kubectl -n usm get clusterlink cp-to-cloud-source -o yaml`
  shows the Admin REST error. Delete the source CR and re-run `make ccloud`.
- **Pods stuck `Terminating` after a node loss** - `kubectl delete pod --force --grace-period=0`,
  then `kubectl delete node`; the managed node group replaces the instance.
- **Don't run two full CP clusters on this node group** - memory overcommit can
  kill a node and take KRaft quorum with it.

## Teardown

```bash
make down
```

Stops `make console` (asks for sudo to clean `/etc/hosts`/pf if set up), deletes
the managed connector and cluster link, deregisters the USM clusters,
deletes CP resources (so the EBS volumes are released), then runs `terraform destroy`
(which also removes the Enterprise cluster and the environment).

## Layout

```
terraform/         AWS (VPC, EKS, S3, PrivateLink, Route53) + Confluent Cloud (env, gateway, access point, SA, keys)
k8s/cfk/           CFK CRs: KRaft, Kafka, Schema Registry, Connect, USMAgent, topics, Control Center
k8s/connectors/    CFK Connector CRs (Datagen x2, S3 sink)
k8s/apps/          Kafka Streams demo + SASL consumer
k8s/ccloud/        CCloud REST classes, cloud topic, source-initiated cluster link, schema exporters, cloud consumers, console proxy
k8s/flink/         Optional CMF/Flink resources and the drop-gender SQL
docs/              Write-ups (schema IDs in Kafka headers across Cluster/Schema Linking)
scripts/           infra.sh, deploy-cp.sh, register-usm.sh, deploy-workloads.sh, deploy-ccloud.sh, console.sh (+ console-proxy-local.sh), c3.sh, flink.sh, status.sh, down.sh
```
