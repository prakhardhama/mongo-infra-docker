# Ops Manager Docker Setup

A simplified Docker setup for MongoDB Ops Manager with its appDb (metadata database).

## Features

- Ops Manager running in Docker
- appDb (MongoDB for Ops Manager metadata) running in the same container
- Can connect to MongoDB deployments on your macOS host
- No TLS certificates required
- No load balancer or other extras
- Minimal resource requirements (8GB RAM recommended)

## Prerequisites

- Docker Desktop or Docker Engine
- At least 8GB RAM allocated to Docker
- macOS (Intel or Apple Silicon)

## Quick Start

1. Navigate to the om-docker directory:
   ```bash
   cd /Users/ankit/Repos/mongo-infra-docker/om-docker
   ```

2. Run the quick-start script:
   ```bash
   bash quick-start.sh
   ```

3. The script will:
   - Ask you to enter a name for your Docker stack (default: `om-docker`)
   - Ask you to choose an Ops Manager version (default: **8.0.12** - just press Enter)
   - Ask you to choose your platform (default: **M1-Mac** - just press Enter)
   - Download required packages (MongoDB Enterprise Server and Ops Manager)
   - Build and start the Ops Manager container
   - Wait 5 minutes for Ops Manager to initialize

4. Open your browser and navigate to:
   ```
   http://localhost:8080
   ```

5. Complete the Ops Manager setup:
   - Click "Sign Up" to register your first user (Global Admin)
   - Complete the Initial Setup screens

## Connecting to MongoDB on macOS

To connect Ops Manager to a MongoDB deployment running on your macOS host:

1. In Ops Manager, when adding a deployment, use one of these hostnames:
   - `host.docker.internal:27017` (recommended for Docker Desktop)
   - Your Mac's IP address (e.g., `192.168.1.100:27017`)

2. Make sure your MongoDB on macOS is configured to accept connections from Docker:
   - If using `mongod` directly, bind to `0.0.0.0` instead of `127.0.0.1`
   - Check firewall settings if needed

## Setting Up the MongoDB Agent

Since you'll be setting up the agent manually:

1. In Ops Manager, go to **Deployment >> Agents >> Downloads & Settings**
2. Select your operating system
3. Click **+Generate Key** to create an API key
4. Note the values for:
   - `mmsGroupId`
   - `mmsApiKey`
   - `mmsBaseUrl` (should be `http://ops.om.internal:8080` or `http://localhost:8080`)

5. Use these values when configuring your agent manually

## Data Persistence

All critical data is stored in Docker volumes and will persist across container restarts and system reboots:

- **mongodb-data**: MongoDB appDb data (all Ops Manager metadata)
- **mms-conf**: Ops Manager configuration files
- **mms-logs**: Ops Manager application logs
- **head-data**: Backup head database storage
- **filesystem-data**: Backup filesystem storage

This means you can safely:
- Stop and restart the container
- Restart Docker Desktop
- Reboot your system

Your Ops Manager configuration, users, and managed deployments will be preserved.

### View volumes
```bash
docker volume ls | grep <stack-name>
```

### Inspect a volume
```bash
docker volume inspect <stack-name>_mongodb-data
```

## Container Management

**Note:** Replace `<stack-name>` with the name you provided during setup (default: `om-docker`)

### View Logs
```bash
docker compose -p <stack-name> logs -f ops
```

### Stop Ops Manager
```bash
docker compose -p <stack-name> down
```

### Start Ops Manager (after stopping)
```bash
docker compose -p <stack-name> up -d ops
```

### Access appDb (MongoDB for Ops Manager metadata)

**Using MongoDB Compass:**
```
mongodb://localhost:27171
```

**Using mongosh from inside the container:**
```bash
docker exec -it <stack-name>-ops mongosh
```

**Using mongosh from your Mac (if installed locally):**
```bash
mongosh mongodb://localhost:27171
```

### Access Ops Manager container shell
```bash
docker exec -it <stack-name>-ops /bin/bash
```

### Check container status
```bash
docker compose -p <stack-name> ps
```

## Ports

- `8080` - Ops Manager web interface
- `25999` - Ops Manager API
- `27700-27719` - Ops Manager agent communication ports

## Troubleshooting

### Ops Manager not starting
- Check Docker has at least 8GB RAM allocated
- Check logs: `docker compose -p <stack-name> logs ops`
- Ensure ports 8080, 25999, and 27700-27719 are not in use

### Cannot connect to MongoDB on macOS
- Try using `host.docker.internal` instead of `localhost` or `127.0.0.1`
- Verify MongoDB on macOS is listening on `0.0.0.0` not just `127.0.0.1`
- Check macOS firewall settings

### Container keeps restarting
- Check available disk space
- Review logs for specific errors
- Ensure Docker has sufficient resources

## Clean Up

### Remove containers only (keeps data)
```bash
docker compose -p <stack-name> down
```

### Remove containers AND all data volumes (WARNING: deletes everything)
```bash
docker compose -p <stack-name> down -v
```

### Remove downloaded installation files
```bash
rm -rf downloads/*
```

**Note:** The `-v` flag will delete all persistent data including your Ops Manager configuration, users, and managed deployments. Only use this if you want to start completely fresh.

## Notes

- **Defaults**: The script defaults to Ops Manager 8.0.12 and M1-Mac (aarch64) platform
- **Stack Name**: You can run multiple Ops Manager instances by using different stack names
- **Data Persistence**: All data is stored in Docker volumes and persists across restarts
- The appDb (MongoDB metadata database) runs inside the ops container
- No TLS certificates are configured in this setup
- The setup is minimal and doesn't include load balancers, proxies, or other extras
- Agent setup is done manually, so no agent configuration files are included

