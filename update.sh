#!/bin/bash

# ── Trova il file tar.gz ───────────────────────────────────────
tar_files=(*.tar.gz)
if [ ${#tar_files[@]} -eq 1 ]; then
    tar_file="${tar_files[0]}"
    echo "Found: $tar_file"
else
    echo "Select a file to extract:"
    select tar_file in "${tar_files[@]}"; do
        if [ -n "$tar_file" ]; then
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
fi

openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d -in "$tar_file" -pass pass:"$EXAM" | tar -xz -C .

if [ $? -eq 0 ]; then
    rm "$tar_file"
else
    echo "Failed to extract the tar file. Please check your password and try again."
    exit 1
fi

# ── Download materiale extra ───────────────────────────────────
echo "Downloading extra material..."
curl -o ML_exam_slides.tar.xz https://cloud.dei.unipd.it/public.php/dav/files/qiiccDGqZREDbHB
if [ $? -eq 0 ]; then
    tar -xf ML_exam_slides.tar.xz
    rm ML_exam_slides.tar.xz
else
    echo "Failed to download slides."
fi

echo "Downloading cheat sheet..."
curl -o cheat_sheet.pdf https://cloud.dei.unipd.it/public.php/dav/files/RPT9S9jwkkNjicQ/

# ── Avvia Jupyter, cattura URL con token ───────────────────────
jupyter lab --no-browser &
JUPYTER_PID=$!

echo "Waiting for Jupyter to start..."
JUPYTER_URL=""
for i in $(seq 1 60); do
    # Use 'jupyter server list' to get the full URL without line-wrapping issues
    RAW=$(jupyter server list 2>/dev/null | grep -oE 'http://127\.[^ ]+' | head -1)
    if [ -n "$RAW" ]; then
        # Normalise: http://127.0.0.1:PORT/?token=TOKEN → .../lab?token=TOKEN
        JUPYTER_URL=$(echo "$RAW" | sed 's|/\?token=|/lab?token=|')
        break
    fi
    sleep 1
done

if [ -z "$JUPYTER_URL" ]; then
    echo "Jupyter non ha risposto in tempo. URL non trovato."
    wait "$JUPYTER_PID"
    exit 1
fi

echo "Jupyter pronto: $JUPYTER_URL"

# ── Lancia il kiosk ───────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIOSK_CMD="python3 '$SCRIPT_DIR/res/exam-kiosk.py' '$JUPYTER_URL'"

if [ -n "$SINGULARITY_CONTAINER" ] || [ -n "$APPTAINER_CONTAINER" ]; then
    # Inside container — GTK not available here, launch kiosk on the host.
    # Try to send the command to the other tmux pane (host shell).
    LAUNCHED=0
    if [ -n "$TMUX" ]; then
        CURRENT_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null)
        OTHER_PANE=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -v "$CURRENT_PANE" | head -1)
        if [ -n "$OTHER_PANE" ]; then
            tmux send-keys -t "$OTHER_PANE" "$KIOSK_CMD" Enter 2>/dev/null && LAUNCHED=1
        fi
    fi

    if [ "$LAUNCHED" -eq 0 ]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Lancia il kiosk sull'host (in un altro terminale):"
        echo "  $KIOSK_CMD"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi

    wait "$JUPYTER_PID"
else
    python3 "$SCRIPT_DIR/res/exam-kiosk.py" "$JUPYTER_URL"
    KIOSK_EXIT=$?

    if [ "$KIOSK_EXIT" -eq 42 ]; then
        echo "Interfaccia grafica non disponibile."
        echo "Apri nel browser: $JUPYTER_URL"
        wait "$JUPYTER_PID"
    else
        kill "$JUPYTER_PID" 2>/dev/null
        wait "$JUPYTER_PID" 2>/dev/null
    fi
fi
