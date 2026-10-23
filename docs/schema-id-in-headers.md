# Schema IDs in Kafka headers across Cluster Linking + Schema Linking

Findings from testing Confluent's
[schema ID in Kafka headers](https://www.confluent.io/blog/schema-id-kafka-headers-data-governance/)
on this demo (CP 8.3 on EKS, source-initiated cluster link and Schema Linking
to a Confluent Cloud Enterprise cluster, both private over PrivateLink).

**Question:** the demo's Schema Linking uses IMPORT mode and `contextType: NONE`
so that the CP integer schema IDs embedded in mirrored records mean the same
thing in the Confluent Cloud Schema Registry. Is that still needed when the
schema ID travels in a record header instead?

**Short answer:** no. Header-encoded records only need the schema itself to
exist in the Cloud SR with an identical envelope. Neither the default context
(`NONE`) nor matching integer IDs are required. Both remain required for
records in the classic payload format.

## Two ways to carry the schema ID

### Classic: payload prefix ("magic byte")

```
value = 00 | 00 00 00 01 | <Avro binary>
        ^    ^^^^^^^^^^^
        |    schema ID (int32, big-endian), assigned by ONE registry
        magic byte (Confluent wire format v0)
```

The integer ID is local to the registry (and context) that assigned it. Cluster
Linking copies records byte for byte, so a mirrored record still says "ID 1",
and the destination registry must map ID 1 to the same schema. That is what the
exporter's IMPORT mode (register with the original ID) and `contextType: NONE`
(put it in the default context, where plain ID lookups look) provide.

### New: record header

```
header __value_schema_id = 01 | <16-byte schema GUID>
                           ^
                           header format version
value = <Avro binary>      (no prefix)
```

Enabled on the producer with
`value.schema.id.serializer=io.confluent.kafka.serializers.schema.id.HeaderSchemaIdSerializer`.
Requires CP 8.2+ (or Confluent Cloud) and Java clients 8.1.1+. Deserializers
look for the header first and fall back to the payload prefix, so both formats
can share a topic.

## Test setup

All tests ran on the live demo. Producers ran in the CP Schema Registry pod
(`kafka-avro-console-producer`, CP 8.3 clients); consumers in the
`ccloud-avro-consumer` pod against the Confluent Cloud mirror and the Cloud SR.

| Topic (1 partition, mirrored) | Records | Schema | How the schema reached the Cloud SR |
|---|---|---|---|
| `schema-header-test` | offsets 0-2 header, 3-4 classic | `ksql.pageviews` (CP ID 1) | already exported as `pageviews-value` (exporter `cp-to-cloud`, `contextType: NONE`) |
| `schema-header-ctx-test` | offsets 0-2 header | `demo.pageviews_ctx` (CP ID 2) | exporter `cp-to-cloud-ctx`, `contextType: AUTO` |
| `schema-header-manual-test` | offsets 0-1 header, 2 classic | `demo.pageviews_manual` (CP ID 3, Cloud ID 2) | registered by hand in the Cloud SR (READWRITE) |

The test topics and mirrors were added on the live system only (not in the repo
manifests). Re-running `make ccloud` removes the mirrors, and CFK then deletes
the cloud copies.

## Test 1: header records with a schema exported in the default context

**GUIDs are content-derived.** Registering the same `pageviews` schema under a
second subject (`schema-header-test-value`) returned the same ID and GUID:

```
pageviews-value           id=1 guid=8c03388a-de1a-e692-296c-bdd822c42c3f
schema-header-test-value  id=1 guid=8c03388a-de1a-e692-296c-bdd822c42c3f
```

The GUID is not a random (v4) UUID; it behaves as a hash of the schema envelope.

**The Cloud SR resolves the CP GUID:** `GET /schemas/guids/8c03388a-...` on the
Cloud SR returned the same schema.

**Wire format on CP** (headers and first value bytes):

| Offset | `__value_schema_id` | Value starts with |
|---|---|---|
| 0-2 | `01 8c03388ade1ae692296cbdd822c42c3f` | `02 16 55 73 65 72...` (plain Avro: viewtime=1, string length 11, "User...") |
| 3-4 | none | `00 00 00 00 01` (magic byte + ID 1) |

**Confluent Cloud** decoded all 5 records from the mirror: 0-2 via the header
GUID (they have no prefix, so no other path exists), 3-4 via integer ID 1.

## Test 2: header records with a schema only in a non-default context

A new schema (`demo.pageviews_ctx`, CP ID 2, GUID
`913f9ed8-3be1-f554-2fae-2e0d2a9bf996`) was exported with `contextType: AUTO`.

| Check (Cloud SR) | Result |
|---|---|
| Before export: `GET /schemas/guids/913f9ed8-...` | `40403 Schema ... not found` |
| After export: contexts | `.` and `.Yzg2YzRhNzktN2YxMi00ZA-id_schemaregistry_usm` |
| After export: subject | `:.Yzg2YzRhNzktN2YxMi00ZA-id_schemaregistry_usm:schema-header-ctx-test-value` |
| `GET /schemas/guids/913f9ed8-...` (no context given) | **resolves** |
| `GET /schemas/ids/2` (default context) | **`40403 schema not found`** |
| `GET /schemas/ids/2?subject=:.Yzg2...:schema-header-ctx-test-value` | resolves |

**GUID lookups span contexts; integer ID lookups don't.** All 3 header records
decoded in Confluent Cloud. A classic record with ID 2 would have failed.

## Test 3: schema registered by hand (no exporter)

A new schema (`demo.pageviews_manual`) was registered **independently** in both
registries: first by hand in the Cloud SR (`POST /subjects/.../versions`, global
mode READWRITE, no subject-level mode, default context, no exporter), then on CP
by producing with it.

| Registry | Subject | Integer ID | GUID |
|---|---|---|---|
| Confluent Cloud SR | `schema-header-manual-test-value` | **2** | `b4b67f15-9079-012e-46ef-5d7c44cd7318` |
| CP SR | `schema-header-manual-test-value` | **3** | `b4b67f15-9079-012e-46ef-5d7c44cd7318` |

**Same GUID, different integer IDs.** Each registry computed the GUID on its own,
which confirms it is derived from the schema content.

Topic `schema-header-manual-test` (mirrored) got 2 header records and then 1
classic record. Decoding the mirror in Confluent Cloud:

```
Offset:0  {"viewtime":1,"userid":"User_manual_header","pageid":"Page_1"}
Offset:1  {"viewtime":2,"userid":"User_manual_header","pageid":"Page_2"}
Offset:2  SerializationException: Error retrieving Avro value schema for id
          SchemaId{schemaType='AVRO', id=3, guid='null', ...}
          Caused by: RestClientException: schema not found; error code: 40403
```

- Header records decode without any exporter, IMPORT mode or ID alignment.
- The classic record fails: it says "ID 3", which doesn't exist in the Cloud SR.
- Worse case (not tested, but follows from the IDs above): the Cloud SR's
  default-context ID 2 is now `pageviews_manual`, while CP's ID 2 is
  `pageviews_ctx`. A classic record from CP with ID 2 would be decoded in
  Confluent Cloud with the **wrong schema** instead of failing. Integer IDs are
  only safe across registries when something (IMPORT mode) keeps them aligned.

## Conclusions

| | Classic prefix (int ID) | Header (GUID) |
|---|---|---|
| Schema must exist in the destination SR | yes | yes (exporter or registered by hand, Test 3) |
| Same integer ID on both sides (IMPORT) | **required** | not needed (Test 3) |
| Default context (`contextType: NONE`) | **required** | not needed (Test 2) |
| Identical schema envelope (schema, references, metadata, rules) | not required | **required**, any difference changes the GUID |
| Old consumers (< 8.1.1 / non-Confluent) | work | can't resolve the schema (they don't read the header) |

Recommendations:

- Keep Schema Linking for distributing schemas: it copies the envelope exactly,
  which is what GUID matching depends on, and IMPORT mode keeps the cloud copy
  read-only (one source of truth, no drift).
- While any topic still has classic-prefix records (existing data, mid-migration
  producers), keep IMPORT + `contextType: NONE`.
- Header IDs remove the cross-registry integer-ID coupling, which simplifies
  hybrid and multi-registry setups. Size cost: the header name plus 17 bytes per
  record instead of 5.

## In the demo: the `clickstream` pipeline

Based on these results, the demo has a separate header-ID pipeline. Header and
classic formats never share a topic or a subject: `users`/`pageviews` stay
classic, `clickstream` is header-only.

| Piece | Where | Detail |
|---|---|---|
| Topic | `k8s/cfk/50-topics.yaml` | `clickstream`, 3 partitions |
| Producer | `k8s/connectors/connectors.yaml` | `datagen-clickstream`, AvroConverter with `value.converter.value.schema.id.serializer: io.confluent.kafka.serializers.schema.id.HeaderSchemaIdSerializer` |
| Schema | CP SR | `clickstream-value` (auto-registered by the converter) |
| Schema Linking | `k8s/ccloud/41-schema-exporter-clickstream.yaml` | exporter `cp-to-cloud-clickstream`, `contextType: AUTO` (own context in the Cloud SR) |
| Mirror | `k8s/ccloud/10-link-destination.yaml` | `clickstream` on the `cp-to-cloud` link |
| Consumer | `k8s/ccloud/55-cloud-clickstream-consumer.yaml` | `ccloud-clickstream-consumer`, decodes via the header GUID |

Verified on the live demo: records carry `__value_schema_id = 01 68c84311...`
next to Datagen's own headers, values start directly with Avro, the Cloud SR
has `clickstream-value` only under `:.<context>:`, `GET /schemas/ids/4` in the
default context returns 404, and the cloud consumer decodes every record.

## Managing schemas with CI instead of Schema Linking

With header IDs, "drift" means the schema envelope differs between registries,
so the GUIDs differ and consumers on the other side can't resolve them. Integer
IDs are irrelevant. Registering the same schema in both registries from CI works
(Test 3), with these caveats:

1. **Producer auto-registration (the main risk).** With
   `auto.register.schemas=true` (the default; `datagen-clickstream` does this),
   the producer registers its own variant (the Connect AvroConverter, for
   example, adds `connect.name`), and records carry that GUID, which CI never
   registered on the other side. Set `auto.register.schemas=false` and
   `use.latest.version=true` on producers so they only use CI's schemas.
2. **Registry-side defaults.** `defaultMetadata`, `defaultRuleSet` or
   `overrideMetadata` configured in one registry change the envelope at
   registration time. Keep registry config identical (ideally CI-managed too).
3. **References.** Register referenced schemas identically, under the same
   names, in both registries and before the schemas that use them.
4. **Order and partial failure.** Register in the destination before the
   source, so mirrored records never arrive with an unknown GUID. Keep
   compatibility settings identical, and fail the CI run if either side fails.
5. **Out-of-band changes.** Restrict writes to the CI service account (RBAC) or
   set those subjects to `READONLY`.

Detect drift with a scheduled job comparing GUIDs per subject version: the CP SR
returns them from `/subjects/<s>/versions/<v>`, the Cloud SR from
`/schemas?subjectPrefix=<s>`.

In this demo the exporter copies whatever `datagen-clickstream` registered, so
the GUIDs always match; that changes once schemas are CI-managed.

## Commands

Endpoints in this environment (they change on every rebuild):
CP SR `http://localhost:18081` (port-forward), Cloud SR
`https://lsrc-<id>-<ap-id>.<region>.aws.accesspoint.glb.confluent.cloud`
(`terraform -chdir=terraform output -raw ccloud_schema_registry_url`), reachable
from a laptop after `make console`, or from any pod in EKS.

```bash
export KUBECONFIG=$PWD/.kubeconfig
kubectl -n usm port-forward svc/schemaregistry 18081:8081 &

CP_SR=http://localhost:18081
CLOUD_SR=$(terraform -chdir=terraform output -raw ccloud_schema_registry_url)
CLOUD_AUTH="$(terraform -chdir=terraform output -raw ccloud_sr_api_key):$(terraform -chdir=terraform output -raw ccloud_sr_api_secret)"

# GUID of a subject version. CP returns it on the version endpoint; the Cloud SR
# omits it there, but returns it from /schemas?subjectPrefix=...
curl -s $CP_SR/subjects/pageviews-value/versions/1 | jq '{subject, id, guid}'
curl -s -u "$CLOUD_AUTH" "$CLOUD_SR/schemas?subjectPrefix=pageviews-value" | jq '.[] | {subject, id, version, guid}'

# Resolve a GUID (context-free, works on both)
curl -s $CP_SR/schemas/guids/<guid> | jq .
curl -s -u "$CLOUD_AUTH" $CLOUD_SR/schemas/guids/<guid> | jq .

# Register by hand in the Cloud SR (Test 3)
curl -s -u "$CLOUD_AUTH" -X POST -H 'Content-Type: application/vnd.schemaregistry.v1+json' \
  $CLOUD_SR/subjects/<subject>/versions -d "$(jq -n --arg s "$SCHEMA" '{schema: $s}')"

# Contexts and subjects across all contexts
curl -s -u "$CLOUD_AUTH" $CLOUD_SR/contexts
curl -s -u "$CLOUD_AUTH" "$CLOUD_SR/subjects?subjectPrefix=:*:"
```

Produce header-encoded records (in the CP Schema Registry pod):

```bash
kubectl -n usm exec -it schemaregistry-0 -c schemaregistry -- bash
export LOG_DIR=/tmp
SCHEMA='{"type":"record","name":"pageviews","namespace":"ksql","fields":[{"name":"viewtime","type":"long"},{"name":"userid","type":"string"},{"name":"pageid","type":"string"}],"connect.name":"ksql.pageviews"}'
kafka-avro-console-producer --bootstrap-server kafka.usm.svc.cluster.local:9071 \
  --topic schema-header-test --property schema.registry.url=http://localhost:8081 \
  --property "value.schema=$SCHEMA" \
  --property value.schema.id.serializer=io.confluent.kafka.serializers.schema.id.HeaderSchemaIdSerializer
# then type: {"viewtime":1,"userid":"User_header","pageid":"Page_1"}
```

Decode the mirror in Confluent Cloud:

```bash
kubectl -n usm exec deploy/ccloud-avro-consumer -- bash -c 'LOG_DIR=/tmp kafka-avro-console-consumer \
  --bootstrap-server "$BOOTSTRAP" --command-config /tmp/client.properties \
  --topic schema-header-test --from-beginning --max-messages 5 --formatter-property print.offset=true \
  --formatter-property schema.registry.url="$SR_URL" \
  --formatter-property basic.auth.credentials.source=USER_INFO \
  --formatter-property basic.auth.user.info="$SR_API_KEY:$SR_API_SECRET"'
```

Inspect headers on CP:

```bash
kubectl -n usm exec kafka-0 -c kafka -- kafka-console-consumer --bootstrap-server localhost:9071 \
  --topic schema-header-test --from-beginning --max-messages 5 \
  --formatter-property print.headers=true --formatter-property print.value=false
```
