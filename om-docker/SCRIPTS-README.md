# Scripts Overview

This directory contains scripts for setting up and managing the Primary OM AppDB with Meta OM.

## Essential Scripts (KEEP)

### 1. `meta-om-primary-appdb-agent-installation.sh`
**Purpose**: Install MongoDB Agent in the AppDB container  
**When to use**: First-time setup after creating the mongodb-ops-manager container  
**Usage**:
```bash
./om-docker/meta-om-primary-appdb-agent-installation.sh
```

### 2. `meta-om-primary-appdb-agent-restart.sh`
**Purpose**: Restart the automation agent  
**When to use**: When agent becomes unresponsive or after configuration changes  
**Usage**:
```bash
bash om-docker/meta-om-primary-appdb-agent-restart.sh
```

### 3. `fix-automation-agent-user.sh` ⭐ CRITICAL
**Purpose**: Fix UID mismatch between MongoDB and automation agent  
**When to use**: Before enabling Automation (prevents "different UID" error)  
**Usage**:
```bash
bash om-docker/fix-automation-agent-user.sh
```
**What it does**:
- Stops automation agent
- Changes ownership of all automation files to `mongod` user
- Restarts agent as `mongod` user (matching MongoDB process)

### 4. `check-automation-status.sh`
**Purpose**: Comprehensive status check for troubleshooting  
**When to use**: Debugging connectivity or automation issues  
**Usage**:
```bash
bash om-docker/check-automation-status.sh
```
**Shows**:
- Container status
- Network configuration
- MongoDB status
- Agent status
- Replica set configuration

## Setup Documentation

### Primary Setup Guide
**File**: `SETUP-APPDB-FOR-META-OM.md`  
**Purpose**: Complete step-by-step guide for setting up AppDB with Meta OM  
**Covers**:
- Creating MongoDB container with logPath
- Network configuration
- Replica set initialization
- Agent installation
- Enabling Automation
- Troubleshooting

### Original Documentation
**File**: `om-backup-local-setup.md`  
**Purpose**: Original comprehensive setup guide  
**Status**: Contains additional context and alternative approaches

### Quick Reference
**File**: `IMPORT-APPDB-INSTRUCTIONS.md`  
**Purpose**: Quick reference for importing AppDB into Meta OM  
**Use case**: When you already have the container set up

## Typical Workflow

### First-Time Setup
1. Follow `SETUP-APPDB-FOR-META-OM.md` steps 1-7
2. Run `meta-om-primary-appdb-agent-installation.sh`
3. Import deployment in Meta OM UI
4. Run `fix-automation-agent-user.sh` ⭐
5. Enable Automation in Meta OM UI

### Troubleshooting
1. Run `check-automation-status.sh` to diagnose issues
2. If agent is down: `meta-om-primary-appdb-agent-restart.sh`
3. If UID mismatch: `fix-automation-agent-user.sh`

### After Container Restart
1. Check if agent is running: `docker exec mongodb-ops-manager pgrep -fa automation-agent`
2. If not running: `meta-om-primary-appdb-agent-restart.sh`
3. If UID mismatch appears: `fix-automation-agent-user.sh`