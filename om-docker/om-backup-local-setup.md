

# OM BACKUP LOCAL SETUP

# Common

Update /etc/hosts

```shell
127.0.0.1       host.docker.internal
127.0.0.1       ops.om.internal
127.0.0.1       node1.om.internal
```

# Topology

![][image1]

# Meta OM

## Docker OM

[https://github.com/prakhardhama/mongo-infra-docker/blob/prakhar.dhama/om-backup-local/README.md](https://github.com/prakhardhama/mongo-infra-docker/blob/prakhar.dhama/om-backup-local/README.md)

```shell
$ cd mongo-infra-docker
$ git checkout prakhar.dhama/om-backup-local
$ cd ops-manager

$ bash quick-start.sh
```

Wait for “Press any key to attempt Agent setup in the script”

Sign Up User at [http://ops.om.internal:8080/](http://ops.om.internal:8080/)

## Docker Agents

In Docker OM; Go to Deployment \> Agents \> Downloads & Settings \> Other Linux

```textproto
mmsGroupId=699fcfb392b0f2400ea0077c
mmsApiKey=699fcfe992b0f2400ea008460ffcc57fc28921f13dd8bceea7da68d0
mmsBaseUrl=http://ops.om.internal:8080
```

Update file in mongo-infra-docker at ops-manager/mongodb-mms/automation-agent.config

Press any key to continue complete Agent setup.  
Servers \> … \> Enable Monitoring \> Confirm & Deploy

* Monitoring should turn green

## Docker OM Backup

Admin \> Backup \> Head Directory \> Enable Daemon

Configure S3 Blockstore

* S3 Bucket Name: Same as configured in AWS (eg. meta-ops-manager-backup-bucket)
* S3 Enpoint: As configured (eg. [s3.eu-north-1.amazonaws.com](http://s3.eu-north-1.amazonaws.com))
* AWS Keys: Access Credentials
* Hostname:port: localhost:27017

Servers \> … \> Enable Backup \> Confirm & Deploy

* Backup should turn green

# Primary OM

## Local OM

[https://github.com/10gen/ops-manager/tree/prakhar.dhama/om-backup-local](https://github.com/10gen/ops-manager/tree/prakhar.dhama/om-backup-local)

**Setup AppDB for Primary OM**

Start the AppDB for the Local OM using MongoDB Enterprise 7.0 as a replica set with proper logging configuration.

**Important**: MongoDB must be started with a config file that includes `logPath` for Automation to work.

```shell
# Pull MongoDB Enterprise Server 7.0
$ docker pull mongodb/mongodb-enterprise-server:7.0-ubi8

# Create a temporary container to set up the config file
$ docker run -d \
  --name mongodb-ops-manager-temp \
  -v primary-om-appdb:/data/db \
  mongodb/mongodb-enterprise-server:7.0-ubi8 \
  --replSet appdb-rs --bind_ip_all

# Create the MongoDB configuration file with logPath
$ docker exec -u root mongodb-ops-manager-temp bash -c 'cat > /etc/mongodb/mongod.conf << "EOF"
# mongod.conf - MongoDB configuration file

# Where to store data
storage:
  dbPath: /data/db

# Where to write logging data
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

# Network interfaces
net:
  port: 27017
  bindIp: 0.0.0.0

# Replication
replication:
  replSetName: appdb-rs
EOF'

# Create log directory
$ docker exec -u root mongodb-ops-manager-temp mkdir -p /var/log/mongodb
$ docker exec -u root mongodb-ops-manager-temp chown -R mongod:mongod /var/log/mongodb

# Stop and remove the temporary container
$ docker stop mongodb-ops-manager-temp
$ docker rm mongodb-ops-manager-temp

# Create the final MongoDB container with config file
$ docker run -d \
  --name mongodb-ops-manager \
  -p 27018:27017 \
  -v primary-om-appdb:/data/db \
  mongodb/mongodb-enterprise-server:7.0-ubi8 \
  --config /etc/mongodb/mongod.conf

# Verify MongoDB is running with config file
$ docker exec mongodb-ops-manager ps aux | grep "mongod --config"
# Should show: mongod --config /etc/mongodb/mongod.conf
```

**Connect AppDB to Meta OM Network**

Connect the Primary OM's AppDB to the Meta OM's Docker network so Meta OM can back it up

```shell
# Inspect the Meta OM container to see what networks it's on
$ docker inspect ops --format '{{range $key, $value := .NetworkSettings.Networks}}{{$key}} {{end}}'# Connect to the ops-manager_main network
$ docker network connect ops-manager_main mongodb-ops-manager

# Verify the connection and get the IP address
$ docker inspect mongodb-ops-manager --format '{{json .NetworkSettings.Networks}}' | jq -r '.["ops-manager_main"].IPAddress'
# Should output: 172.18.0.2
```

I**nitialize Replica Set**

Initialize the replica set with \`host.docker.internal:27018\` so it's accessible from both local and Docker environments

```shell
# Initialize the Replica Set
$ docker exec mongodb-ops-manager mongosh --eval "
rs.initiate({
  _id: 'appdb-rs',
  members: [{ _id: 0, host: 'host.docker.internal:27018' }]
})
"

# Verify replica set status
$ docker exec mongodb-ops-manager mongosh --quiet --eval "rs.status().members.map(m => ({name: m.name, state: m.stateStr}))"
# Should show: [ { name: 'host.docker.internal:27018', state: 'PRIMARY' } ]
```

**Configure Primary OM**

In ops-manager, update server/conf/conf-hosted.properties

```textproto
mongo.mongoUri=mongodb://host.docker.internal:27018/?replicaSet=appdb-rs&directConnection=true&maxPoolSize=150&retryWrites=false&retryReads=false&uuidRepresentation=standard
mms.centralUrl=http://localhost:8081
```

**Note**: The \`*directConnection=true*\` parameter allows Primary OM to connect directly without caring about the replica set member hostname mismatch.

**Start Primary OM**

Navigate to the ops-manager directory and run the bazel command to start the local ops manager on the 8081 port

```shell
$ cd ~/ops-manager
$ bazel run --server_env=hosted //server:mms
```

Wait for migrations to complete and server to start (this may take 2-3 minutes). The server is ready when you see it listening on port 8081:

```shell
# Verify server is running
$ lsof -i :8081 | grep LISTEN
# Should show java process listening on port 8081

# Test server is responding
$ curl -I http://localhost:8081
# Should return HTTP 303 redirect
```

Access Primary OM at [http://localhost:8081](http://localhost:8081)

```textproto
"From" Email Address:        noreply@localhost
"Reply To" Email Address:    noreply@localhost
Admin Email Address:         admin@localhost
SMTP Server Hostname:        localhost
SMTP Server Port:            25

Versions Directory *
A local path on every Ops Manager server to store MongoDB binaries that are downloaded. The binaries will be placed there by an Ops Manager admin (when in Local mode) or downloaded automatically.		/Users/prakhar.dhama/local/mongodb-versions
```

## Local Agents

[https://github.com/10gen/mms-automation/tree/prakhar.dhama/om-backup-local](https://github.com/10gen/mms-automation/tree/prakhar.dhama/om-backup-local)

In Docker OM; Go to Deployment \> Agents \> Downloads & Settings \> Other Linux

Update file in mms-automation at go\_planner/src/com.tengen/cm/main/local.config

```textproto
mmsGroupId=69a6cf779238830ac9788d1d
mmsApiKey=69a6d0049238830ac9788df1ecbf4fc07a6a3f665fdb773035e85a17
mmsBaseUrl=http://localhost:8081
```

```shell
# Update log permissions
$ sudo mkdir -p /var/log/mongodb-mms-automation
$ sudo chown $(whoami):staff /var/log/mongodb-mms-automation
$ sudo chmod 777 /var/log/mongodb-mms-automation

# Fix permissions
$ sudo mkdir -p /var/lib/mongodb-mms-automation
$ sudo chown $(whoami):staff /var/lib/mongodb-mms-automation
$ sudo chmod 777 /var/lib/mongodb-mms-automation

```

Update log paths under Agents \> Downloads & Settings

```textproto
Agent Log Settings
Monitoring Log Settings
Linux Log File Path: /var/log/mongodb-mms-automation/primary-monitoring-agent.log

Backup Log Settings
Linux Log File Path: /var/log/mongodb-mms-automation/primary-backup-agent.log
```

Start the automation agent locally using the below command

```shell
$ cd go_planner/src/com.tengen/cm/main
$ go run cm.go --config=local.config

# Find the process
ps aux | grep "go run cm.go" | grep -v grep
```

## Local ReplicaSet Deployment

Use MongoDB 7.0.14-ent. MongoDB 7.0 is stable and well-tested on Apple Silicon.

```shell
mkdir -p /Users/prakhar.dhama/om/mongodb-data/poRepRs_27031
mkdir -p /Users/prakhar.dhama/om/mongodb-data/poRepRs_27032
mkdir -p /Users/prakhar.dhama/om/mongodb-data/poRepRs_27033
chmod -R 777 /Users/prakhar.dhama/om
```

## Local OM Backup

Navigate to the ops-manager repo directory and start the backup daemon using the below command in a separate terminal

```shell
$ bazel run //server:daemon -- \
  --jvm_flag=-DDAEMON.ROOT.DIRECTORY=$HOME/data/backups/daemon/
```

After the backup daemon is running, we would get an option to **Enable the Daemon** in the Admin \-\> Backup page

* S3 Bucket Name: Same as configured in AWS (eg. primary-ops-manager-backup-bucket)
* S3 Enpoint: As configured (eg. [s3.eu-north-1.amazonaws.com](http://s3.eu-north-1.amazonaws.com))
* AWS Keys: Access Credentials
* Hostname:port: localhost:27018

# Manage Primary OM AppDB by Meta OM

## Prerequisites

The Primary OM's AppDB needs to be accessible from both:

- **Local machine** (for Primary OM running via Bazel)
- **Docker network** (for Meta OM's monitoring agents)

## Step 1: Connect Primary AppDB to Meta OM Network

Ensure the Primary OM's AppDB container is connected to the same Docker network as Meta OM:

```shell
# Verify Primary AppDB is on the ops-manager_main network
$ docker inspect mongodb-ops-manager --format '{{json .NetworkSettings.Networks}}' | jq -r '.["ops-manager_main"].IPAddress'
# Should output: 172.18.0.2
```

If not connected, run:

```shell
$ docker network connect ops-manager_main mongodb-ops-manager
```

## Step 2: Configure Docker Compose for Host Resolution

Update `ops-manager/docker-compose.yml` to allow Meta OM containers to resolve `host.docker.internal`:

Add `extra_hosts` to both `ops` and `node1` services:

```
  ops:
    ...
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ...

  node1:
    ...
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ...
```

Restart the containers:

```shell
$ cd ops-manager
$ docker compose restart ops node1
```

## Step 3: Reconfigure Primary AppDB Replica Set

The replica set member hostname must use the Docker network IP (not `host.docker.internal`) so Meta OM's monitoring agent can discover it correctly:

```shell
# Reconfigure replica set to use Docker network IP
$ docker exec mongodb-ops-manager mongosh --eval "
cfg = rs.conf();
cfg.members[0].host = '172.18.0.2:27017';
rs.reconfig(cfg);
"

# Verify the change
$ docker exec mongodb-ops-manager mongosh --quiet --eval "rs.status().members.map(m => ({name: m.name, state: m.stateStr}))"
# Should show: [ { name: '172.18.0.2:27017', state: 'PRIMARY' } ]
```

## Step 4: Add Existing Deployment in Meta OM

1. Access Meta OM at [http://ops.om.internal:8080](http://ops.om.internal:8080) or [http://localhost:8080](http://localhost:8080)
2. Navigate to: **Deployment → Add Existing MongoDB Deployment**
3. Enter seed node: **172.18.0.2:27017**
4. Click **Verify Connection**
5. Connection should succeed\! ✅

## Why This Configuration Works

| Component | Connection String | Reason |
| :---- | :---- | :---- |
| **Primary OM** (local) | `host.docker.internal:27018` | Connects via host-mapped port from local machine |
| **Meta OM** (Docker) | `172.18.0.2:27017` | Connects via Docker network internal port |
| **Replica Set Member** | `172.18.0.2:27017` | Matches what Meta OM's monitoring agent discovers |
| **Primary OM uses** | `directConnection=true` | Bypasses replica set discovery, ignores member hostname |

This dual-configuration allows both OMs to connect to the same AppDB despite running in different environments.

## Step 5: Install Agent in Primary AppDB

### Overview

The Primary OM's Application Database (`appdb-rs`) needs to be monitored and backed up by Meta OM. However, **Meta OM's Automation cannot manage the Primary OM's AppDB** (this is a MongoDB restriction). We will:

- ✅ **Install the MongoDB Agent** in the `mongodb-ops-manager` container
- ✅ **Enable Monitoring** to collect metrics and performance data
- ✅ **Enable Backup** to create snapshots and continuous oplog backups
- ❌ **NOT enable Automation** (not supported for Primary OM's AppDB)

### Important Restrictions

According to [MongoDB documentation](https://www.mongodb.com/docs/ops-manager/current/tutorial/prepare-backing-mongodb-instances/#install-the-application-database-and-backup-database):

**Important**: Do not use Ops Manager Automation to deploy or manage the Application Database or Backup Database. Ops Manager Automation cannot manage the MongoDB deployments that Ops Manager uses for its own data.

### Installation Script

The installation script (`om-docker/meta-om-primary-appdb-agent-installation.sh`) automates the following:

1. **Detects and copies the ARM64 agent** from Meta OM container
2. **Installs required system packages** (`hostname`, `procps-ng`)
3. **Installs the MongoDB Agent** binaries
4. **Configures the agent** with Meta OM's API credentials
5. **Starts the agent** with proper PATH settings

Run the installation script:

```shell
$ cd mongo-infra-docker
$ chmod +x om-docker/meta-om-primary-appdb-agent-installation.sh
$ ./om-docker/meta-om-primary-appdb-agent-installation.sh
```

**Expected Output:**

```
==========================================
MongoDB Agent Installation Script
==========================================
Target: mongodb-ops-manager container
Group ID: 69a13144de116a0d710fa00a
...
✓ Agent started successfully (PID: 1234567)
```

### Verify Agent Installation

Check that the agent is running:

```shell
# Check agent process
$ docker top mongodb-ops-manager | grep mongodb-mms-automation-agent

# View agent logs
$ docker exec mongodb-ops-manager tail -f /var/log/mongodb-mms-automation/agent-startup.log
```

In Meta OM UI ([http://localhost:8080](http://localhost:8080)):

1. Go to **Deployment → Agents**
2. You should see the agent for `75c8593e08b3` (or similar hostname) with a **green status**
3. Agent version should be displayed (e.g., `108.0.12.8846`)

### Step 6: Enable Monitoring for Primary AppDB

1. In Meta OM UI, go to **Deployment → Servers**
2. Click on the `75c8593e08b3` server (Primary AppDB container)
3. Click the **"..."** menu → **Enable Monitoring**
4. Wait 30-60 seconds for monitoring to activate

**Verify Monitoring:**

```shell
# Check monitoring agent logs
$ docker exec mongodb-ops-manager tail -20 /var/log/mongodb-mms-automation/meta-monitoring-agent.log
```

You should see:

```
Starting monitoring of `75c8593e08b3:27017`
Collecting DB stats for 161 database(s)
```

In Meta OM UI:

- Go to **Deployment → Metrics**
- Select the `appdb-rs` deployment
- You should see performance charts (CPU, memory, operations, etc.)

### Step 7: Enable Backup for Primary AppDB

#### Configure Meta OM Backup (if not already done)

1. In Meta OM UI, go to **Admin → Backup**
2. Click **Enable Daemon** (if not already enabled)
3. Configure S3 Blockstore:
    - **S3 Bucket Name**: `meta-ops-manager-backup-bucket`
    - **S3 Endpoint**: `s3.eu-north-1.amazonaws.com`
    - **AWS Access Key ID**: Your AWS access key
    - **AWS Secret Access Key**: Your AWS secret key
    - **Hostname:port**: `node1.om.internal:27021` (Meta OM's own AppDB)

#### Enable Backup for Primary AppDB

1. Go to **Deployment → Servers**
2. Click on the `75c8593e08b3` server
3. Click the **"..."** menu → **Enable Backup**
4. Configure backup settings:
    - **Snapshot Schedule**: Default (every 24 hours)
    - **Snapshot Retention**: Default (keep 2 snapshots)
5. Click **Confirm & Deploy**

**Verify Backup:**

```shell
# Check backup agent logs
$ docker exec mongodb-ops-manager tail -30 /var/log/mongodb-mms-automation/meta-backup-agent.log | grep -i "snapshot\|oplog"
```

You should see:

```
Snapshot complete
Successfully finished pushing oplog slice
```

In Meta OM UI:

- Go to **Backup → Snapshots**
- Select `appdb-rs`
- You should see a snapshot listed with status **"COMPLETE"**
- Oplog should show continuous backup activity

### Troubleshooting

**Agent not starting:**

```shell
# Check if required packages are installed
$ docker exec mongodb-ops-manager which hostname
$ docker exec mongodb-ops-manager which ps

# If missing, install them
$ docker exec -u root mongodb-ops-manager yum install -y hostname procps-ng
```

**Agent crashes immediately:**

```shell
# Check agent logs for errors
$ docker exec mongodb-ops-manager cat /var/log/mongodb-mms-automation/agent-startup.log

# Common issue: Missing PATH
# Restart agent with proper PATH:
$ docker exec -u root mongodb-ops-manager bash -c "
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
pkill -f mongodb-mms-automation-agent
nohup /opt/mongodb-mms-automation/bin/mongodb-mms-automation-agent \
    -f /etc/mongodb-mms/automation-agent.config \
    > /var/log/mongodb-mms-automation/agent-startup.log 2>&1 &
"
```

**Monitoring not showing data:**

- Wait 5-10 minutes for initial data collection
- Check that the agent is green in **Deployment → Agents**
- Verify monitoring logs show "Collecting DB stats"

**Backup snapshots not appearing:**

- Ensure S3 credentials are correct in **Admin → Backup**
- Check backup daemon is running in Meta OM
- Verify backup logs show "Snapshot complete"

### Summary

After completing these steps, you should have:

- ✅ MongoDB Agent installed and running in `mongodb-ops-manager` container
- ✅ Monitoring active (collecting metrics from Primary OM's AppDB)
- ✅ Backup active (creating snapshots and streaming oplog)
- ✅ Meta OM successfully managing Primary OM's Application Database
- ❌ Automation correctly disabled (not supported for Primary OM's AppDB)

This completes the Meta OM → Primary OM AppDB backup topology setup\!

# Miscellaneous

## Local OM Admin API Key

```textproto
Public Key:Private Key: 
```

[image1]: <data:image/png;base64,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>