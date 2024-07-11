#!/usr/bin/env bash
set -e

dir="$(realpath "$(dirname "$0")")"
OS="$(uname)"

# Source the .env.deploy file if it exists
if [ -f "$dir/.env.deploy" ]; then
    echo "Loading environment variables from .env.deploy file"
    source "$dir/.env.deploy"
fi

# .env setup
cd "$dir"

# Free ports
sudo docker ps --format "{{.Names}}" | grep 'strategy' | xargs -r sudo docker kill > /dev/null
sudo docker ps --format "{{.Names}}" | grep 'ib-gateway' | xargs -r sudo docker kill > /dev/null

# Reset .env if any
rm -f "$dir/.env"

# Echo the env variable IBKR_USERNAME to the user
echo "IBKR_USERNAME: $IBKR_USERNAME"

# Read user choice from environment variable
choice="${TRADING_MODE:-}"

if [ "$choice" == "1" ]; then
    echo "[*] Will Deploy Live"
    printf "TRADING_MODE=live\n" >> .env
    PORT=4003

elif [ "$choice" == "2" ]; then
    printf "TRADING_MODE=paper\n" >> .env
    PORT=4004
    echo "[*] Will Deploy Paper"

elif [ "$choice" == "3" ]; then
    printf "TRADING_MODE=both\n" >> .env
    PORT=4004
    echo "[*] Will Deploy Both"

elif [ "$choice" == "4" ]; then
    rm -f "environment/.cred"
    echo "[*] Credentials Reset"

elif [ "$choice" == "5" ]; then
    rm -f "environment/.pref"
    echo "[*] Settings Reset"

elif [ "$choice" == "6" ]; then
    sudo docker system prune -a -f --volumes
    echo "[*] Done"

elif [ "$choice" == "7" ]; then
    sudo docker images --format "{{.Repository}}" | grep "strategy" | xargs -r sudo docker rmi -f
    echo "[*] Done"

else
    echo "Choice was $choice"
    echo "Invalid choice. Exiting..."
    exit 1
fi

# Check if port is in use and find an available port if necessary
while lsof -ti:$PORT > /dev/null; do
    echo "Port $PORT is in use. Exiting..."
    exit 1
done
echo "Using port $PORT."

# Make .env if not available
if [ ! -e "environment/.cred" ]; then
    tws_userid="${IBKR_USERNAME:-}"
    tws_password="${IBKR_PASSWORD:-}"

    echo "TWS_USERID=$tws_userid" >> environment/.cred
    echo "TWS_PASSWORD=$tws_password" >> environment/.cred
fi

if [ ! -e "environment/.pref" ]; then
    bot_repo="${LUMIBOT_STRATEGY_GITHUB_URL:-}"
    echo "bot_repo=$bot_repo" >> environment/.pref

    echo 'ALPACA_BASE_URL="https://paper-api.alpaca.markets/v2"' >> environment/.pref
    echo 'BROKER=IBKR' >> environment/.pref
    echo "INTERACTIVE_BROKERS_IP=ib-gateway" >> environment/.pref
fi

printf "INTERACTIVE_BROKERS_CLIENT_ID=%s\n" "$((RANDOM % 1000 + 1))" >> .env
printf "INTERACTIVE_BROKERS_PORT=%s\n" "$PORT" >> .env

# Add variables to local .env
cat "$dir/environment/.cred" >> .env
cat "$dir/environment/.pref" >> .env

# Load env variables
source "$dir/.env"

# Clone the repository only if the directory does not exist
if [ ! -d "$dir/environment/bot" ]; then
    git clone "$bot_repo" "$dir/environment/bot" || { echo "Probably not logged into git. Exiting..."; exit 1; }
else
    echo "Directory $dir/environment/bot already exists. Skipping clone."
fi

# Add needed files
cp environment/requirements.txt environment/bot/
cp environment/Dockerfile environment/bot/
cp environment/launch.sh environment/bot/
cp environment/healthcheck.py environment/bot/
# cp environment/bot/credentials.py environment/bot/

# Patch credentials and pick config
case $OS in
    'Linux')
        sed -i 's/broker = InteractiveBrokers(INTERACTIVE_BROKERS_CONFIG)/broker = InteractiveBrokers(INTERACTIVE_BROKERS_CONFIG, max_connection_retries=50)/' environment/bot/credentials.py
        sed -i 's/if ALPACA_CONFIG\["API_KEY"\]:/if ALPACA_CONFIG["API_KEY"] and os.environ.get("BROKER", "").lower() == "alpaca":/' environment/bot/credentials.py
        sed -i "s/LIVE_TRADING_CONFIGURATION_FILE_NAME = '.*'/LIVE_TRADING_CONFIGURATION_FILE_NAME = '${selected_config}'/" environment/bot/main.py
        ;;

    'Darwin') 
        sed -i '' 's/broker = InteractiveBrokers(INTERACTIVE_BROKERS_CONFIG)/broker = InteractiveBrokers(INTERACTIVE_BROKERS_CONFIG, max_connection_retries=50)/' environment/bot/credentials.py
        sed -i '' 's/if ALPACA_CONFIG\["API_KEY"\]:/if ALPACA_CONFIG["API_KEY"] and os.environ.get("BROKER", "").lower() == "alpaca":/' environment/bot/credentials.py
        sed -i '' "s/LIVE_TRADING_CONFIGURATION_FILE_NAME = '.*'/LIVE_TRADING_CONFIGURATION_FILE_NAME = '${selected_config}'/" environment/bot/main.py
        ;;

    *) 
        exit 1
        ;;  
esac

# List available configuration files
echo "Available configuration files:"
config_files=$(ls -1 "environment/bot/configurations")
i=1
for file in $config_files; do
    echo "[$i] $file"
    ((i++))
done

# Read configuration choice from the environment variable
config_choice="${CONFIG_CHOICE:-}"

# Validate user input
if ! [[ "$config_choice" =~ ^[0-9]+$ ]] || ((config_choice < 1 || config_choice > i-1)); then
    # Echo the choice to the user
    echo "Choice was $config_choice"
    echo "Invalid choice. Exiting..."
    exit 1
fi

# Get the selected configuration file
selected_config="$(basename "$(ls -1 "environment/bot/configurations" | grep ".py$" | sed -n "${config_choice}p")" .py)"

# Set the selected configuration file in .env
echo "CONFIG_FILE=$selected_config" >> .env

# Set config
case $OS in
    'Linux')
        sed -i "s/LIVE_TRADING_CONFIGURATION_FILE_NAME = '.*'/LIVE_TRADING_CONFIGURATION_FILE_NAME = '${selected_config}'/" environment/bot/main.py
        ;;

    'Darwin') 
        sed -i '' "s/LIVE_TRADING_CONFIGURATION_FILE_NAME = '.*'/LIVE_TRADING_CONFIGURATION_FILE_NAME = '${selected_config}'/" environment/bot/main.py
        ;;

    *) 
        exit 1
        ;;  
esac

sudo docker compose up --remove-orphans -d