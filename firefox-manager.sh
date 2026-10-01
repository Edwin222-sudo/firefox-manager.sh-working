#!/bin/sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SIZE_FILE="/tmp/firefox_size.txt"
WRAPPER_HTML="/root/firefox-autokeyboard.html"

show_header() {
    clear
    echo "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo "${BLUE}║     🦊 Firefox Container Manager      ║${NC}"
    echo "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
}

get_current_size() {
    if docker ps | grep -q firefox-kiosk; then
        local size=$(docker exec firefox-kiosk sh -c 'echo $DISPLAY_WIDTH 2>/dev/null' 2>/dev/null)
        local height=$(docker exec firefox-kiosk sh -c 'echo $DISPLAY_HEIGHT 2>/dev/null' 2>/dev/null)
        if [ ! -z "$size" ] && [ ! -z "$height" ]; then
            echo "${size}x${height}"
            return
        fi
        if [ -f "$SIZE_FILE" ]; then
            cat "$SIZE_FILE"
            return
        fi
        echo "Unknown"
    else
        echo "Stopped"
    fi
}

show_menu() {
    echo "${YELLOW}Current Status:${NC}"
    if docker ps | grep -q firefox-kiosk; then
        echo "${GREEN}✅ Firefox is RUNNING${NC}"
        CURRENT_SIZE=$(get_current_size)
        echo "📱 Current size: $CURRENT_SIZE"
    else
        echo "${RED}❌ Firefox is STOPPED${NC}"
    fi
    echo ""
    echo "${BLUE}Select an option:${NC}"
    echo "1) 📱 iPhone 17 (393x852)"
    echo "2) 📱 iPhone 16 (393x852)"
    echo "3) 📱 iPhone 15 (393x852)"
    echo "4) 📱 iPhone 13 (390x844)"
    echo "5) 💻 MacBook (1440x900)"
    echo "6) 💻 MacBook Pro (1680x1050)"
    echo "7) 🖥️ Desktop (1920x1080)"
    echo "8) 📊 Tablet (1024x1366)"
    echo "9) ⭐ Your Favorite (440x956)"
    echo "10) ✏️ Custom Size"
    echo "11) 🔄 Restart Firefox"
    echo "12) 🛑 Stop Firefox"
    echo "13) 🗑️ Remove Container"
    echo "14) 📋 Show Logs"
    echo "0) ❌ Exit"
    echo ""
}

# ---------------------------------------------------------------
# FIXED: waits for noVNC to actually be extracted from the image
# before copying index.html. Prevents empty-file race condition.
# ---------------------------------------------------------------
check_wrapper_file() {
    # Already exists and is valid? Reuse it.
    if [ -s "$WRAPPER_HTML" ] && grep -q "noVNC_container" "$WRAPPER_HTML" 2>/dev/null; then
        return 0
    fi

    echo "${YELLOW}Building wrapper from container's real index.html...${NC}"

    # Ensure the data dir exists so bind mounts never silently fail
    mkdir -p /root/firefox_data
    chmod 755 /root/firefox_data

    docker rm -f firefox-tmp 2>/dev/null
    docker run -d --name=firefox-tmp jlesage/firefox > /dev/null 2>&1

    # Wait up to 90s for noVNC's index.html to appear inside the container
    waited=0
    while [ $waited -lt 90 ]; do
        if docker exec firefox-tmp test -s /opt/noVNC/index.html 2>/dev/null; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if ! docker exec firefox-tmp test -s /opt/noVNC/index.html 2>/dev/null; then
        echo "${RED}❌ noVNC index.html never appeared in container (waited ${waited}s)${NC}"
        docker rm -f firefox-tmp 2>/dev/null
        return 1
    fi

    # Copy the REAL index.html out of the container
    docker cp firefox-tmp:/opt/noVNC/index.html "$WRAPPER_HTML" 2>/dev/null

    if [ ! -s "$WRAPPER_HTML" ]; then
        echo "${RED}❌ Failed to copy index.html out of container${NC}"
        docker rm -f firefox-tmp 2>/dev/null
        return 1
    fi

    # Inject the hint badge before </body>
    sed -i 's|</body>|<style>#wrapper-hint{position:fixed;top:8px;left:50%;transform:translateX(-50%);background:rgba(0,0,0,0.9);color:#fff;padding:8px 16px;border-radius:20px;font:600 13px -apple-system,sans-serif;z-index:99999;box-shadow:0 2px 10px rgba(0,0,0,0.7);border:1px solid rgba(255,255,255,0.25);white-space:nowrap;pointer-events:none;}</style><div id="wrapper-hint">Tap three dots on the left to show keyboard</div></body>|' "$WRAPPER_HTML"

    if [ -s "$WRAPPER_HTML" ]; then
        echo "${GREEN}✅ Created $WRAPPER_HTML ($(wc -c < "$WRAPPER_HTML") bytes)${NC}"
    else
        echo "${RED}❌ Wrapper file is empty after injection${NC}"
        docker rm -f firefox-tmp 2>/dev/null
        return 1
    fi

    docker rm -f firefox-tmp 2>/dev/null
    return 0
}

switch_device() {
    local device=$1
    local width=$2
    local height=$3

    echo "${YELLOW}Switching to $device (${width}x${height})...${NC}"

    # FIX: ensure host data dir exists before bind-mounting
    mkdir -p /root/firefox_data
    chmod 755 /root/firefox_data

    if ! check_wrapper_file; then
        return 1
    fi

    # FIX: force-remove any stuck "Created" container before recreating
    docker stop firefox-kiosk 2>/dev/null
    docker rm -f firefox-kiosk 2>/dev/null

    echo "${width}x${height}" > "$SIZE_FILE"

    if [ "$width" -le 500 ]; then
        docker run -d \
            --name=firefox-kiosk \
            --restart unless-stopped \
            -p 80:5800 \
            -e FF_OPEN_URL="https://gmail.com/" \
            -e DISPLAY_WIDTH="$width" \
            -e DISPLAY_HEIGHT="$height" \
            -e DISPLAY_NUM=0 \
            -e DISPLAY_REFRESH=60 \
            -e KEEP_APP_RUNNING=1 \
            -e TZ=Africa/Nairobi \
            -e VNC_RESOLUTION="${width}x${height}" \
            -e FF_ZOOM_LEVEL="100" \
            -e FF_DPI=96 \
            -v /root/firefox_data:/config:rw \
            -v /root/firefox-autokeyboard.html:/opt/noVNC/index.html:ro \
            --shm-size=2g \
            --memory="2g" \
            --cpus="1" \
            jlesage/firefox
    else
        docker run -d \
            --name=firefox-kiosk \
            --restart unless-stopped \
            -p 80:5800 \
            -e FF_OPEN_URL="https://gmail.com/" \
            -e DISPLAY_WIDTH="$width" \
            -e DISPLAY_HEIGHT="$height" \
            -e DISPLAY_NUM=0 \
            -e DISPLAY_REFRESH=60 \
            -e KEEP_APP_RUNNING=1 \
            -e TZ=Africa/Nairobi \
            -e VNC_RESOLUTION="${width}x${height}" \
            -e FF_ZOOM_LEVEL="100" \
            -e FF_DPI=96 \
            -v /root/firefox_data:/config:rw \
            -v /root/firefox-autokeyboard.html:/opt/noVNC/index.html:ro \
            --shm-size=2g \
            --memory="4g" \
            --cpus="2" \
            jlesage/firefox
    fi

    if [ $? -eq 0 ]; then
        echo "${GREEN}✅ Firefox started${NC}"
        echo ""
        echo "🌐 Open on your phone:"
        echo "   ${BLUE}http://YOUR_VPS_IP:80/${NC}"
        echo ""
        echo "⌨️  To type: tap the ☰ (three dots on the left) → Keyboard"
        echo "📱 Resolution: ${width}x${height}"
        echo ""
        echo "${YELLOW}Waiting 10s for Firefox to initialize...${NC}"
        sleep 10
        echo "${GREEN}✅ Ready${NC}"
        echo "🔄 Open http://YOUR_VPS_IP:80/"
    else
        echo "${RED}❌ Failed to start Firefox${NC}"
    fi
}

while true; do
    show_header
    show_menu
    printf "Enter your choice: "
    read choice

    case $choice in
        1) switch_device "iphone17" 393 852 ;;
        2) switch_device "iphone16" 393 852 ;;
        3) switch_device "iphone15" 393 852 ;;
        4) switch_device "iphone13" 390 844 ;;
        5) switch_device "macbook" 1440 900 ;;
        6) switch_device "macbook-pro" 1680 1050 ;;
        7) switch_device "desktop" 1920 1080 ;;
        8) switch_device "tablet" 1024 1366 ;;
        9) switch_device "favorite" 440 956 ;;
        10)
            printf "Enter width: "
            read width
            printf "Enter height: "
            read height
            if echo "$width" | grep -q '^[0-9]\+$' && echo "$height" | grep -q '^[0-9]\+$'; then
                switch_device "custom" "$width" "$height"
            else
                echo "${RED}Invalid dimensions${NC}"
            fi
            ;;
        11)
            docker restart firefox-kiosk
            echo "${GREEN}✅ Firefox restarted${NC}"
            sleep 20
            echo "${GREEN}✅ Refresh your browser${NC}"
            ;;
        12)
            docker stop firefox-kiosk
            echo "${YELLOW}⚠️ Firefox stopped${NC}"
            ;;
        13)
            docker stop firefox-kiosk 2>/dev/null
            docker rm -f firefox-kiosk 2>/dev/null
            rm -f "$SIZE_FILE"
            echo "${YELLOW}⚠️ Container removed${NC}"
            ;;
        14)
            docker logs --tail 50 firefox-kiosk
            printf "\nPress Enter to continue..."
            read dummy
            ;;
        0)
            echo "${GREEN}Goodbye!${NC}"
            exit 0
            ;;
        *)
            echo "${RED}Invalid option${NC}"
            ;;
    esac

    printf "Press Enter to continue..."
    read dummy
done
