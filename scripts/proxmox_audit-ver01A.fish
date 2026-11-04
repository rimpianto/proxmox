#!/usr/bin/env fish

# Work around terminals whose TERM value is not recognized on the host
set -x TERM xterm-256color

# Ensure required packages are installed
if not type -q ccze
    echo "WARNING: 'ccze' is not installed. Colors might not work."
    echo "Install it using: apt-get install ccze -y"
    sleep 2
end

# Function to pause the screen before reloading the menu
function pause
    echo ""
    read -P "Press ENTER to return to the menu..." -l dummy
end

# Infinite loop to display the menu until 'q' is pressed
while true
    clear
    echo "=========================================================="
    echo "      🛡️ PROXMOX SECURITY & AUDIT MENU (Fish Shell)      "
    echo "                             Ver 0.1A                     "
    echo "=========================================================="
    echo " --- ACTIVE SESSIONS ---"
    echo "  1) Currently connected users (w)"
    echo "  2) List active system sessions (loginctl)"
    echo "  3) Single session details (requires ID)"
    echo ""
    echo " --- ACCESS HISTORY (LOGS) ---"
    echo "  4) Successful Terminal (SSH) logins"
    echo "  5) Failed Terminal (SSH) logins"
    echo "  6) Successful Web (GUI) logins"
    echo "  7) Failed Web (GUI) logins"
    echo ""
    echo " --- NETWORK & PROCESSES ---"
    echo "  8) Listening ports (ss -tulpn)"
    echo "  9) Active network connections (ESTAB)"
    echo " 10) Identify program name (requires PID)"
    echo " 11) Root scheduled tasks (crontab)"
    echo " 12) Auto-executed scripts (/etc/cron.d/)"
    echo ""
    echo " --- MALWARE SCANNER ---"
    echo " 13) Quick scan (chkrootkit)"
    echo " 14) Deep scan (rkhunter)"
    echo "=========================================================="
    echo "  q) Exit"
    echo "=========================================================="

    # Read user input
    read -P "Select an option: " choice

    switch $choice
        case 1
            w | ccze -A
            pause
        case 2
            loginctl list-sessions | ccze -A
            pause
        case 3
            read -P "Enter the session ID: " sess_id
            loginctl session-status $sess_id | ccze -A
            pause
        case 4
            echo "Use arrows to scroll. Press 'q' to exit the log."
            sleep 2
            journalctl -u ssh.service --grep="Accepted" | ccze -A | less -R
            pause
        case 5
            echo "Use arrows to scroll. Press 'q' to exit the log."
            sleep 2
            journalctl -u ssh.service --grep="Failed password" | ccze -A | less -R
            pause
        case 6
            echo "Use arrows to scroll. Press 'q' to exit the log."
            sleep 2
            journalctl -u pvedaemon.service --grep="successful auth" | ccze -A | less -R
            pause
        case 7
            echo "Use arrows to scroll. Press 'q' to exit the log."
            sleep 2
            journalctl -u pvedaemon.service --grep="authentication failure" | ccze -A | less -R
            pause
        case 8
            ss -tulpn | ccze -A
            pause
        case 9
            ss -tnp | grep --color=always ESTAB
            pause
        case 10
            read -P "Enter the process PID (e.g. 1354): " pid_num
            ps -p $pid_num -o comm,args | ccze -A
            pause
        case 11
            crontab -l | ccze -A
            pause
        case 12
            ls -la --color=auto /etc/cron.d/
            pause
        case 13
            chkrootkit
            pause
        case 14
            rkhunter --check --sk
            pause
        case q Q
            echo "Exiting... Goodbye!"
            break
        case '*'
            echo "Invalid choice! Please try again."
            pause
    end
end
