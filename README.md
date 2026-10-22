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
 │     ├ datagen-users     → test1                               │ ├VPCE─►│  Enterprise cluster           │
 │     ├ datagen-pageviews → test2 (Avro, CP SR)                 │ │(Priv-│   ├ test1, test2  (mirrors)   │
 │     └ s3-sink-users     test1 → S3 ──► S3 bucket (Pod Ident.) │ │ Link)│   ├ orders ◄─ managed Datagen │
 │   Kafka ── cluster link cp-to-cloud (source-initiated) ───────┼─┤      │   └ consumer groups           │
 │   Schema Registry (CP)                                        │ │      │     ccloud-demo-consumer      │
 │   ks-validate (Kafka Streams WordCount) + feeder              │ │      └───────────────────────────────┘
 │   persistent-consumer (SASL) on test1                         │ │
 │   Schema Registry ── schema exporter cp-to-cloud ─► CCloud SR ┼─┤
 │   ccloud-consumer ── reads test1 + orders from CCloud ────────┼─┤
 │   ccloud-avro-consumer ── decodes test2 via CCloud SR ────────┼─┘
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
| **CFK** (`k8s/cfk`) | KRaftController ×3, Kafka ×3 (`cp-server:8.3.0`), Connect ×2, Schema Registry, **USMAgent**, KafkaTopics |
| **Connectors** (`k8s/connectors`) | `Connector` CRs: Datagen *users* (JSON), Datagen *pageviews* (Avro), S3 sink |
| **Apps** (`k8s/apps`) | `ks-validate` stateful Kafka Streams app + feeder, SASL persistent consumer |
| **Flink** (optional, `k8s/flink`) | Flink operator + CMF (Helm), CFK `FlinkEnvironment`, `drop-gender` SQL statement |
| **USM registration** (`scripts/register-usm.sh`) | Registers the CP Kafka and Connect clusters through the USM REST API |
| **Hybrid** (`k8s/ccloud`, `scripts/deploy-ccloud.sh`) | CFK `KafkaRestClass`es, source-initiated `ClusterLink` pair mirroring `test1`/`test2` into CCloud, CFK-managed cloud topic `orders`, **Schema Linking** (`SchemaExporter` CP SR → CCloud SR), fully-managed **Datagen** connector → `orders`, `ccloud-consumer` + `ccloud-avro-consumer` on EKS |

## Prerequisites

- `terraform` ≥ 1.6, `aws` CLI v2, `kubectl`, `helm` v3+, `jq`, `envsubst` (gettext), `curl`
- AWS credentials with admin-level access to create VPC/EKS/IAM (e.g. `aws sso login`)
- A Confluent Cloud org with USM available, a payment method on file, and a
  **Cloud resource management API key** owned by an `OrganizationAdmin`

## Quick start

```bash
cp .env.example .env               # add CONFLUENT_CLOUD_API_KEY / _SECRET
make up                            # ~30 min end-to-end
make status
```

`make up` runs five steps you can also run individually:

| Step | Command | What it does |
|---|---|---|
| 1 | `make infra` | `terraform apply` + writes a dedicated kubeconfig to `./.kubeconfig` |
| 2 | `make cp` | Installs CFK, creates secrets from Terraform outputs, deploys CP + USM Agent |
| 3 | `make register` | Registers the CP Kafka cluster and Connect cluster with USM |
| 4 | `make workloads` | Deploys the connectors and the Kafka Streams / consumer apps |
| 5 | `make ccloud` | Cluster link + Schema Linking CP → CCloud, managed Datagen connector, cloud consumers |

Optional: `make flink` adds CMF + Flink and the `drop-gender` job (`test1` → `flink-test`).

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
2. **Topics** - `test1` … `streams-wordcount-output` with live throughput.
3. **Connectors** - `datagen-users`, `datagen-pageviews`, `s3-sink-users`
   running on the *self-managed* Connect cluster, with task status and throughput.
   Check the S3 bucket (`terraform -chdir=terraform output s3_sink_bucket`) for files.
4. **Consumer groups / lag** - `test1-persistent-consumer`, `connect-s3-sink-users`, `ks-validate`.
5. **Kafka Streams** - `ks-validate` with thread/state, RocksDB, e2e latency and
   processor metrics.
6. **Hybrid** - open the `usm-demo-cloud` Enterprise cluster in the same
   environment: `test1`/`test2` are **mirror topics** fed from the CP cluster by
   the `cp-to-cloud` cluster link, `orders` is produced by a fully-managed Datagen
   connector, and `ccloud-demo-consumer` (running on EKS) consumes both - one
   pane of glass for self-managed and cloud.
7. **Schema Linking** - in the environment's **Schema Registry**, `test2-value`
   shows up in IMPORT (read-only) mode with the **same schema ID** as in the CP
   Schema Registry, so the mirrored Avro `test2` messages render decoded in the
   Cloud message browser. `kubectl -n usm logs deploy/ccloud-avro-consumer`
   shows the same records decoded through the Cloud SR.

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
- **Only ship the CA you need to the link.** The link's TLS truststore is stored
  in the link config (max 32 KB), so a full CA bundle is rejected. CCloud chains
  to Let's Encrypt, so the script ships just the ISRG roots.
- **Terraform runs outside the VPC.** The provider normally checks a new Kafka
  API key against the cluster's REST endpoint, which is private-only here -
  hence `disable_wait_for_ready = true` - and cloud topics/links are managed by
  CFK from inside EKS instead of Terraform.
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

Deletes the managed connector and cluster link, deregisters the USM clusters,
deletes CP resources (so the EBS volumes are released), then runs `terraform destroy`
(which also removes the Enterprise cluster and the environment).

## Layout

```
terraform/         AWS (VPC, EKS, S3, PrivateLink, Route53) + Confluent Cloud (env, gateway, access point, SA, keys)
k8s/cfk/           CFK CRs: KRaft, Kafka, Schema Registry, Connect, USMAgent, topics
k8s/connectors/    CFK Connector CRs (Datagen x2, S3 sink)
k8s/apps/          Kafka Streams demo + SASL consumer
k8s/ccloud/        CCloud REST classes, cloud topic, source-initiated cluster link, schema exporter, cloud consumers
k8s/flink/         Optional CMF/Flink resources and the drop-gender SQL
scripts/           infra.sh, deploy-cp.sh, register-usm.sh, deploy-workloads.sh, deploy-ccloud.sh, flink.sh, status.sh, down.sh
```
