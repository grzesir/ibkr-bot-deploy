#!/usr/bin/env bash

dir="$(realpath "$(dirname "$0")")"

if [[ "$*" =~ v ]]; then
  echo "Verbose On"
else
    d="-d"
fi

# cleanup
cleanup() {
    echo "Performing cleanup..."
    rm -f "$dir/.env"
    rm -rf "$dir/options_butterfly_condor"
}

# Set up exit trap
cleanup
trap cleanup EXIT SIGINT SIGTERM

# .env setup
cd "$dir"
PORT=8888
# make .env if not available
if [ ! -e "environment/.env" ]; then
  read -rp "Enter USERNAME: " tws_userid
  read -rp "Enter PASSWORD: " tws_password
  echo "USERNAME=$tws_userid" >> environment/.env
  echo "PASSWORD=$tws_password" >> environment/.env
fi

# pick trade mode
echo "Select trading mode:"
echo "[1] Live"
echo "[2] Paper"
read -rp "Enter your choice: " choice

if [ "$choice" == "1" ]; then
    echo "[*] Will Deploy Live"
    printf "TRADING_MODE=live\n" >> .env

elif [ "$choice" == "2" ]; then
    echo "[*] Will Deploy Paper"
    printf "TRADING_MODE=paper\n" >> .env

else
    echo "Invalid choice. Exiting..."
    exit 1
    
fi

# free ports
sudo docker ps --format "{{.Names}}" | grep 'options-butterfly-condor' | xargs -r sudo docker kill > /dev/null
sudo docker ps --format "{{.Names}}" | grep 'ib-gateway' | xargs -r sudo docker kill > /dev/null

# Check if port is in use and find an available port if necessary
while lsof -ti:$PORT > /dev/null; do
    echo "Port $PORT is in use. Exitting..."
    exit 1
done
echo "Using port $PORT."

printf "INTERACTIVE_BROKERS_CLIENT_ID=%s\n" "$((RANDOM % 1000 + 1))" >> .env
printf "INTERACTIVE_BROKERS_PORT=%s\n" "$PORT" >> .env
printf "INTERACTIVE_BROKERS_IP=ib-gateway\n" >> .env
printf "TWOFA_TIMEOUT_ACTION=restart\n" >> .env
printf "AUTO_RESTART_TIME=11:59 PM\n" >> .env
printf "RELOGIN_AFTER_2FA_TIMEOUT=yes\n" >> .env
printf "TIME_ZONE=Europe/Zurich\n" >> .env
printf "TWS_ACCEPT_INCOMING=accept\n" >> .env
printf "BYPASS_WARNING=yes\n" >> .env
printf "VNC_SERVER_PASSWORD=12345678\n" >> .env
printf "READ_ONLY_API=no\n" >> .env

# add secrets from .env to local .env
cat "$dir/environment/.env" >> .env

echo "Pulling options-butterfly-condor..."

git clone "git@github.com:Lumiwealth-Strategies/options_butterfly_condor.git" || { echo "Probably not logged into git. Exiting..."; exit 1; }

# add needed files
cp environment/Dockerfile options_butterfly_condor/
cp environment/requirements.txt options_butterfly_condor/
cp environment/healthcheck.py options_butterfly_condor/

# add retries to bot ib connection
OS="$(uname)"
case $OS in
  'Linux')
    sed -i 's/broker = InteractiveBrokers(INTERACTIVE_BROKERS_CONFIG)/broker = InteractiveBrokers(INTERACTIVE_BROKERS_CONFIG, max_connection_retries=50)/' "$dir/options_butterfly_condor/credentials.py"
    ;;
  'Darwin') 
    sed -i '' 's/broker = InteractiveBrokers(INTERACTIVE_BROKERS_CONFIG)/broker = InteractiveBrokers(INTERACTIVE_BROKERS_CONFIG, max_connection_retries=50)/' "$dir/options_butterfly_condor/credentials.py"
    ;;
  *) 
  exit 1
  ;;  
esac

OS="$(uname)"
case $OS in
  'Linux')
    sudo docker-compose up --remove-orphans
    #while ! python healthcheck.py; do sleep 5; done
    #sudo docker-compose -f docker-compose-obc.yaml up "$d"
    ;;

  'Darwin') 
    sudo docker compose up --remove-orphans
    #while ! python healthcheck.py; do sleep 5; done
    #sudo docker compose -f docker-compose-obc.yaml up "$d"
    ;;
  *) 
   exit 1
   ;;
esac