---
theme: default
title: Confluent USM Demo
info: CP 8.3 on EKS and Confluent Cloud, one pane of glass with Unified Stream Manager
colorSchema: dark
transition: slide-left
mdc: true
fonts:
  sans: Inter
  mono: JetBrains Mono
layout: cover
class: cover
---

<div class="eyebrow">Confluent Unified Stream Manager</div>

# One pane of glass<br/><span class="grad">for self-managed and cloud</span>

<div class="sub">
Confluent Platform 8.3 on EKS, managed from Confluent Cloud
</div>

<div class="chips">
  <span>CP 8.3 · KRaft</span><span>CFK 3.3</span><span>AWS EKS</span><span>PrivateLink</span><span>Cluster Linking</span><span>Schema Linking</span>
</div>

---
layout: center
class: text-center
---

# The problem

<div class="grid grid-cols-2 gap-10 mt-10 text-left">
<div v-click class="card">
  <div class="card-k">Self-managed</div>
  <h3>Confluent Platform</h3>
  <p>Brokers, Connect, Kafka Streams apps, each with its own tools and dashboards</p>
</div>
<div v-click class="card">
  <div class="card-k">Fully managed</div>
  <h3>Confluent Cloud</h3>
  <p>Clusters, connectors and governance in the Cloud Console</p>
</div>
</div>

<div v-click class="statement mt-12">
USM puts <span class="grad">both in the Cloud Console</span>, next to each other
</div>

---

# What's running

<div class="arch mt-6">
  <div class="zone eks" style="grid-column:1;grid-row:1/6"></div>
  <div class="zone cloud" style="grid-column:3;grid-row:1/6"></div>

  <div class="zlabel" style="grid-column:1;grid-row:1">AWS EKS · CP 8.3 on CFK</div>
  <div class="zlabel" style="grid-column:3;grid-row:1">Confluent Cloud · env usm-demo</div>

  <div class="box" style="grid-column:1;grid-row:2">USM Agent</div>
  <div class="box main" style="grid-column:1;grid-row:3">Kafka x3 · KRaft</div>
  <div class="box" style="grid-column:1;grid-row:4">Schema Registry</div>
  <div class="mini" style="grid-column:1;grid-row:5">
    <span>Connect x2</span><span>Connect on Cloud Kafka</span><span>Datagen x4</span><span>S3 sink</span><span>Kafka Streams</span>
  </div>

  <div v-click="1" class="wire" style="grid-column:2;grid-row:2"><span>telemetry · PrivateLink</span></div>
  <div v-click="2" class="wire" style="grid-column:2;grid-row:3"><span>cluster link (outbound)</span></div>
  <div v-click="3" class="wire" style="grid-column:2;grid-row:4"><span>Schema Linking</span></div>

  <div v-click="1" class="box cl" style="grid-column:3;grid-row:2">USM views</div>
  <div v-click="2" class="box cl main" style="grid-column:3;grid-row:3">Enterprise cluster · mirrors</div>
  <div v-click="3" class="box cl" style="grid-column:3;grid-row:4">Cloud Schema Registry</div>
  <div class="mini" style="grid-column:3;grid-row:5">
    <span>managed Datagen → orders</span><span>EKS Connect → stock-trades</span>
  </div>
</div>

<div class="foot">Everything private: nothing on EKS is reachable from the internet</div>

---

# What you'll see in Confluent Cloud

<div class="grid grid-cols-3 gap-5 mt-8">
<div v-click class="card">
  <div class="num">01</div>
  <h3>CP cluster</h3>
  <p>Shows up in the environment next to the cloud clusters, with broker, partition and throughput metrics</p>
</div>
<div v-click class="card">
  <div class="num">02</div>
  <h3>Topics</h3>
  <p><code>users</code>, <code>pageviews</code>, <code>clickstream</code> and the Streams topics, with live throughput</p>
</div>
<div v-click class="card">
  <div class="num">03</div>
  <h3>Connectors</h3>
  <p>Datagen + S3 sink on <em>self-managed</em> Connect, including a Connect cluster that runs on <b>Cloud Kafka</b></p>
</div>
<div v-click class="card">
  <div class="num">04</div>
  <h3>Consumer lag</h3>
  <p>S3 sink, Kafka Streams and a SASL consumer, each with its own consumer group</p>
</div>
<div v-click class="card">
  <div class="num">05</div>
  <h3>Kafka Streams</h3>
  <p>Thread state, RocksDB, end-to-end latency and processor metrics for <code>ks-validate</code></p>
</div>
<div v-click class="card accent">
  <div class="num">06</div>
  <h3>Mirror topics</h3>
  <p>On the Enterprise cluster, next to cloud-native <code>orders</code>, in the same environment</p>
</div>
</div>

---
layout: two-cols
layoutClass: gap-12
---

# Hybrid: CP → Cloud

<div class="mt-6 space-y-5">
<div v-click class="row"><span class="dot"></span><div><b>Cluster link</b>, started by CP: the brokers on EKS connect out, Cloud never connects in</div></div>
<div v-click class="row"><span class="dot"></span><div><code>users</code>, <code>pageviews</code>, <code>clickstream</code> become <b>mirror topics</b> on the Enterprise cluster</div></div>
<div v-click class="row"><span class="dot"></span><div><code>orders</code> comes from a <b>fully-managed</b> Datagen connector</div></div>
<div v-click class="row"><span class="dot"></span><div><code>ccloud-demo-consumer</code> on EKS reads both</div></div>
</div>

::right::

<div class="h-full flex flex-col justify-center gap-4 mt-8">
  <div class="pill cp">CP · users / pageviews / clickstream</div>
  <div class="arrow">↓ cluster link cp-to-cloud</div>
  <div class="pill cloud">Cloud · mirror topics</div>
  <div class="pill cloud ghost">Cloud · orders ← managed Datagen</div>
  <div class="arrow">↓</div>
  <div class="pill cp">EKS · ccloud-demo-consumer</div>
</div>

---

# Schema Linking: two ways to carry the schema ID

<div class="grid grid-cols-2 gap-8 mt-8">
<div class="card">
  <div class="card-k">pageviews · classic</div>
  <h3>ID in the payload</h3>

```text
00 | 00 00 00 01 | <avro>
     └ int ID, local to one registry
```

  <p>Exported with <code>contextType: NONE</code> in IMPORT mode, so the Cloud SR uses the <b>same integer ID</b></p>
</div>
<div v-click class="card accent">
  <div class="card-k">clickstream · new</div>
  <h3>GUID in a header</h3>

```text
header __value_schema_id = 01 | <GUID>
value  = <avro>
```

  <p>Exported into <b>its own context</b>, without a matching ID. The GUID still resolves</p>
</div>
</div>

<div v-click class="note">Both decode in the Cloud: <code>ccloud-avro-consumer</code> and <code>ccloud-clickstream-consumer</code></div>

---
layout: center
class: text-center
---

# Private by design

<div class="chain mt-10">
  <div class="node">USM Agent<br/><small>EKS</small></div>
  <div class="link">→</div>
  <div class="node">VPC endpoint<br/><small>AWS</small></div>
  <div class="link">→</div>
  <div class="node">PrivateLink gateway<br/><small>Confluent</small></div>
  <div class="link">→</div>
  <div class="node hl">Access point<br/><small>USM + Enterprise cluster</small></div>
</div>

<div class="mt-12 text-center opacity-80">
The Enterprise cluster is private-only. <code>make console</code> gives <em>your browser</em> a path in<br/>
through a TLS-passthrough proxy and <code>kubectl port-forward</code>. Nothing is exposed publicly.
</div>

---
layout: center
class: text-center
---

# All of it is code

<div class="term mt-8">
<div class="c"># ~30 min: Terraform → CFK → USM → workloads → cloud link</div>
<div><span class="p">$</span> make up</div>
<div><span class="p">$</span> make status</div>
<div class="c mt-3"># clean teardown</div>
<div><span class="p">$</span> make down</div>
</div>

<div class="chips mt-10 justify-center">
  <span>Terraform</span><span>CFK CRs</span><span>Shell scripts</span>
</div>

---
layout: center
class: text-center
---

# Let's look at it <span class="grad">live</span>

<div class="sub mt-4">Confluent Cloud → Environments → <code>usm-demo</code></div>

---

# Minimum versions for USM

<div class="req-wrap mt-6">
<table class="req">
  <thead>
    <tr><th>Feature</th><th>Confluent Server</th><th>Clients</th><th>Tooling</th></tr>
  </thead>
  <tbody>
    <tr>
      <td><b>Cluster registration</b></td>
      <td>7.9.6+ on 7.9.x, or <span class="v">8.1.0+</span></td>
      <td class="dim">none</td>
      <td class="dim">none</td>
    </tr>
    <tr>
      <td><b>Client monitoring</b><br/><small>KIP-714 push metrics</small></td>
      <td>7.9.6+ on 7.9.x, or <span class="v">8.1.2+</span></td>
      <td>Java <span class="v">3.7.2+</span><br/>librdkafka <span class="v">2.6+</span></td>
      <td class="dim">none</td>
    </tr>
    <tr class="hl">
      <td><b>Kafka Streams</b></td>
      <td>8.2.2+ on 8.2.x, or <span class="v">8.3.0+</span></td>
      <td>Streams lib on Kafka <span class="v">4.2.0+</span></td>
      <td>CFK <span class="v">3.3.0+</span><br/>Ansible <span class="v">8.2.2+</span></td>
    </tr>
  </tbody>
</table>
</div>

<div class="chips mt-8">
  <span>KRaft only</span><span>Private networking (PrivateLink)</span><span>Advanced Governance</span><span>AWS / Azure, no GCP</span>
</div>

<div class="foot">This demo: CP 8.3.0 on CFK 3.3, so every USM page lights up</div>
