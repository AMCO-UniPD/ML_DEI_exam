#!/bin/bash

SIF=/nfsd/opt/sif-images/ML_notebook_v9.sif
REPO=https://github.com/AMCO-UniPD/ML_DEI_exam.git
REPO_DIR=ML_DEI_exam

NO_GUI=0
for arg in "$@"; do
    [ "$arg" = "--no-gui" ] && NO_GUI=1
done

# ── Controlla dipendenze ──────────────────────────────────────
if ! command -v singularity &>/dev/null; then
    echo "Errore: 'singularity' non trovato."
    echo "Chiama il docente."
    exit 1
fi

if [ ! -f "$SIF" ]; then
    echo "Errore: immagine Singularity non trovata: $SIF"
    echo "Chiama il docente."
    exit 1
fi

# ── Codice esame ──────────────────────────────────────────────
read -rp "Codice esame: " EXAM < /dev/tty

# ── Clona il repo ─────────────────────────────────────────────
RESTORE_ITEMS=()
if [ -d "$REPO_DIR" ]; then
    BACKUP="${REPO_DIR}_$(date '+%Y-%m-%d-%H:%M:%S')"
    mv "$REPO_DIR" "$BACKUP"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ATTENZIONE: cartella '$REPO_DIR' già esistente."
    echo "  Rinominata in: $BACKUP"
    echo "  Verrà scaricata una nuova copia del materiale."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Contenuto del backup:"
    mapfile -t BACKUP_ENTRIES < <(ls -1 "$BACKUP")
    for i in "${!BACKUP_ENTRIES[@]}"; do
        printf "    [%d] %s\n" "$((i+1))" "${BACKUP_ENTRIES[$i]}"
    done
    echo ""
    read -rp "  Numeri da ripristinare (es: 1 3), Invio per saltare: " RESTORE_INPUT < /dev/tty
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    for idx in $RESTORE_INPUT; do
        if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#BACKUP_ENTRIES[@]}" ]; then
            RESTORE_ITEMS+=("${BACKUP_ENTRIES[$((idx-1))]}")
        fi
    done
fi
echo "Scarico materiale d'esame..."
git clone "$REPO" "$REPO_DIR"
cd "$REPO_DIR"
for item in "${RESTORE_ITEMS[@]}"; do
    cp -r "../$BACKUP/$item" "restored_$item"
    echo "Ripristinato: restored_$item"
done

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

# ── Genera pagina istruzioni (self-contained con immagini base64) ─
README_HTML=$(python3 - << 'PYEOF'
import pathlib, re, base64, tempfile

md = pathlib.Path('README.md').read_text()
lines_out = []
in_code = False

def embed_image(m):
    try:
        data = base64.b64encode(pathlib.Path(m.group(2)).read_bytes()).decode()
        return f'<img src="data:image/png;base64,{data}" alt="{m.group(1)}" style="max-width:100%">'
    except Exception:
        return ''

for line in md.split('\n'):
    if line.startswith('```'):
        lines_out.append('</pre>' if in_code else '<pre>')
        in_code = not in_code
        continue
    if in_code:
        lines_out.append(line.replace('&', '&amp;').replace('<', '&lt;'))
        continue
    line = re.sub(r'!\[([^\]]*)\]\(([^)]+)\)', embed_image, line)
    if line.startswith('# '):     lines_out.append(f'<h1>{line[2:]}</h1>')
    elif line.startswith('## '):  lines_out.append(f'<h2>{line[3:]}</h2>')
    elif line.startswith('### '): lines_out.append(f'<h3>{line[4:]}</h3>')
    elif line.strip() == '':      lines_out.append('<br>')
    else:                         lines_out.append(f'<p>{line}</p>')

page = ('<!DOCTYPE html><html><head><meta charset="utf-8">'
        '<style>body{font-family:sans-serif;max-width:760px;margin:32px auto;'
        'padding:0 20px;line-height:1.6}img{max-width:100%}'
        'pre{background:#f4f4f4;padding:12px;border-radius:4px;overflow-x:auto}'
        '</style></head><body>' + '\n'.join(lines_out) + '</body></html>')

f = tempfile.NamedTemporaryFile(suffix='.html', delete=False, mode='w')
f.write(page)
f.close()
print(f.name)
PYEOF
)

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
    python3 res/exam-kiosk.py "$JUPYTER_URL" "file://$README_HTML"
    KIOSK_EXIT=$?

    if [ "$KIOSK_EXIT" -eq 42 ]; then
        echo ""
        echo "Interfaccia grafica non disponibile (GTK/WebKit mancante)."
        echo "Apri nel browser: $JUPYTER_URL"
        wait "$JUPYTER_PID"
    fi
fi

# ── Pulizia ───────────────────────────────────────────────────
kill "$JUPYTER_PID" 2>/dev/null
wait "$JUPYTER_PID" 2>/dev/null
rm -f "$JUPYTER_LOG" "$README_HTML"
