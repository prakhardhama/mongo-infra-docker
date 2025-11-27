#!/bin/bash

if [[ "$DOCKER_DEFAULT_PLATFORM" == linux/amd64 ]]
then
  echo "Looks like you've set DOCKER_DEFAULT_PLATFORM to force amd64:"
  echo " - We want to run a native aarch64 container for you, don't worry we will swap the jdk"
  echo " - You could try unset DOCKER_DEFAULT_PLATFORM, then run this again"
  exit 1
fi

# Ask for Docker stack name
echo "Enter a name for your Docker stack (used for container and network names):"
read -p "Stack name [default: om-docker]: " stack_name
stack_name=${stack_name:-om-docker}
echo "Using stack name: $stack_name"
echo

# Set defaults: OM 8.0.12 and M1-Mac
export version='8.0.12'
export version_for_url='8.0'
export platform="aarch64"
export distro="amzn2"

version_options=("8-0-12" "7-0-17" "downloaded")
echo "Choose Ops Manager version (default: 8-0-12):"
PS3="Select version [1]: "
select opt in "${version_options[@]}"
do
  case $opt in
    8-0-12)
      export version='8.0.12'
      export version_for_url='8.0'
      touch downloads/8.ver 2>&1
      rm downloads/7.ver 2>&1
      break
      ;;
    7-0-17)
      export version='7.0.17'
      export version_for_url='7.0'
      rm downloads/8.ver 2>&1
      touch downloads/7.ver 2>&1
      break
      ;;
    downloaded)
      export skip_download='true'
      rm downloads/8.ver 2>&1
      rm downloads/7.ver 2>&1
      break
      ;;
    *)
      # Default to 8-0-12 if just pressing enter
      if [[ -z "$REPLY" ]] || [[ "$REPLY" == "1" ]]; then
        export version='8.0.12'
        export version_for_url='8.0'
        touch downloads/8.ver 2>&1
        rm downloads/7.ver 2>&1
        break
      else
        echo "Invalid option"
      fi
      ;;
  esac
done

echo "Choose platform (default: M1-Mac):"
platform_options=("M1-Mac" "Intel-Mac" "Linux" "Linux-ARM" "Quit")
PS3="Select platform [1]: "
select opt in "${platform_options[@]}"
do
  # Determine sed command based on OS
  if [[ "$(uname)" == "Darwin" ]]; then
    SED_CMD="sed -i ''"
  else
    SED_CMD="sed -i"
  fi
  
  case $opt in
    M1-Mac)
      echo "Configuring for an M1/M2/Mxxx Mac"
      $SED_CMD 's/x86_64/aarch64/g' docker-compose.yml
      $SED_CMD 's/Dockerfile-x86_64-rhel8-om/Dockerfile-aarch64-rhel8-om/g' docker-compose.yml
      export platform="aarch64"
      export distro="amzn2"
      break
      ;;
    Intel-Mac)
      echo "Configuring for an Intel Mac"
      $SED_CMD 's/aarch64/x86_64/g' docker-compose.yml
      $SED_CMD 's/Dockerfile-aarch64-rhel8-om/Dockerfile-x86_64-rhel8-om/g' docker-compose.yml
      export platform="x86_64"
      export distro="rhel8"
      break
      ;;
    Linux)
      echo "Configuring for Linux/Windows"
      $SED_CMD 's/aarch64/x86_64/g' docker-compose.yml
      $SED_CMD 's/Dockerfile-aarch64-rhel8-om/Dockerfile-x86_64-rhel8-om/g' docker-compose.yml
      export platform="x86_64"
      export distro="rhel8"
      break
      ;;
    Linux-ARM)
      echo "Configuring for Generic-ARM"
      $SED_CMD 's/x86_64/aarch64/g' docker-compose.yml
      $SED_CMD 's/Dockerfile-x86_64-rhel8-om/Dockerfile-aarch64-rhel8-om/g' docker-compose.yml
      export platform="aarch64"
      export distro="amzn2"
      break
      ;;
    Quit)
      echo "Bye."
      exit 0
      ;;
    *)
      # Default to M1-Mac if just pressing enter
      if [[ -z "$REPLY" ]] || [[ "$REPLY" == "1" ]]; then
        echo "Configuring for an M1/M2/Mxxx Mac (default)"
        $SED_CMD 's/x86_64/aarch64/g' docker-compose.yml
        $SED_CMD 's/Dockerfile-x86_64-rhel8-om/Dockerfile-aarch64-rhel8-om/g' docker-compose.yml
        export platform="aarch64"
        export distro="amzn2"
        break
      else
        echo "Invalid option"
      fi
      ;;
  esac
done

# Set up urls based on the above parameters
if [[ "$version" == "8.0.12" ]] # Updates JDK to jdk-21.0.8+9.
then
  urls=("https://repo.mongodb.com/yum/redhat/8/mongodb-enterprise/${version_for_url}/${platform}/RPMS/mongodb-enterprise-server-8.0.1-1.el8.${platform}.rpm" "https://downloads.mongodb.com/on-prem-mms/rpm/mongodb-mms-8.0.12.500.20250804T1959Z.x86_64.rpm" "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.8%2B9/OpenJDK21U-jdk_aarch64_linux_hotspot_21.0.8_9.tar.gz")
fi

if [[ "$version" == "7.0.17" ]] # Updates JDK to jdk-17.0.16+8.
then
  urls=("https://repo.mongodb.com/yum/redhat/8/mongodb-enterprise/${version_for_url}/${platform}/RPMS/mongodb-enterprise-server-7.0.0-1.el8.${platform}.rpm" "https://downloads.mongodb.com/on-prem-mms/rpm/mongodb-mms-7.0.17.500.20250806T1728Z.x86_64.rpm" "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.16%2B8/OpenJDK17U-jdk_aarch64_linux_hotspot_17.0.16_8.tar.gz")
fi

# Create downloads directory if it doesn't exist
mkdir -p downloads

# Download AppDB and Ops Manager
if [[ $skip_download != true ]]
then
  echo "Downloading AppDB from ${urls[0]}"
  curl -o downloads/mongodb-enterprise.${platform}.rpm -L "${urls[0]}"
  echo ""
  echo "Downloading Ops Manager from ${urls[1]}"
  curl -o downloads/mongodb-mms.x86_64.rpm -L "${urls[1]}"
  echo ""
  if [[ "$platform" == "aarch64" ]]
  then
    echo "Downloading JDK ${urls[2]}"
    curl -o downloads/jdk.${platform}.tar.gz -L "${urls[2]}"
  fi
  echo
fi 

# Update container name in docker-compose.yml with stack name
if [[ "$(uname)" == "Darwin" ]]; then
  # macOS sed - match any existing container name and replace with stack name
  sed -i '' "s/container_name:.*/container_name: ${stack_name}-ops/" docker-compose.yml
else
  # Linux sed - match any existing container name and replace with stack name
  sed -i "s/container_name:.*/container_name: ${stack_name}-ops/" docker-compose.yml
fi

# Build and run Ops Manager container
echo "Building and starting Ops Manager container with stack name: $stack_name..."
docker compose -p "$stack_name" up -d ops --build
echo
echo "Waiting 5 minutes for Ops Manager to start up..."
echo
sleep 300
echo
echo "=== Ops Manager Setup Complete ==="
echo
echo "Stack name: $stack_name"
echo "Container name: ${stack_name}-ops"
echo "Ops Manager should now be running at: http://localhost:8080"
echo
echo "Next steps:"
echo "1. Open http://localhost:8080 in your browser"
echo "2. Click 'Sign Up' and register your first user (Global Admin)"
echo "3. Complete the Initial Setup screens"
echo "4. To connect to your MongoDB deployment on macOS:"
echo "   - Use 'host.docker.internal' as the hostname (e.g., host.docker.internal:27017)"
echo "   - Or use your Mac's IP address if host.docker.internal doesn't work"
echo
echo "The appDb (MongoDB for Ops Manager metadata) is running inside the ${stack_name}-ops container."
echo "You can access it via:"
echo "  - MongoDB Compass: mongodb://localhost:27171"
echo "  - mongosh: docker exec -it ${stack_name}-ops mongosh"
echo
echo "=== Data Persistence ==="
echo "Your data is stored in Docker volumes and will persist across container restarts:"
echo "  - mongodb-data: MongoDB appDb data"
echo "  - mms-conf: Ops Manager configuration"
echo "  - mms-logs: Ops Manager logs"
echo "  - head-data: Backup head database"
echo "  - filesystem-data: Backup filesystem storage"
echo
echo "To stop Ops Manager: docker compose -p $stack_name down"
echo "To view logs: docker compose -p $stack_name logs -f ops"
echo "To remove all data (WARNING - deletes everything): docker compose -p $stack_name down -v"
echo

