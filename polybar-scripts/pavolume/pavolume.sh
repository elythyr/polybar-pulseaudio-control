#!/bin/bash

# SCRIPT CONFIGURATION - More info in the README.md
OSD="no"  # On Screen Display message for KDE if enabled
INC=2  # Increment when lowering/rising the volume
MAX_VOL=130  # Maximum volume
AUTOSYNC="no"  # All programs have the same volume if enabled
VOLUME_ICONS=( "# " "# " "# " )  # Volume icons array, from lower volume to higher
MUTED_ICON="# "  # Muted volume icon
MUTED_COLOR="%{F#6b6b6b}"  # Color when the audio is muted
DEFAULT_SINK_ICON="# "  # The default sink icon if a custom one isn't found
CUSTOM_SINK_ICONS=(  )  # Custom sink icons in index of sink order
NOTIFICATIONS="no"  # Notifications when switching sinks if enabled
SINK_BLACKLIST=(  )  # Index blacklist for sinks when switching between them


# Script variables
isMuted="no"
activeSink=""
endColor="%{F-}"

function getCurVol {
    curVol=$(pacmd list-sinks | grep -A 15 'index: '"$activeSink"'' | grep 'volume:' | grep -E -v 'base volume:' | awk -F : '{print $3}' | grep -o -P '.{0,3}%'| sed s/.$// | tr -d ' ')
}

function getCurSink {
    activeSink=$(pacmd list-sinks | awk '/* index:/{print $3}')
}

function volMuteStatus {
    isMuted=$(pacmd list-sinks | grep -A 15 "index: $activeSink" | awk '/muted/{ print $2}')
}

function getSinkInputs {
    inputArray=$(pacmd list-sink-inputs | grep -B 4 "sink: $1 " | awk '/index:/{print $2}')
}

function volUp {
    getCurVol
    maxLimit=$((MAX_VOL - INC))

    if [ "$curVol" -le "$MAX_VOL" ] && [ "$curVol" -ge "$maxLimit" ]; then
        pactl set-sink-volume "$activeSink" "$MAX_VOL%"
    elif [ "$curVol" -lt "$maxLimit" ]; then
        pactl set-sink-volume "$activeSink" "+$INC%"
    fi

    getCurVol

    if [ ${OSD} = "yes" ]; then
        qdbus org.kde.kded /modules/kosd showVolume "$curVol" 0
    fi

    if [ ${AUTOSYNC} = "yes" ]; then
        volSync
    fi
}

function volDown {
    pactl set-sink-volume "$activeSink" "-$INC%"
    getCurVol

    if [ ${OSD} = "yes" ]; then
        qdbus org.kde.kded /modules/kosd showVolume "$curVol" 0
    fi

    if [ ${AUTOSYNC} = "yes" ]; then
        volSync
    fi
}

function volSync {
    getSinkInputs "$activeSink"
    getCurVol

    for each in $inputArray; do
        pactl set-sink-input-volume "$each" "$curVol%"
    done
}

function volMute {
    case "$1" in
        mute)
            pactl set-sink-mute "$activeSink" 1
            curVol=0
            status=1
            ;;
        unmute)
            pactl set-sink-mute "$activeSink" 0
            getCurVol
            status=0
            ;;
    esac

    if [ ${OSD} = "yes" ]; then
        qdbus org.kde.kded /modules/kosd showVolume ${curVol} ${status}
    fi

}

# Changing the audio device, from 
function changeDevice {
    # Treats pulseaudio sink list to avoid calling pacmd list-sinks twice
    o_pulseaudio=$(pacmd list-sinks| grep -e 'index' -e 'device.description')

    # Gets max sink index
    nSinks=$(echo "$o_pulseaudio" | grep index | cut -d: -f2 | sed '$!d')

    # Gets present default sink index
    activeSink=$(echo "$o_pulseaudio" | grep "\* index" | cut -d: -f2)

    # Sets new sink index, checks that it's not in the blacklist
    newSink=$activeSink
    i=0
    found=0
    while [ $i -le "$nSinks" ] && [ "$found" -ne 1 ]; do
        found=1
        newSink=$((newSink + 1))
        if [ "$newSink" -gt "$nSinks" ]; then newSink=0; fi
        for el in "${SINK_BLACKLIST[@]}"; do
            if [ "$el" -eq "${newSink}" ]; then 
                found=0
                break
            fi
        done
        i=$((i+1))
    done

    # New sink
    pacmd set-default-sink $newSink

    # Moves all audio threads to new sink
    inputs=$(pactl list sink-inputs short | cut -f 1)
    for i in $inputs; do
        pacmd move-sink-input "$i" "$newSink"
    done

    if [ $NOTIFICATIONS = "yes" ]; then
        sendNotification
    fi
}

function sendNotification {
    o_pulseaudio=$(pacmd list-sinks| grep -e 'index' -e 'device.description')
    deviceName=$(echo "$o_pulseaudio" | sed -n '/* index/{n;p;}' | grep -o '".*"' | sed 's/"//g')
    notify-send "Output cycle" "Changed output to ${deviceName}" --icon=audio-headphones-symbolic
}

# Prints output for bar
# Listens for events for fast update speed
function listen {
    firstrun=0

    pactl subscribe 2>/dev/null | {
        while true; do 
            {
                # If this is the first time just continue
                # and print the current state
                # Otherwise wait for events
                # This is to prevent the module being empty until
                # an event occurs
                if [ $firstrun -eq 0 ]
                then
                    firstrun=1
                else
                    read -r event || break
                    if ! echo "$event" | grep -e "on card" -e "on sink" -e "on server"
                    then
                        # Avoid double events
                        continue
                    fi
                fi
            } &>/dev/null
            output
        done
    }
}

function output() {
    getCurSink
    getCurVol
    volMuteStatus

    # Fixed volume icons over max volume
    iconsLen="${#VOLUME_ICONS[@]}"
    if [ "$iconsLen" -ne 0 ]; then
        volSplit=$(( MAX_VOL / iconsLen ))
        for (( i=1; i<=iconsLen; i++ )); do
            if (( i*volSplit >= curVol )); then
                volIcon="${VOLUME_ICONS[$((i-1))]}"
                break
            fi
        done
    else
        volIcon=""
    fi

    # Uses custom sink icon if the array contains one
    sinksLen=${#CUSTOM_SINK_ICONS[@]}
    if [ "$activeSink" -le "$((sinksLen - 1))" ]; then
        sinkIcon=${CUSTOM_SINK_ICONS[$activeSink]}
    else
        sinkIcon=$DEFAULT_SINK_ICON
    fi

    # Showing the formatted message
    if [ "${isMuted}" = "yes" ]; then
        echo "${MUTED_COLOR}${MUTED_ICON}${curVol}%   ${sinkIcon}${activeSink}${endColor}"
    else
        echo "${volIcon}${curVol}%   ${sinkIcon}${activeSink}"
    fi
}


getCurSink
case "$1" in
    --up)
        volUp
        ;;
    --down)
        volDown
        ;;
    --togmute)
        volMuteStatus
        if [ "$isMuted" = "yes" ]
        then
            volMute unmute
        else
            volMute mute
        fi
        ;;
    --mute)
        volMute mute
        ;;
    --unmute)
        volMute unmute
        ;;
    --sync)
        volSync
        ;;
    --listen)
        # Listen for changes and immediately create new output for the bar
        # This is faster than having the script on an interval
        listen
        ;;
    --change)
        # Changes the audio device
        changeDevice
        ;;
    *)
        # By default print output for bar
        output
        ;;
esac
