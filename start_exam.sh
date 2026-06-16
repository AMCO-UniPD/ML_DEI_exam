#!/bin/bash

SIF=/nfsd/opt/sif-images/ML_notebook_v9.sif
REPO=https://github.com/AMCO-UniPD/ML_DEI_exam.git
REPO_DIR=ML_DEI_exam

NO_GUI=0
for arg in "$@"; do
    [ "$arg" = "--no-gui" ] && NO_GUI=1
done

# ── Codice esame ──────────────────────────────────────────────
read -rp "Codice esame: " EXAM < /dev/tty

# ── Clona il repo ─────────────────────────────────────────────
echo "Scarico materiale d'esame..."
git clone "$REPO" "$REPO_DIR"
cd "$REPO_DIR"

# ── Decritta l'archivio ───────────────────────────────────────
tar_files=(*.tar.gz)
if [ ${#tar_files[@]} -eq 0 ]; then
    echo "Errore: nessun archivio trovato nel repo."
    exit 1
fi
openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d \
    -in "${tar_files[0]}" -pass pass:"$EXAM" | tar -xz -C .
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "Errore: codice esame non valido o archivio corrotto."
    exit 1
fi
rm "${tar_files[0]}"

# ── Materiale extra ───────────────────────────────────────────
echo "Scarico slides..."
curl -fsSL -o ML_exam_slides.tar.xz \
    https://cloud.dei.unipd.it/public.php/dav/files/qiiccDGqZREDbHB \
    && tar -xf ML_exam_slides.tar.xz && rm ML_exam_slides.tar.xz \
    || echo "Avviso: download slides fallito."

echo "Scarico cheat sheet..."
curl -fsSL -o cheat_sheet.pdf \
    https://cloud.dei.unipd.it/public.php/dav/files/RPT9S9jwkkNjicQ/ \
    || echo "Avviso: download cheat sheet fallito."

# ── Avvia Jupyter nel container ───────────────────────────────
echo "Avvio Jupyter..."
JUPYTER_LOG=$(mktemp /tmp/jupyter-XXXXX.log)
singularity exec "$SIF" jupyter lab --no-browser > "$JUPYTER_LOG" 2>&1 &
JUPYTER_PID=$!

# ── Attendi URL con token ─────────────────────────────────────
echo "Attendo Jupyter..."
JUPYTER_URL=""
for i in $(seq 1 60); do
    URL=$(grep -oE 'http://127\.[0-9.]+:[0-9]+/lab\?token=[a-f0-9]+' \
        "$JUPYTER_LOG" 2>/dev/null | head -1)
    if [ -n "$URL" ]; then
        JUPYTER_URL="$URL"
        break
    fi
    sleep 1
done

if [ -z "$JUPYTER_URL" ]; then
    echo "Errore: Jupyter non ha risposto in 60s. Log: $JUPYTER_LOG"
    kill "$JUPYTER_PID" 2>/dev/null
    exit 1
fi

echo "Jupyter pronto: $JUPYTER_URL"

# ── Kiosk o modalità no-gui ───────────────────────────────────
if [ "$NO_GUI" -eq 1 ]; then
    echo ""
    echo "Modalità --no-gui: apri nel browser:"
    echo "  $JUPYTER_URL"
    wait "$JUPYTER_PID"
else
    python3 res/exam-kiosk.py "$JUPYTER_URL"
    KIOSK_EXIT=$?

    if [ "$KIOSK_EXIT" -eq 42 ]; then
        echo ""
        echo "ERRORE: interfaccia grafica non disponibile (GTK/WebKit mancante)."
        echo "Chiama il docente."
    fi
fi

# ── Pulizia ───────────────────────────────────────────────────
kill "$JUPYTER_PID" 2>/dev/null
wait "$JUPYTER_PID" 2>/dev/null
rm -f "$JUPYTER_LOG"
