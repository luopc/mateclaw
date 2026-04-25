#!/bin/bash

set -eo pipefail

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Print help information
usage() {
  echo "Usage: $0 [release|snapshot]"
  echo "  release    - Build and release a new version"
  echo "  snapshot   - Build and deploy a snapshot version (default)"
  exit 1
}

# Parameter processing
if [ $# -eq 0 ]; then
  echo -e "${YELLOW}No build type specified, defaulting to snapshot${NC}"
  BUILD_TYPE="snapshot"
else
  BUILD_TYPE=$(echo "$1" | tr '[:upper:]' '[:lower:]')
fi
start_time=$(date +%s)
# Parameter validation
if [ "$BUILD_TYPE" != "release" ] && [ "$BUILD_TYPE" != "snapshot" ]; then
  echo -e "${RED}Error: Invalid build type argument${NC}"
  usage
fi

if [ "$BUILD_TYPE" = "release" ]; then
  echo -e "${GREEN}Building Release Version${NC}"

  # Clean workspace
  if ! git clean -f; then
    echo -e "${RED}Error: Failed to clean workspace${NC}"
    exit 1
  fi

  # Update dependency versions
  mvn versions:use-latest-releases -Dincludes=com.luopc.platform.parent* -DgenerateBackupPoms=false -DallowSnapshots=false

  # Detect version changes
  echo -e "${YELLOW}Detecting version changes${NC}"
  # Check for uncommitted changes
  changes=$(git status --porcelain)
  if [ -n "$changes" ]; then
    echo -e "${GREEN}Changes detected, committing version updates${NC}"
    git add .

    if git diff --cached --quiet; then
      echo -e "${YELLOW}No changes to commit${NC}"
    else
      if ! git commit -m "#plugin - auto committed"; then
        echo -e "${RED}Error: Failed to commit version changes${NC}"
        exit 1
      else
        echo -e "${GREEN}Version changed and committed${NC}"
      fi
    fi
  else
    echo -e "${YELLOW}No changes detected, skipping commit${NC}"
  fi

  VERSION=$(mvn -q -Dexec.executable="echo" -Dexec.args='${project.version}' --non-recursive org.codehaus.mojo:exec-maven-plugin:3.5.1:exec | awk -v FS="-" '{print $1}')

  # Execute release
  echo -e "${GREEN}Starting release build${NC}"
  if ! mvn -B clean release:prepare-with-pom release:perform \
    -DuseReleaseProfile=false \
    -Dmaven.javadoc.skip=true \
    -Puat; then
    echo -e "${RED}Error: Release build failed${NC}"
    exit 1
  fi
  end_time=$(date +%s)
  echo -e "${YELLOW}[INFO] released version is $VERSION, total duration time: $((end_time - start_time))s${NC}"
  echo -e "${GREEN}deploy -p {package} -v $VERSION -h data${NC}"

elif [ "$BUILD_TYPE" = "snapshot" ]; then
  echo -e "${GREEN}Building Snapshot Version${NC}"
  # -Dmaven.javadoc.skip=true \
  if ! mvn -B clean deploy -Puat; then
    echo -e "${RED}Error: Snapshot build failed${NC}"
    exit 1
  fi

  # Get version number
  VERSION=$(mvn -q -Dexec.executable="echo" \
    -Dexec.args='${project.version}' \
    --non-recursive \
    org.codehaus.mojo:exec-maven-plugin:1.6.0:exec)
  end_time=$(date +%s)
  echo -e "${YELLOW}[INFO] Deployed snapshot version: ${VERSION}, total duration time: $((end_time - start_time))s${NC}"
  echo -e "${GREEN}deploy -p {package} -v $VERSION -h data${NC}"
else
  echo -e "${RED}Error: Invalid build type '$BUILD_TYPE'${NC}"
  usage
fi

echo -e "${NC}java -jar -Dspring.profiles.active=dev -Dapp=example common-example/target/common-example.jar${NC}"
