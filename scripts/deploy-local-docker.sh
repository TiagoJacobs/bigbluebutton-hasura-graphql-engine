#!/bin/bash

# -----------------------------------------------------------------------------
# Deploy updated Hasura GraphQL Engine to the local BigBlueButton Docker setup.
# This script is intended for use on a development machine.
#
# It copies the newly built graphql-engine binary to the target BBB instance,
# forcibly stops any running Hasura processes, replaces the binary, and
# restarts the bbb-graphql-server service with clear logs.
# -----------------------------------------------------------------------------

# Color helpers
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RED="\e[31m"
RESET="\e[0m"

echo -e "${BLUE}==> Copying new graphql-engine binary...${RESET}"

scp dist-newstyle/build/x86_64-linux/ghc-9.10.2/graphql-engine-1.0.0/x/graphql-engine/opt/build/graphql-engine/graphql-engine \
  bigbluebutton@bbb30:/tmp/

echo -e "${BLUE}==> Connecting to BBB instance...${RESET}"

ssh bigbluebutton@bbb30 "
  GREEN='\e[32m'
  YELLOW='\e[33m'
  BLUE='\e[34m'
  RED='\e[31m'
  RESET='\e[0m'

  echo -e \"\${BLUE}==> Stopping all bbb-graphql-server instances ...\${RESET}\"
  sudo systemctl stop 'bbb-graphql-server@*.service' || true
  sudo systemctl stop bbb-graphql-server.service || true

  echo -e \"\${BLUE}==> Ensuring Hasura is fully stopped ...\${RESET}\"
  while pgrep -f hasura-graphql-engine >/dev/null; do
    echo -e \"\${YELLOW}Hasura still running — killing it...\${RESET}\"
    sudo pkill -9 -f hasura-graphql-engine || true
    sleep 0.2
  done
  echo -e \"\${GREEN}Hasura successfully stopped.\${RESET}\"

  echo -e \"\${BLUE}==> Deploying new graphql-engine binary...\${RESET}\"
  sudo cp /tmp/graphql-engine /usr/bin/hasura-graphql-engine
  sudo chmod +x /usr/bin/hasura-graphql-engine

  echo -e \"\${BLUE}==> Starting all bbb-graphql-server instances ...\${RESET}\"
  sudo systemctl start bbb-graphql-server.service
  sudo systemctl start 'bbb-graphql-server@*.service' || true

  echo -e \"\${GREEN}Deployment completed successfully! 🚀\${RESET}\"
"

echo -e "${GREEN}All done!${RESET}"

