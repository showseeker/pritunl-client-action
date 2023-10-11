#!/usr/bin/env bash

# Set up error handling
set -euo pipefail

## GitHub Action Inputs as Environment Variables
PRITUNL_PROFILE_FILE="${PRITUNL_PROFILE_FILE:-}"
PRITUNL_PROFILE_PIN="${PRITUNL_PROFILE_PIN:-}"
PRITUNL_VPN_MODE="${PRITUNL_VPN_MODE:-}"
PRITUNL_CLIENT_VERSION="${PRITUNL_CLIENT_VERSION:-}"
PRITUNL_START_CONNECTION="${PRITUNL_START_CONNECTION:-}"

## GitHub Actions Setup and Checks Environent Variables
PRITUNL_READY_PROFILE_TIMEOUT="${PRITUNL_READY_PROFILE_TIMEOUT:-}"
PRITUNL_ESTABLISHED_CONNECTION_TIMEOUT="${PRITUNL_ESTABLISHED_CONNECTION_TIMEOUT:-}"

# Normalize the VPN mode
normalize_vpn_mode() {
  case "$(echo "$PRITUNL_VPN_MODE" | tr '[:upper:]' '[:lower:]')" in
    ovpn|openvpn)
      PRITUNL_VPN_MODE="ovpn"
      ;;
    wg|wireguard)
      PRITUNL_VPN_MODE="wg"
      ;;
    *)
      echo "Invalid VPN mode: $PRITUNL_VPN_MODE"
      exit 1
      ;;
  esac
}
normalize_vpn_mode

# Validate version against raw source version file
validate_version() {
  local version="$1"
  local version_pattern="^[0-9]+(\.[0-9]+)+$"
  local pritunl_client_repo="pritunl/pritunl-client-electron"
  local version_file="https://raw.githubusercontent.com/$pritunl_client_repo/master/CHANGES"

  # Validate Client Version Pattern
  if ! [[ "$version" =~ $version_pattern ]]; then
    echo "Invalid version pattern for $version"
    exit 1
  fi

  # Use curl to fetch the raw file and pipe it to grep
  if ! [[ $(curl --silent --show-error --location $version_file | grep --count "$version") -ge 1 ]]; then
    echo "Invalid Version: '$version' does not exist in the '$pritunl_client_repo' CHANGES file."
    exit 1
  fi
}

# Installation process for Linux
install_linux() {
  if [[ "$PRITUNL_CLIENT_VERSION" == "from-package-manager" ]]; then
    # Install using Pritunl Prebuilt Apt Repository
    echo "deb https://repo.pritunl.com/stable/apt $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/pritunl.list
    gpg --keyserver hkp://keyserver.ubuntu.com --recv-keys 7568D9BB55FF9E5287D586017AE645C0CF8E292A > /dev/null 2>&1
    gpg --armor --export 7568D9BB55FF9E5287D586017AE645C0CF8E292A | sudo tee /etc/apt/trusted.gpg.d/pritunl.asc > /dev/null
    sudo apt-get update -qq --assume-yes
    sudo apt-get install -qq --assume-yes pritunl-client
  else
    # Install using Debian Package from Pritunl GitHub Releases for Version Specific
    validate_version "$PRITUNL_CLIENT_VERSION"
    deb_url="https://github.com/pritunl/pritunl-client-electron/releases/download/$PRITUNL_CLIENT_VERSION/pritunl-client_$PRITUNL_CLIENT_VERSION-0ubuntu1.$(lsb_release -cs)_amd64.deb"
    curl --silent --show-error --location "$deb_url" --output "$RUNNER_TEMP/pritunl-client.deb"
    sudo apt-get install -qq --assume-yes --fix-broken "$RUNNER_TEMP/pritunl-client.deb"
  fi

  install_vpn_dependencies "Linux"
}

# Installation process for macOS
install_macos() {
  if [[ "$PRITUNL_CLIENT_VERSION" == "from-package-manager" ]]; then
    # Install using Homebrew macOS Package Manager
    brew install --quiet --cask pritunl
  else
    # Install using macOS Package from Pritunl GitHub Releases for Version Specific
    validate_version "$PRITUNL_CLIENT_VERSION"
    pkg_zip_url="https://github.com/pritunl/pritunl-client-electron/releases/download/$PRITUNL_CLIENT_VERSION/Pritunl.pkg.zip"
    curl --silent --show-error --location "$pkg_zip_url" --output "$RUNNER_TEMP/Pritunl.pkg.zip"
    unzip -qq -o "$RUNNER_TEMP/Pritunl.pkg.zip" -d "$RUNNER_TEMP"
    sudo installer -pkg "$RUNNER_TEMP/Pritunl.pkg" -target /
  fi

  if ! [[ -d "$HOME/bin" ]]; then
    mkdir -p "$HOME/bin"
  fi
  ln -s "/Applications/Pritunl.app/Contents/Resources/pritunl-client" "$HOME/bin/pritunl-client"

  install_vpn_dependencies "macOS"
}

# Installation process for Windows
install_windows() {
  if [[ "$PRITUNL_CLIENT_VERSION" == "from-package-manager" ]]; then
    # Install using Choco Windows Package Manager
    choco install --no-progress --yes pritunl-client
  else
    # Install using Windows Package from Pritunl GitHub Releases for Version Specific
    validate_version "$PRITUNL_CLIENT_VERSION"
    exe_url="https://github.com/pritunl/pritunl-client-electron/releases/download/$PRITUNL_CLIENT_VERSION/Pritunl.exe"
    curl --silent --show-error --location "$exe_url" --output "$RUNNER_TEMP/Pritunl.exe"
    pwsh -ExecutionPolicy Bypass -Command "Start-Process -FilePath '$RUNNER_TEMP\Pritunl.exe' -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' -Wait"
  fi

  if ! [[ -d "$HOME/bin" ]]; then
    mkdir --parents "$HOME/bin"
  fi
  ln --symbolic "/c/Program Files (x86)/Pritunl/pritunl-client.exe" "$HOME/bin/pritunl-client"

  install_vpn_dependencies "Windows"
  sleep 1

  if [[ "$PRITUNL_VPN_MODE" == "wg" ]]; then
    # Restarting the `pritunl` service to determine the latest changes of the `PATH` values
    # from the `System Environment Variables` during the WireGuard installation is needed.
    pwsh -ExecutionPolicy Bypass -Command "Invoke-Command -ScriptBlock { net stop 'pritunl' ; net start 'pritunl' }"
  fi
}

# Install VPN dependent packages based on OS
install_vpn_dependencies() {
  local os_type="$1"
  if [[ "$PRITUNL_VPN_MODE" == "wg" ]]; then
    if [[ "$os_type" == "Linux" ]]; then
      sudo apt-get install -qq --assume-yes wireguard-tools
    elif [[ "$os_type" == "macOS" ]]; then
      brew install --quiet wireguard-tools
    elif [[ "$os_type" == "Windows" ]]; then
      choco install --no-progress --yes wireguard
    fi
  else
    if [[ "$os_type" == "Linux" ]]; then
      sudo apt-get install -qq --assume-yes openvpn-systemd-resolved
    fi
  fi
}


# Main installation process based on OS
install_platform() {
  local os_type="$1"
  case "$os_type" in
    Linux)
      install_linux
      ;;
    macOS)
      install_macos
      ;;
    Windows)
      install_windows
      ;;
    *)
      echo "Unsupported OS: $os_type"
      exit 1
      ;;
  esac
}

# Main script execution
if [[ "$RUNNER_OS" == "Linux" || "$RUNNER_OS" == "macOS" || "$RUNNER_OS" == "Windows" ]]; then
  install_platform "$RUNNER_OS"
else
  echo "Unsupported OS: $RUNNER_OS"
  exit 1
fi

# Show Pritunl Client Version
pritunl-client version

# Function to print a progress bar
print_progress_bar() {
  local current_step="$1"   # Current step in the process
  local total_steps="$2"    # Total steps in the process
  local message="$3"        # Message to display with the progress bar

  # Calculate the percentage progress
  local percentage=$((current_step * 100 / total_steps))

  # Calculate the number of completed and remaining characters for the progress bar
  local completed=$((percentage / 2))
  local remaining=$((50 - completed))

  # Print the progress bar
  echo -n -e "$message: ["
  for ((i = 0; i < completed; i++)); do
    echo -n -e "#"
  done
  for ((i = 0; i < remaining; i++)); do
    echo -n -e "-"
  done
  echo -n -e "] checking $current_step out of a maximum of $total_steps allowed attempts."

  # Print new line
  echo -n -e "\n"
}

# Function to decode and add a profile
load_profile_file() {
  # Define the total number of steps
  local total_steps="${PRITUNL_READY_PROFILE_TIMEOUT}"

  # Initialize the current step variable
  local current_step=0

  # Save the `base64` text file format and convert it back to `tar` archive file format.
  echo "$PRITUNL_PROFILE_FILE" > "$RUNNER_TEMP/profile-file.base64"
  base64 --decode "$RUNNER_TEMP/profile-file.base64" > "$RUNNER_TEMP/profile-file.tar"

  # Add the Profile File to Pritunl Client
  pritunl-client add "$RUNNER_TEMP/profile-file.tar"

  # Loop until the current step reaches the total number of steps
  while [[ "$current_step" -le "$total_steps" ]]; do
    client_id=$(
      pritunl-client list |
        awk -F '|' 'NR==4{print $2}' |
        sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
    )

    if [[ "$client_id" =~ ^[a-z0-9]{16}$ ]]; then
      # Set `client-id` as step output and break the loop
      echo "client-id=$client_id" >> "$GITHUB_OUTPUT"
      break
    else
      # Increment the current step
      current_step=$((current_step + 1))

      # Print the attempt progress using the progress bar function
      print_progress_bar "$current_step" "$total_steps" "Profile ready"

      # Sleep for a moment (simulating work)
      sleep 1

      # Print the timeout message and exit error if needed
      if [[ "$current_step" -eq "$total_steps" ]]; then
        echo "Profile setup failed! Client ID not found..."
        exit 1
      fi
    fi
  done

  # Disable autostart option
  pritunl-client disable "$client_id"
  # Display Profile Client ID
  echo "Profile is added with Client ID: '$client_id'"
}

# Load the Pritunl Profile File
load_profile_file


# Start VPN connection
start_vpn_connection() {
  local client_id="$1"
  local vpn_flags=()

  if [[ -n "$PRITUNL_VPN_MODE" ]]; then
    vpn_flags+=( "--mode" "$PRITUNL_VPN_MODE" )
  fi

  if [[ -n "$PRITUNL_PROFILE_PIN" ]]; then
    vpn_flags+=( "--password" "$PRITUNL_PROFILE_PIN" )
  fi

  pritunl-client start "$client_id" "${vpn_flags[@]}"
}

# Function to wait for an established connection
wait_connection() {
  # Define the total number of steps
  local total_steps="${PRITUNL_ESTABLISHED_CONNECTION_TIMEOUT}"

  # Initialize the current step variable
  local current_step=0

  # Loop until the current step reaches the total number of steps
  while [[ "$current_step" -le "$total_steps" ]]; do
    active_network=$(
      pritunl-client list |
        awk -F '|' 'NR==4{print $8}' |
        sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
    )

    if [[ "$active_network" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?$ ]]; then
      # "Break the loop if connection established"
      break
    else
      # Increment the current step
      current_step=$((current_step + 1))

      # Print the connection check progress using the progress bar function
      print_progress_bar "$current_step" "$total_steps" "Establishing connection"

      # Sleep for a moment (simulating work)
      sleep 1

      # Print the timeout message and exit error if needed
      if [[ "$current_step" -eq "$total_steps" ]]; then
        echo "Timeout reached! Exiting..."
        exit 1
      fi
    fi
  done
}

# Display VPN Connection Status
display_connection_status() {
  local pritunl_client_info=$(pritunl-client list)
  local profile_name=$(echo "$pritunl_client_info" | awk -F '|' 'NR==4{print $3}' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  local profile_ip=$(echo "$pritunl_client_info" | awk -F '|' 'NR==4{print $8}' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  echo "Connected as '$profile_name' with a private address of '$profile_ip'."
}


if [[ "$PRITUNL_START_CONNECTION" == "true" ]]; then
  # Start the VPN connection
  start_vpn_connection "$client_id"

  # Waiting for an Established Connection
  wait_connection

  # Display VPN Connection Status
  display_connection_status
fi
