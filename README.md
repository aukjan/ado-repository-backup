# Azure DevOps repository backup

## :bulb: Introduction

Microsoft doesn't provide any built-in solution to backup the Azure Devops git repositories.

They ask them to trust the process as described in the [Data Protection Overview](https://docs.microsoft.com/en-us/azure/devops/organizations/security/data-protection?view=azure-devops) page, however most companies want to keep an **on-premise** backup of their code repositories.


## Project 

This project provides a **bash script** to backup all azure devops repositories of an Azure Devops Organization and a **yaml azure pipeline** that can be scheduled to run backup every day/week.

Running the backup from pipeline has the advantage of not having to worry about renewing the PAT which can have a maximum validity period of 1 year.

Finally the project includes a docker setup to create a specific docker image and run the backup through a docker container. Docker compose is used for the purpose.

## Credits

Initially a fork of https://github.com/lionelpere/azure-devops-repository-backup, most of ideas and bash main script taken from it.

Modified by Aukjan van Belkum, 2026

## :bullettrain_side: Azure DevOps pipeline

The `azure-pipelines.yml` file is ready to be used as azure devops yaml pipeline. It is required a linux host with azure devops agent installed.

### Setup a pipeline that uses the bash script

1. Create a new pipeline using the `azure-pipelines.yml` file
2. Adjust the pipeline schedule as desired
3. Replace the value of variable AgentTagName
4. Adjust the script parameters to fit your needs

### Setup a pipeline that uses docker compose task

1. Create a new pipeline using the `azure-pipelines-docker.yml` file
2. Adjust the pipeline schedule as desired
3. Replace the value of variable AgentTagName
4. Add further environment variables as `dockerComposeFileArgs` to change the defaults of script parameters

## :fire: Bash Script

### Prerequisite 

* Shell bash (If you're running on windows, use [WSL2](https://docs.microsoft.com/en-us/windows/wsl/) to easily run a GNU/Linux environment)
* Azure CLI : [Installation guide](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
* Azure CLI - Devops Extension : [Installation guide](https://docs.microsoft.com/en-us/azure/devops/cli/?view=azure-devops)
* git, jq, base64 packages (available in most Linux distributions)

Interaction with the Azure DevOps API requires a [personal access token](https://docs.microsoft.com/en-us/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate?view=azure-devops).

For this backup script you need to generate a PAT with read access on Code. Using the pipeline doesn't require this configuration because the pipeline uses the internal SYSTEM_ACCESS_TOKEN of build agent itself.

**Additional PAT scopes required for optional features:**
- **Pipelines** (`-l`): Build (Read)
- **Artifacts** (`-a`): Packaging (Read)
- **Backlog** (`-b`): Work Items (Read)

### Usage:
```shell
     ./backup-devops.sh [-h] -p PAT -d backup-dir -o organization -r retention [-v] [-x] [-w] [-n] [-b] [-s] [-l] [-a] [-f projects]
     where:
          -h  show this help text
          -p  personal access token (PAT) for Azure DevOps [REQUIRED]
          -d  backup directory path: the directory where to store the backup archive [REQUIRED]
          -o  Azure DevOps organization URL (e.g. https://dev.azure.com/organization) [REQUIRED]
          -r  retention days for backup files: how many days to keep the backup files [REQUIRED]
              A value of zero is accepted and keeps only the last daily backup
          -v  verbose mode [default is false]
          -x  dry run mode (no actual backup, only simulation) [default is false]
          -w  backup project wiki [default is false]
          -n  do not compress backup folder [default is true]
          -b  backup backlog work items (exports via REST API as JSON) [default is false]
          -s  skip repository cloning (use with -b/-l/-a for metadata-only mode) [default is false]
          -l  backup pipeline definitions (YAML + classic as JSON) [default is false]
          -a  backup artifact feeds, packages and binaries [default is false]
          -f  filter projects: comma-separated list of project names to backup [default is all]
```

## :whale: Run with docker compose

If you don't want to install all those prerequisities or you want to isolate this process, you can run this task in a docker image.

### Istructions:

~~~shell
$ git clone https://github.com/aukjan/ado-repository-backup.git

$ cd ado-repository-backup
~~~
create a .env file to store variables of ADO organization and PAT
~~~shell
$ cat .env 
DEVOPS_PAT=+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
DEVOPS_ORG_URL=https://dev.azure.com/MyOrg
~~~
review the compose.yml file and change options if needed
~~~shell
➜  docker git:(master) ✗ docker compose config
name: adorepobck
services:
  backup:
    build:
      context: /home/tom/source/ado-repository-backup
      dockerfile: docker/Dockerfile
    container_name: adorepobck
    environment:
      DEVOPS_ORG_URL: https://dev.azure.com/MyOrg
      DEVOPS_PAT: +++++++++++++++++++++++++++++++++++++++++++++++++++++++++
      DRY_RUN: "false"
      NOCOMPRESS: "false"
      RETENTION_DAYS: "1"
      VERBOSE: "false"
      WIKI: "true"
    image: adorepobck:latest
    networks:
      default: null
    pull_policy: build
    volumes:
      - type: bind
        source: /home/tom/source/ado-repository-backup/docker/data
        target: /data
        bind:
          create_host_path: true
networks:
  default:
    name: adorepobck_default

~~~

start docker container with compose:
~~~shell
➜  docker git:(master) ✗ docker compose up    
[+] Building 0.1s (13/13) FINISHED                                                                                                                                   docker:default
 => [backup internal] load build definition from Dockerfile                                                                                                                    0.0s
 => => transferring dockerfile: 547B                                                                                                                                           0.0s
 => [backup internal] load metadata for mcr.microsoft.com/azure-cli:latest                                                                                                     0.0s
 => [backup internal] load .dockerignore                                                                                                                                       0.0s
 => => transferring context: 2B                                                                                                                                                0.0s
 => [backup 1/7] FROM mcr.microsoft.com/azure-cli:latest                                                                                                                       0.0s
 => [backup internal] load build context                                                                                                                                       0.0s
 => => transferring context: 912B                                                                                                                                              0.0s
 => CACHED [backup 2/7] RUN tdnf check-update     && tdnf --refresh install -y          tar jq git     && tdnf clean all                                                       0.0s
 => CACHED [backup 3/7] RUN az extension add --name azure-devops                                                                                                               0.0s
 => CACHED [backup 4/7] RUN /usr/sbin/useradd -m -s /bin/bash devops                                                                                                           0.0s
 => CACHED [backup 5/7] COPY --chown=devops --chmod=744 src/backup-devops.sh /home/devops                                                                                      0.0s
 => [backup 6/7] COPY --chown=devops --chmod=744 docker/starter.sh /home/devops                                                                                                0.0s
 => [backup 7/7] WORKDIR /home/devops                                                                                                                                          0.0s
 => [backup] exporting to image                                                                                                                                                0.0s
 => => exporting layers                                                                                                                                                        0.0s
 => => writing image sha256:5a764125e82f076a12bfa7328e27bd6f8891526f594b3dd371e9abf9dea7cc70                                                                                   0.0s
 => => naming to docker.io/library/adorepobck:latest                                                                                                                           0.0s
 => [backup] resolving provenance for metadata file                                                                                                                            0.0s
[+] Running 2/2
 ✔ backup                Built                                                                                                                                                 0.0s 
 ✔ Container adorepobck  Recreated                                                                                                                                             0.1s 
Attaching to adorepobck
adorepobck  | INFO: running script ./backup-devops.sh -p <YOUR_PAT_TOKEN> -o https://dev.azure.com/MyOrg -d /data -r 1   -w
adorepobck  | === Azure DevOps Repository Backup Script ===
adorepobck  | === Script parameters
adorepobck  | ORGANIZATION_URL  = https://dev.azure.com/MyOrg
adorepobck  | BACKUP_ROOT_PATH  = /data
adorepobck  | RETENTION_DAYS    = 1
adorepobck  | DRY_RUN           = false
adorepobck  | PROJECT_WIKI      = true
adorepobck  | VERBOSE_MODE      = false
adorepobck  | COMPRESS          = true
adorepobck  | === Install DevOps Extension
adorepobck  | === Set AZURE_DEVOPS_EXT_PAT env variable
adorepobck  | === Get project list
adorepobck  | === Backup folder created [/data/202504221958]
adorepobck  | ==> Found project [0] [lab]
adorepobck  | ==> Backup project [0] [lab] [eb147cba-7fc6-4ab2-bbf9-3cc2a23f04dd]
adorepobck  | === Backup folder created [/data/202504221958/lab]
adorepobck  | ====> Backup repo [0][dcv2] [a84eeb8f-a39f-49be-aa27-14953f801652] [https://dev.azure.com/MyOrg/lab/_git/dcv2]
adorepobck  | Cloning into '/data/202504221958/lab/repo/dcv2'...
adorepobck  | ====> Backup repo [2][gitlab] [a6739d38-bc24-431f-b840-97c7701df79a] [https://dev.azure.com/MyOrg/lab/_git/gitlab]
adorepobck  | Cloning into '/data/202504221958/lab/repo/gitlab'...
adorepobck  | ====> Backup repo [3][gitversion] [28772289-eec6-43d7-8a90-89aa94f0eb8d] [https://dev.azure.com/MyOrg/lab/_git/gitversion]
adorepobck  | Cloning into '/data/202504221958/lab/repo/gitversion'...
adorepobck  | ====> Backup repo [4][lab] [7dd9fd5c-0cde-4b96-b419-20bb3c193c25] [https://dev.azure.com/MyOrg/lab/_git/lab]
adorepobck  | Cloning into '/data/202504221958/lab/repo/lab'...
adorepobck  | ====> Backup repo [5][versioning.v2] [f3a4a150-7cc7-4cc6-810a-3adaaea86d43] [https://dev.azure.com/MyOrg/lab/_git/versioning.v2]
adorepobck  | Cloning into '/data/202504221958/lab/repo/versioning.v2'...
adorepobck  | ====> Backup Wiki repo https://dev.azure.com/MyOrg/lab/_git/lab.wiki
adorepobck  | Cloning into '/data/202504221958/lab/wiki/lab'...
adorepobck  | remote: TF401019: The Git repository with name or identifier lab.wiki does not exist or you do not have permissions for the operation you are attempting.
adorepobck  | fatal: repository 'https://dev.azure.com/MyOrg/lab/_git/lab.wiki/' not found
adorepobck  | ====> WARNING: backup failed for repo [https://dev.azure.com/MyOrg/lab/_git/lab.wiki]
adorepobck  | ====> WARNING: wiki not defined?
adorepobck  | === Backup completed ===
adorepobck  | Projects : 1
adorepobck  | Repositories : 8
adorepobck  | === Compress folder
adorepobck  | Size : 13M        /data/202504221958 (uncompressed) - 6.7M        202504221958.tar.gz (compressed)
adorepobck  | === Remove raw data in folder
adorepobck  | === Apply retention policy (1 days):
adorepobck  | === i'm going to delete following files:
adorepobck  | /data/202504201852.tar.gz
adorepobck  | === Done.
adorepobck  | Elapsed time : 0 days 00 hr 00 min 18 sec
adorepobck exited with code 0
~~~

### Running individual services

The compose file includes separate services for each backup mode. Run them individually:

```shell
# Backup only pipeline definitions
docker compose up pipelines

# Backup only artifact feeds and binaries
docker compose up artifacts

# Backup only backlog work items
docker compose up backlog

# Full backup (repos + wiki)
docker compose up backup
```

### Project filtering

To limit backup to specific projects, set `PROJECT_FILTER` in your `.env` file:

```shell
# .env
PROJECT_FILTER=MyProject,AnotherProject
```

Or pass it directly:

```shell
PROJECT_FILTER=MyProject docker compose up pipelines
```
