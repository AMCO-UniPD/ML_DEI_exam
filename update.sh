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
JUPYTER_LOG=$(mktemp)
jupyter lab --no-browser >"$JUPYTER_LOG" 2>&1 &
JUPYTER_PID=$!

echo "Waiting for Jupyter to start..."
JUPYTER_URL=""
for i in $(seq 1 60); do
    JUPYTER_URL=$(grep -oE 'http://127\.0\.0\.1:[0-9]+/lab\?token=[a-f0-9]+' "$JUPYTER_LOG" 2>/dev/null | head -1)
    if [ -n "$JUPYTER_URL" ]; then
        break
    fi
    sleep 1
done
rm -f "$JUPYTER_LOG"

if [ -z "$JUPYTER_URL" ]; then
    echo "Jupyter non ha risposto in tempo. URL non trovato."
    echo "Apri manualmente: http://127.0.0.1:8888"
    wait "$JUPYTER_PID"
    exit 1
fi

echo "Jupyter pronto: $JUPYTER_URL"

# ── Lancia il kiosk ───────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/res/exam-kiosk.py" "$JUPYTER_URL"
KIOSK_EXIT=$?

if [ "$KIOSK_EXIT" -eq 42 ]; then
    # GTK non disponibile — fallback: stampa URL, lascia jupyter in foreground
    echo "Interfaccia grafica non disponibile."
    echo "Apri nel browser: $JUPYTER_URL"
    wait "$JUPYTER_PID"
else
    # Kiosk uscito normalmente — termina jupyter
    kill "$JUPYTER_PID" 2>/dev/null
    wait "$JUPYTER_PID" 2>/dev/null
fi
