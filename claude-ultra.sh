#!/bin/bash

# =============================================================================
# 🚀 DEV CYCLE ULTRA - Pipeline CI/CD avec Claude AI
# =============================================================================
# Combine les meilleures pratiques de :
# - Script autonome (boucle continue, monitoring quotas, commits auto)
# - SuperClaude (personas experts, evidence-based, réduction tokens)
# - Ralph (détection fin de tâche, rate limiting, fichiers de contrôle)
# =============================================================================

VERSION="1.0.0"
# Version history: 1.0.0 - Initial release with fast mode (unified persona), parallel mode (git worktrees + tmux), persistent mode

set -uo pipefail
# Note: -e removed to allow better error handling in parallel mode

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
LOG_DIR="./logs"
LOG_FILE="$LOG_DIR/dev-cycle-$(date +%Y%m%d).log"
CONTEXT_FILE=".claude-context"

# Fichiers de contrôle style Ralph (@ prefix)
TASK_FILE="TODO.md"                    # Tâches à faire
FIX_PLAN_FILE="@fix_plan.md"           # Plan de correction prioritaire (optionnel)
AGENT_CONFIG_FILE="@AGENT.md"          # Config agent (optionnel)
ARCHITECTURE_FILE="ARCHITECTURE.md"    # Documentation architecture
CURRENT_TASK_FILE="@current_task.md"   # Tâche en cours (généré par PO, lu par les autres)
AGENT_TASK_FILE="@agent-task.md"       # Tâche agent worktree (NE PAS merger vers main)

# Flags Claude
CLAUDE_FLAGS="--dangerously-skip-permissions"

# Rate limiting style Ralph
MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-50}"
CALL_COUNT=0
HOUR_START=$(date +%s)

# Seuils de détection de fin (style Ralph)
MAX_CONSECUTIVE_NO_CHANGES=3
CONSECUTIVE_NO_CHANGES=0

# Mode persistent (ne s'arrête jamais, découpe les grosses tâches automatiquement)
PERSISTENT_MODE="${PERSISTENT_MODE:-false}"

# Mode token-efficient (désactivé par défaut)
TOKEN_EFFICIENT_MODE="${TOKEN_EFFICIENT_MODE:-false}"

# Mode output: verbose (défaut), events (JSON), quiet (minimal)
OUTPUT_MODE="${OUTPUT_MODE:-verbose}"

# Limite de tâches (0 = illimité)
MAX_TASKS="${MAX_TASKS:-0}"

# Fichiers de contrôle events (pour intégration Claude Code)
EVENTS_FILE="@ultra.events.log"
PROGRESS_FILE="@ultra.progress.json"
CONTROL_FILE="@ultra.command"
STATUS_FILE="@ultra.status"
PID_FILE="@ultra.pid"

# -----------------------------------------------------------------------------
# BMAD INTEGRATION (Sprint Status / User Stories)
# -----------------------------------------------------------------------------
BMAD_STATUS_FILE="_bmad-output/implementation-artifacts/sprint-status.yaml"
BMAD_STORIES_DIR="_bmad-output/implementation-artifacts/stories"
BMAD_MODE=false

# -----------------------------------------------------------------------------
# CUSTOMER EXPERIENCE TESTER
# -----------------------------------------------------------------------------
CX_ENABLED="${CX_ENABLED:-true}"
CX_MAX_INTERACTIONS=2
CX_LOG_FILE="$LOG_DIR/cx-tests-$(date +%Y%m%d).log"

# -----------------------------------------------------------------------------
# RISK ASSESSMENT (Catégorisation des stories)
# -----------------------------------------------------------------------------
RISK_ENABLED="${RISK_ENABLED:-true}"
RISK_LOG_FILE="$LOG_DIR/risk-assessment-$(date +%Y%m%d).log"
REVIEW_QUEUE_FILE="@review-queue.md"
# Seuil de risque pour pause/review: LOW, MEDIUM, HIGH, NONE
# NONE = jamais de pause (100% autonome), HIGH = pause seulement pour HIGH
RISK_PAUSE_THRESHOLD="${RISK_PAUSE_THRESHOLD:-NONE}"
# Auto-approve les tâches sous ce seuil (skip CX test pour LOW)
RISK_AUTO_APPROVE="${RISK_AUTO_APPROVE:-LOW}"

# -----------------------------------------------------------------------------
# MODE PARALLÈLE (Git Worktrees)
# -----------------------------------------------------------------------------
PARALLEL_MODE="${PARALLEL_MODE:-false}"
PARALLEL_AGENTS="${PARALLEL_AGENTS:-3}"
RESUME_MODE="${RESUME_MODE:-false}"
WORKTREE_DIR=".worktrees"
SWARM_SESSION="claude-swarm"
AGENT_PIDS=()
MERGE_QUEUE=()

# Couleurs pour les agents
AGENT_COLORS=("31" "32" "33" "34" "35" "36" "91" "92" "93" "94" "95" "96")

# Couleurs ANSI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
RESET='\033[0m'

# -----------------------------------------------------------------------------
# CONFIGURATION QUOTA API (Claude Max)
# -----------------------------------------------------------------------------
QUOTA_WARN_SESSION="${QUOTA_WARN_SESSION:-70}"
QUOTA_STOP_SESSION="${QUOTA_STOP_SESSION:-90}"
QUOTA_WARN_WEEKLY="${QUOTA_WARN_WEEKLY:-80}"
QUOTA_STOP_WEEKLY="${QUOTA_STOP_WEEKLY:-95}"

# Variables de tracking
SESSION_QUOTA_PCT=0
WEEKLY_QUOTA_PCT=0
WEEKLY_OPUS_PCT=0
SESSION_RESET=""
WEEKLY_RESET=""
SESSION_API_CALLS=0
SESSION_INPUT_TOKENS=0
SESSION_OUTPUT_TOKENS=0
SESSION_CACHE_READ_TOKENS=0

# -----------------------------------------------------------------------------
# PERSONAS EXPERTS (Style SuperClaude) + MCP Integration
# -----------------------------------------------------------------------------
# Chaque persona a une expertise spécifique et des règles evidence-based
# MCP disponibles: Context7, Sequential-thinking, Playwright, Chrome DevTools
#
# IMPORTANT: Les personas doivent AGIR, pas demander confirmation !

MCP_TOOLS="
OUTILS MCP DISPONIBLES (utilise-les activement !):
- Context7: Cherche la doc officielle AVANT de coder (Node, React, libs...)
- Sequential-thinking: Pour raisonnement complexe étape par étape
- Playwright: Tests E2E cross-browser (Chromium, Firefox, WebKit)
- Chrome DevTools: Debug performance, DOM, CSS, Network, Console"

# Instructions communes pour éviter les questions
NO_QUESTIONS="
RÈGLE ABSOLUE - PAS DE QUESTIONS:
- Tu es en mode AUTONOME, personne ne répondra à tes questions
- NE JAMAIS demander 'Voulez-vous que je...', 'Souhaitez-vous...', 'Dois-je...'
- NE JAMAIS terminer par une question
- AGIS directement, prends des décisions, implémente
- Si tu as un doute, choisis l'option la plus raisonnable et avance"

PERSONA_MERGER="Tu es un GIT MERGE EXPERT avec 15 ans d'expérience en gestion de conflits.
${MCP_TOOLS}
${NO_QUESTIONS}

UTILISE Sequential-thinking POUR:
- Analyser chaque conflit étape par étape
- Comprendre l'intention de chaque branche
- Planifier la résolution optimale

EXPERTISE:
- Résolution de conflits Git complexes
- Compréhension du contexte métier des changements
- Préservation de l'intégrité du code
- Merge de branches parallèles

TA MISSION:
1. Analyse les fichiers en conflit fournis
2. Comprends l'intention de CHAQUE branche:
   - Que voulait faire la branche A ?
   - Que voulait faire la branche B ?
3. Résous le conflit en:
   - Préservant les deux fonctionnalités si compatibles
   - Choisissant la meilleure implémentation si incompatibles
   - Combinant intelligemment si possible
4. AGIS: Fournis le code résolu SANS marqueurs de conflit

FORMAT DE RÉPONSE:
\`\`\`resolved
[Le code résolu, propre, sans marqueurs <<<<< ===== >>>>>]
\`\`\`

RÈGLES ABSOLUES:
- [CRITICAL] Jamais de marqueurs de conflit dans le résultat
- [CRITICAL] Le code doit compiler/fonctionner
- [CRITICAL] Préserver les tests des deux côtés
- [HIGH] Garder le meilleur des deux implémentations
- [HIGH] Documenter brièvement le choix si significatif"

# -----------------------------------------------------------------------------
# INITIALISATION
# -----------------------------------------------------------------------------
init() {
    mkdir -p "$LOG_DIR"

    # Vérifier qu'on est dans un repo Git (fonctionne aussi dans les worktrees)
    # Dans un worktree, .git est un fichier, pas un dossier
    if [ ! -d ".git" ] && [ ! -f ".git" ]; then
        echo -e "${RED}⚠️  Ce dossier n'est pas un dépôt Git.${RESET}"
        exit 1
    fi

    # Créer les fichiers de contrôle s'ils n'existent pas
    if [ ! -f "$TASK_FILE" ]; then
        echo -e "${YELLOW}⚠️  Création de $TASK_FILE${RESET}"
        cat > "$TASK_FILE" << 'EOF'
# TODO - Tâches du projet

## En cours
- [ ] Tâche exemple à remplacer

## À faire
- [ ] Définir les tâches du projet

## Terminé
EOF
    fi

    if [ ! -f "$ARCHITECTURE_FILE" ]; then
        echo -e "${YELLOW}⚠️  Création de $ARCHITECTURE_FILE${RESET}"
        cat > "$ARCHITECTURE_FILE" << 'EOF'
# Architecture du projet

## Structure
```
src/
├── domain/        # Entities, Value Objects
├── application/   # Use Cases
├── infrastructure/ # Adapters, Repositories
└── presentation/  # Controllers, Views
```

## Principes
- Clean Architecture
- Dependency Injection
- TDD

## Décisions
<!-- ADRs ici -->
EOF
    fi

    echo "" >> "$LOG_FILE"
    echo "===============================================================================" >> "$LOG_FILE"
    echo "--- NOUVELLE SESSION : $(date) ---" >> "$LOG_FILE"
    echo "--- Mode: $([ "$TOKEN_EFFICIENT_MODE" = "true" ] && echo "Token-Efficient" || echo "Standard") ---" >> "$LOG_FILE"
    echo "===============================================================================" >> "$LOG_FILE"

    log_info "Fichiers de contrôle vérifiés"

    # Détecter le mode BMAD
    if [[ -f "$BMAD_STATUS_FILE" ]]; then
        BMAD_MODE=true
        log_info "Mode BMAD détecté (sprint-status.yaml trouvé)"
    fi
}

# -----------------------------------------------------------------------------
# BMAD FUNCTIONS - Gestion des User Stories
# -----------------------------------------------------------------------------

# Compte le nombre de stories BMAD en backlog ou ready-for-dev
get_bmad_pending_count() {
    if [[ ! -f "$BMAD_STATUS_FILE" ]]; then
        echo "0"
        return
    fi

    # Compte les lignes qui matchent: "  X-Y-story-name: backlog" ou "ready-for-dev"
    local count
    count=$(grep -cE "^\s+[0-9]+-[0-9]+-.*:\s*(backlog|ready-for-dev)" "$BMAD_STATUS_FILE" 2>/dev/null || echo "0")
    echo "$count"
}

# Retourne l'ID de la prochaine story BMAD (ex: "3-2")
get_next_bmad_story_id() {
    if [[ ! -f "$BMAD_STATUS_FILE" ]]; then
        return 1
    fi

    # Trouve la première story en backlog ou ready-for-dev
    local next_line
    next_line=$(grep -E "^\s+[0-9]+-[0-9]+-.*:\s*(backlog|ready-for-dev)" "$BMAD_STATUS_FILE" | head -1)

    if [[ -z "$next_line" ]]; then
        return 1
    fi

    # Extrait l'ID (ex: "3-2" de "  3-2-email-content-reader: backlog")
    # Utilise awk pour une meilleure compatibilité macOS/Linux
    echo "$next_line" | awk -F'[-:]' '{gsub(/^[[:space:]]+/, "", $1); print $1"-"$2}'
}

# Retourne le nom complet de la story (ex: "3-2-email-content-reader")
get_next_bmad_story_name() {
    if [[ ! -f "$BMAD_STATUS_FILE" ]]; then
        return 1
    fi

    local next_line
    next_line=$(grep -E "^\s+[0-9]+-[0-9]+-.*:\s*(backlog|ready-for-dev)" "$BMAD_STATUS_FILE" | head -1)

    if [[ -z "$next_line" ]]; then
        return 1
    fi

    # Extrait le nom complet (ex: "3-2-email-content-reader")
    # Utilise awk pour une meilleure compatibilité macOS/Linux
    echo "$next_line" | awk -F':' '{gsub(/^[[:space:]]+/, "", $1); print $1}'
}

# Compte le total des tâches pendantes (TODO.md + BMAD)
get_total_pending_tasks() {
    local todo_count=0
    local bmad_count=0

    # Compter les tâches TODO.md
    if [[ -f "$TASK_FILE" ]]; then
        todo_count=$(grep -c "^\s*- \[ \]" "$TASK_FILE" 2>/dev/null || echo "0")
    fi

    # Compter les stories BMAD si TODO.md est vide
    if [[ "$todo_count" -eq 0 && "$BMAD_MODE" == "true" ]]; then
        bmad_count=$(get_bmad_pending_count)
    fi

    echo $((todo_count + bmad_count))
}

# Vérifie si on doit utiliser BMAD (TODO.md vide et stories disponibles)
should_use_bmad() {
    if [[ "$BMAD_MODE" != "true" ]]; then
        return 1
    fi

    # Vérifier si TODO.md a des tâches pendantes
    local todo_count=0
    if [[ -f "$TASK_FILE" ]]; then
        todo_count=$(grep -c "^\s*- \[ \]" "$TASK_FILE" 2>/dev/null || echo "0")
    fi

    # Si TODO.md vide, vérifier BMAD
    if [[ "$todo_count" -eq 0 ]]; then
        local bmad_count
        bmad_count=$(get_bmad_pending_count)
        if [[ "$bmad_count" -gt 0 ]]; then
            return 0  # Utiliser BMAD
        fi
    fi

    return 1  # Ne pas utiliser BMAD
}

# -----------------------------------------------------------------------------
# FONCTIONS D'AFFICHAGE
# -----------------------------------------------------------------------------
clear_line() {
    echo -ne "\033[2K\r"
}

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

log_info() {
    log "INFO" "$1"
    echo -e "${GRAY}[$(date '+%H:%M:%S')]${RESET} ${CYAN}ℹ${RESET}  $1"
}

log_success() {
    log "SUCCESS" "$1"
    echo -e "${GRAY}[$(date '+%H:%M:%S')]${RESET} ${GREEN}✓${RESET}  $1"
}

log_error() {
    log "ERROR" "$1"
    echo -e "${GRAY}[$(date '+%H:%M:%S')]${RESET} ${RED}✗${RESET}  $1"
}

log_detail() {
    log "DETAIL" "$1"
    echo -e "${GRAY}[$(date '+%H:%M:%S')]     └─ $1${RESET}"
}

# Appel Claude avec timeout (pour appels auxiliaires: validation, commit msg, etc.)
# Usage: claude_with_timeout TIMEOUT_SECONDS "prompt"
# Retourne: stdout du résultat, code retour 0=ok, 1=timeout/erreur
# Compatible macOS et Linux
claude_with_timeout() {
    local timeout_secs="${1:-$CLAUDE_AUX_TIMEOUT}"
    local prompt="$2"

    local tmp_output
    tmp_output=$(mktemp)
    local exit_code=0

    # Lancer Claude en background avec redirection vers fichier temp
    claude -p $CLAUDE_FLAGS --output-format text "$prompt" > "$tmp_output" 2>/dev/null &
    local pid=$!

    # Attendre avec timeout (compatible macOS et Linux)
    local waited=0
    while kill -0 $pid 2>/dev/null; do
        if [ $waited -ge "$timeout_secs" ]; then
            # Timeout atteint - tuer le processus
            kill -9 $pid 2>/dev/null || true
            wait $pid 2>/dev/null || true
            rm -f "$tmp_output"
            log_info "Claude timeout après ${timeout_secs}s"
            return 1
        fi
        sleep 1
        ((waited++))
    done

    # Récupérer le code de sortie
    wait $pid 2>/dev/null
    exit_code=$?

    # Lire le résultat
    local result=""
    if [ -f "$tmp_output" ]; then
        result=$(cat "$tmp_output")
        rm -f "$tmp_output"
    fi

    echo "$result"
    return $exit_code
}

# -----------------------------------------------------------------------------
# SYSTÈME D'ÉVÉNEMENTS (Pour intégration Claude Code)
# -----------------------------------------------------------------------------
# Émet un événement JSON pour le skill /ultra
# Usage: emit_event TYPE key1=val1 key2=val2 ...
emit_event() {
    [[ "$OUTPUT_MODE" != "events" ]] && return 0

    local event_type="$1"
    shift

    local timestamp
    timestamp=$(date -Iseconds)

    # Construire le JSON avec les paires key=value
    local json_data="{\"type\":\"$event_type\",\"ts\":\"$timestamp\""

    for arg in "$@"; do
        local key="${arg%%=*}"
        local value="${arg#*=}"
        # Échapper les guillemets dans la valeur
        value="${value//\"/\\\"}"
        json_data="$json_data,\"$key\":\"$value\""
    done

    json_data="$json_data}"

    # Écrire dans le fichier events et stdout
    echo "$json_data" >> "$EVENTS_FILE"
    echo "EVENT:$json_data"
}

# Écrit l'état de progression dans un fichier JSON
write_progress() {
    local round="${1:-0}"
    local step="${2:-}"
    local task="${3:-}"
    local status="${4:-running}"

    # Utilise la fonction qui compte TODO.md + BMAD si vide
    local pending_tasks
    pending_tasks=$(get_total_pending_tasks)

    local elapsed=0
    [[ -n "${START_TIME:-}" ]] && elapsed=$(($(date +%s) - START_TIME))

    cat > "$PROGRESS_FILE" << EOF
{
  "status": "$status",
  "round": $round,
  "step": "$step",
  "task": "$task",
  "pending_tasks": $pending_tasks,
  "session_tokens": ${SESSION_INPUT_TOKENS:-0},
  "session_output_tokens": ${SESSION_OUTPUT_TOKENS:-0},
  "elapsed_seconds": $elapsed,
  "timestamp": "$(date -Iseconds)"
}
EOF
}

# Vérifie les commandes de contrôle (pause, stop)
check_control_commands() {
    [[ ! -f "$CONTROL_FILE" ]] && return 0

    local cmd
    cmd=$(cat "$CONTROL_FILE")
    rm -f "$CONTROL_FILE"

    case "$cmd" in
        stop)
            emit_event "STOP_REQUESTED"
            echo "stopped" > "$STATUS_FILE"
            log_info "Arrêt demandé via fichier de contrôle"
            write_progress "${round:-0}" "" "" "stopped"
            exit 0
            ;;
        pause)
            emit_event "PAUSED"
            echo "paused" > "$STATUS_FILE"
            log_info "Pause demandée - en attente de 'resume'"
            while [[ ! -f "$CONTROL_FILE" ]] || [[ "$(cat "$CONTROL_FILE" 2>/dev/null)" != "resume" ]]; do
                sleep 2
            done
            rm -f "$CONTROL_FILE"
            emit_event "RESUMED"
            echo "running" > "$STATUS_FILE"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# RATE LIMITING (Style Ralph)
# -----------------------------------------------------------------------------
check_rate_limit() {
    local now=$(date +%s)
    local elapsed=$((now - HOUR_START))
    
    # Reset toutes les heures
    if [ $elapsed -ge 3600 ]; then
        CALL_COUNT=0
        HOUR_START=$now
        log_info "Rate limit reset (nouvelle heure)"
    fi
    
    if [ $CALL_COUNT -ge $MAX_CALLS_PER_HOUR ]; then
        local wait_time=$((3600 - elapsed))
        echo -e "${YELLOW}⏳ Rate limit atteint ($CALL_COUNT/$MAX_CALLS_PER_HOUR). Attente ${wait_time}s...${RESET}"
        log_info "Rate limit: attente ${wait_time}s"
        sleep $wait_time
        CALL_COUNT=0
        HOUR_START=$(date +%s)
    fi
    
    ((CALL_COUNT++))
}

# -----------------------------------------------------------------------------
# DÉTECTION FIN DE TÂCHE (Style Ralph)
# -----------------------------------------------------------------------------
check_task_completion() {
    # Vérifie si toutes les tâches sont terminées (TODO.md + BMAD)
    local total_pending
    total_pending=$(get_total_pending_tasks)

    if [ "$total_pending" -eq 0 ]; then
        echo -e "${GREEN}🎉 Toutes les tâches sont terminées !${RESET}"
        log_success "Toutes les tâches complétées (TODO.md + BMAD)"
        return 0
    fi
    return 1
}

detect_no_changes() {
    # En mode persistent, ne jamais s'arrêter automatiquement
    if [ "$PERSISTENT_MODE" = "true" ]; then
        return 1
    fi

    # Vérifie s'il y a eu des changements git
    if git diff --quiet && git diff --cached --quiet; then
        ((CONSECUTIVE_NO_CHANGES++))
        log_info "Pas de changements détectés ($CONSECUTIVE_NO_CHANGES/$MAX_CONSECUTIVE_NO_CHANGES)"

        if [ $CONSECUTIVE_NO_CHANGES -ge $MAX_CONSECUTIVE_NO_CHANGES ]; then
            # Vérifier s'il reste des tâches pendantes avant d'arrêter (TODO.md + BMAD)
            local pending_tasks
            pending_tasks=$(get_total_pending_tasks)

            if [ "$pending_tasks" -gt 0 ]; then
                local source="TODO.md"
                should_use_bmad && source="BMAD"
                log_info "Pas de changements mais $pending_tasks tâche(s) restante(s) ($source) - on continue"
                echo -e "${YELLOW}⚠️  $MAX_CONSECUTIVE_NO_CHANGES cycles sans changements mais $pending_tasks tâche(s) restante(s) ($source)${RESET}"
                # Reset le compteur pour donner une autre chance
                CONSECUTIVE_NO_CHANGES=0
                return 1
            fi

            echo -e "${YELLOW}⚠️  $MAX_CONSECUTIVE_NO_CHANGES cycles sans changements - arrêt intelligent${RESET}"
            log_info "Arrêt intelligent: pas de changements"
            return 0
        fi
    else
        CONSECUTIVE_NO_CHANGES=0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# GESTION DES QUOTAS (OAuth API)
# -----------------------------------------------------------------------------
get_oauth_token() {
    local creds
    creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    if [ -z "$creds" ]; then
        return 1
    fi
    echo "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null
}

fetch_usage_quotas() {
    local token
    token=$(get_oauth_token)
    
    if [ -z "$token" ]; then
        return 1
    fi
    
    local response
    response=$(curl -s "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" \
        2>/dev/null)
    
    if [ -z "$response" ]; then
        return 1
    fi
    
    SESSION_QUOTA_PCT=$(echo "$response" | jq -r '.five_hour.utilization // 0' 2>/dev/null | cut -d'.' -f1)
    WEEKLY_QUOTA_PCT=$(echo "$response" | jq -r '.seven_day.utilization // 0' 2>/dev/null | cut -d'.' -f1)
    WEEKLY_OPUS_PCT=$(echo "$response" | jq -r '.seven_day_opus.utilization // 0' 2>/dev/null | cut -d'.' -f1)
    
    local session_reset_raw weekly_reset_raw
    session_reset_raw=$(echo "$response" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)
    weekly_reset_raw=$(echo "$response" | jq -r '.seven_day.resets_at // empty' 2>/dev/null)
    
    if [ -n "$session_reset_raw" ]; then
        SESSION_RESET=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${session_reset_raw%%.*}" "+%Hh%M" 2>/dev/null || echo "")
    fi
    if [ -n "$weekly_reset_raw" ]; then
        WEEKLY_RESET=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${weekly_reset_raw%%.*}" "+%a %d" 2>/dev/null || echo "")
    fi
    
    return 0
}

check_quota() {
    if ! fetch_usage_quotas; then
        return 0
    fi
    
    if [ "$SESSION_QUOTA_PCT" -ge "$QUOTA_STOP_SESSION" ]; then
        echo -e "${RED}🛑 QUOTA SESSION CRITIQUE (${SESSION_QUOTA_PCT}%)${RESET}"
        return 1
    elif [ "$SESSION_QUOTA_PCT" -ge "$QUOTA_WARN_SESSION" ]; then
        echo -e "${YELLOW}⚠️  Quota session: ${SESSION_QUOTA_PCT}%${RESET}"
    fi
    
    if [ "$WEEKLY_QUOTA_PCT" -ge "$QUOTA_STOP_WEEKLY" ]; then
        echo -e "${RED}🛑 QUOTA HEBDO CRITIQUE (${WEEKLY_QUOTA_PCT}%)${RESET}"
        return 1
    elif [ "$WEEKLY_QUOTA_PCT" -ge "$QUOTA_WARN_WEEKLY" ]; then
        echo -e "${YELLOW}⚠️  Quota hebdo: ${WEEKLY_QUOTA_PCT}%${RESET}"
    fi
    
    return 0
}

update_usage_from_result() {
    local json_line="$1"
    local input_tokens output_tokens cache_read
    input_tokens=$(echo "$json_line" | jq -r '.usage.input_tokens // 0' 2>/dev/null)
    output_tokens=$(echo "$json_line" | jq -r '.usage.output_tokens // 0' 2>/dev/null)
    cache_read=$(echo "$json_line" | jq -r '.usage.cache_read_input_tokens // 0' 2>/dev/null)
    
    SESSION_INPUT_TOKENS=$((SESSION_INPUT_TOKENS + input_tokens))
    SESSION_OUTPUT_TOKENS=$((SESSION_OUTPUT_TOKENS + output_tokens))
    SESSION_CACHE_READ_TOKENS=$((SESSION_CACHE_READ_TOKENS + cache_read))
    ((SESSION_API_CALLS++))
}

build_progress_bar() {
    local pct="$1"
    local width="${2:-25}"
    local bar=""
    local filled=$((pct * width / 100))
    
    for ((i=0; i<width; i++)); do
        if [ $i -lt $filled ]; then
            if [ "$pct" -ge 80 ]; then
                bar+="${RED}█${RESET}"
            elif [ "$pct" -ge 50 ]; then
                bar+="${YELLOW}█${RESET}"
            else
                bar+="${GREEN}█${RESET}"
            fi
        else
            bar+="░"
        fi
    done
    echo -e "$bar"
}

draw_usage_dashboard() {
    fetch_usage_quotas
    
    local session_bar weekly_bar
    session_bar=$(build_progress_bar "$SESSION_QUOTA_PCT" 20)
    weekly_bar=$(build_progress_bar "$WEEKLY_QUOTA_PCT" 20)
    
    local total_tokens=$((SESSION_INPUT_TOKENS + SESSION_OUTPUT_TOKENS))
    local rate_pct=$((CALL_COUNT * 100 / MAX_CALLS_PER_HOUR))
    
    echo ""
    echo -e "${BOLD}┌─────────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${BOLD}│${RESET}  📊 ${BOLD}MONITORING${RESET}                                                  ${BOLD}│${RESET}"
    echo -e "${BOLD}├─────────────────────────────────────────────────────────────────┤${RESET}"
    printf "${BOLD}│${RESET}  ⏱️  Session (5h):  ${session_bar} %3d%% ${GRAY}Reset: ${SESSION_RESET:-?}${RESET}   ${BOLD}│${RESET}\n" "$SESSION_QUOTA_PCT"
    printf "${BOLD}│${RESET}  📅 Hebdo (7j):    ${weekly_bar} %3d%% ${GRAY}Reset: ${WEEKLY_RESET:-?}${RESET}  ${BOLD}│${RESET}\n" "$WEEKLY_QUOTA_PCT"
    echo -e "${BOLD}├─────────────────────────────────────────────────────────────────┤${RESET}"
    echo -e "${BOLD}│${RESET}  🔄 Rate: ${CALL_COUNT}/${MAX_CALLS_PER_HOUR}/h | 📈 Tokens: ${total_tokens} | 🧠 Calls: ${SESSION_API_CALLS}    ${BOLD}│${RESET}"
    echo -e "${BOLD}│${RESET}  🎯 Sans changement: ${CONSECUTIVE_NO_CHANGES}/${MAX_CONSECUTIVE_NO_CHANGES}                                  ${BOLD}│${RESET}"
    echo -e "${BOLD}└─────────────────────────────────────────────────────────────────┘${RESET}"
}

# -----------------------------------------------------------------------------
# BARRE DE PROGRESSION
# -----------------------------------------------------------------------------
draw_progress_bar() {
    local current_step="$1"
    local step_name="$2"
    local status="${3:-running}"
    
    local bar_width=40
    local filled=$((current_step * bar_width / TOTAL_STEPS))
    local empty=$((bar_width - filled))
    local percentage=$((current_step * 100 / TOTAL_STEPS))
    
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    
    local status_color
    case "$status" in
        "running") status_color="$YELLOW" ;;
        "success") status_color="$GREEN" ;;
        "error")   status_color="$RED" ;;
        *)         status_color="$RESET" ;;
    esac
    
    echo ""
    echo -e "${BOLD}┌────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${BOLD}│${RESET} ${status_color}${bar}${RESET} ${BOLD}${percentage}%${RESET} │"
    echo -e "${BOLD}│${RESET} ${STEP_ICONS[$((current_step-1))]}  ${step_name}$(printf '%*s' $((35 - ${#step_name})) '')${BOLD}│${RESET}"
    echo -e "${BOLD}└────────────────────────────────────────────────────────┘${RESET}"
}

draw_cycle_header() {
    local round="$1"
    echo ""
    echo -e "${BOLD}${MAGENTA}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                                                          ║"
    printf "║   🔄 CYCLE #%-3d                                         ║\n" "$round"
    echo "║   $(date '+%Y-%m-%d %H:%M:%S')                              ║"
    echo "║                                                          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

draw_steps_overview() {
    local current="$1"
    echo -e "${GRAY}Pipeline:${RESET}"
    local line=""
    for i in "${!STEPS[@]}"; do
        local step_num=$((i + 1))
        local icon="${STEP_ICONS[$i]}"
        
        if [ "$step_num" -lt "$current" ]; then
            line+="${GREEN}${icon}${RESET} → "
        elif [ "$step_num" -eq "$current" ]; then
            line+="${YELLOW}[${icon}]${RESET} → "
        else
            line+="${GRAY}${icon}${RESET} → "
        fi
    done
    echo -e "  ${line%% → }"
    echo ""
}

# -----------------------------------------------------------------------------
# MODE FAST - Prompt unifié (1 appel = 1 tâche complète)
# -----------------------------------------------------------------------------
FAST_PROMPT="Tu es un DÉVELOPPEUR SENIOR AUTONOME avec expertise full-stack et DevOps.
${MCP_TOOLS}
${NO_QUESTIONS}

MISSION: Implémente UNE SEULE tâche du projet en suivant ce workflow complet.

WORKFLOW EN 6 ÉTAPES:

1. SÉLECTION (PO)
   - Lis $TASK_FILE et choisis UNE tâche non terminée (- [ ])
   - Privilégie les quick wins à fort impact
   - La tâche doit être faisable en <30 min

   DÉCOUPAGE AUTOMATIQUE (si aucun quick win):
   - Si TOUTES les tâches restantes sont trop grosses (>30 min estimées)
   - Découpe la première tâche en 3-5 sous-tâches atomiques
   - Ajoute les sous-tâches au $TASK_FILE avec indentation:
     - [ ] Grosse tâche (DÉCOMPOSÉE)
       - [ ] Sous-tâche 1
       - [ ] Sous-tâche 2
   - Ensuite, sélectionne et implémente la première sous-tâche

2. IMPLÉMENTATION (TDD)
   - Écris d'abord le test qui échoue (RED)
   - Écris le code minimal pour passer (GREEN)
   - Fonctions pures, early return, max 20 lignes/fonction
   - Pas de commentaires, code auto-documenté
   - MOCK OBLIGATOIRE: mock toutes les connexions externes (DB, API, services)

3. QUALITÉ
   - Lance les tests existants
   - Vérifie les edge cases: null, undefined, empty, erreurs
   - Ajoute les tests manquants
   - Les tests doivent tourner SANS connexion DB/réseau (tout mocké)

4. SÉCURITÉ (OWASP Top 10)
   - Jamais de secrets en dur
   - Valider/sanitizer tous les inputs
   - Escape output selon contexte

5. DOCUMENTATION
   - Marque la tâche terminée: - [x] tâche ($(date +%Y-%m-%d))
   - Mets à jour $ARCHITECTURE_FILE si choix architectural

6. COMMIT
   - git add des fichiers modifiés
   - Commit avec message conventionnel: type(scope): description

RÈGLES ABSOLUES:
- [CRITICAL] UNE SEULE tâche par exécution
- [CRITICAL] AGIS directement, pas de questions
- [CRITICAL] Si blocage, passe à une autre tâche
- [HIGH] TDD strict: test first
- [HIGH] Commit à la fin si changements"

# -----------------------------------------------------------------------------
# CUSTOMER EXPERIENCE TESTER PROMPT
# -----------------------------------------------------------------------------
CX_TESTER_PROMPT="Tu es un TESTEUR D'EXPÉRIENCE UTILISATEUR lambda (pas technique).
Tu testes comme un vrai utilisateur qui découvre la fonctionnalité.

CONTEXTE:
- Tâche implémentée: %TASK%
- Changements effectués:
%DIFF%

TON RÔLE:
1. Te mettre dans la peau d'un utilisateur ordinaire
2. Évaluer si l'implémentation est intuitive et utilisable
3. Identifier les friction points potentiels

ÉVALUATION (1 seule question ou action de test):
- Pose UNE question concrète sur l'usage OU
- Simule UNE action utilisateur typique

APRÈS TA QUESTION/ACTION, TU DOIS CONCLURE:
- Si ça semble OK → Réponds exactement: CX_RESULT:PASS
- Si problème UX détecté → Réponds exactement: CX_RESULT:FAIL|<raison courte>

FORMAT OBLIGATOIRE DE RÉPONSE:
<question ou simulation d'action>

CX_RESULT:PASS ou CX_RESULT:FAIL|raison"

# -----------------------------------------------------------------------------
# RISK ASSESSOR PROMPT
# -----------------------------------------------------------------------------
RISK_ASSESSOR_PROMPT="Tu es un ÉVALUATEUR DE RISQUE pour le développement logiciel.
Analyse la tâche et les changements pour déterminer le niveau de risque.

TÂCHE: %TASK%

CHANGEMENTS:
%DIFF%

FICHIERS MODIFIÉS:
%FILES%

CRITÈRES D'ÉVALUATION:

🟢 RISQUE FAIBLE (LOW):
- Modifications mineures (typos, formatting, comments)
- Patterns établis et répétitifs
- Tests unitaires simples
- Documentation/README
- Refactoring local sans changement de comportement
- Ajout de logs/metrics

🟡 RISQUE MOYEN (MEDIUM):
- Nouvelles fonctionnalités simples et isolées
- Modifications de logique métier existante
- Ajout de validations/vérifications
- Nouveaux endpoints API simples
- Intégration de services externes avec SDK standard

🔴 RISQUE ÉLEVÉ (HIGH):
- Nouvelles architectures ou patterns
- Modifications de sécurité (auth, permissions, crypto)
- Changements de schéma DB ou migrations
- Code touchant aux paiements/transactions
- Modifications multi-fichiers avec couplage fort
- Edge cases complexes ou gestion d'erreurs critiques
- Code concurrent/parallèle
- Suppression de fonctionnalités existantes

RÉPONDS EXACTEMENT AVEC CE FORMAT:
RISK_LEVEL:<LOW|MEDIUM|HIGH>
RISK_REASON:<explication en 1 ligne>
REVIEW_NEEDED:<true|false>
REVIEW_FOCUS:<si review needed, quoi vérifier>"

# Fonction pour construire le prompt fast avec contexte
build_fast_prompt() {
    local context=""
    local fix_plan=""
    local agent_config=""
    local current_task=""
    local tasks=""
    local bmad_instruction=""

    # Charger le contexte local
    if [ -f "$CONTEXT_FILE" ]; then
        context="
CONTEXTE PROJET:
$(cat "$CONTEXT_FILE")"
    fi

    # Charger le fix_plan prioritaire
    if [ -f "$FIX_PLAN_FILE" ]; then
        fix_plan="
PLAN DE CORRECTION PRIORITAIRE (traite en premier!):
$(cat "$FIX_PLAN_FILE")"
    fi

    # Charger la config agent
    if [ -f "$AGENT_CONFIG_FILE" ]; then
        agent_config="
CONFIGURATION:
$(cat "$AGENT_CONFIG_FILE")"
    fi

    # Charger la tâche en cours si elle existe
    if [ -f "$CURRENT_TASK_FILE" ]; then
        current_task="
TÂCHE EN COURS (continue celle-ci!):
$(cat "$CURRENT_TASK_FILE")"
    fi

    # Vérifier si on doit utiliser BMAD (TODO.md vide mais stories disponibles)
    if should_use_bmad; then
        local story_id
        local story_name
        story_id=$(get_next_bmad_story_id)
        story_name=$(get_next_bmad_story_name)

        # Afficher dans les logs
        log_info "Mode BMAD: prochaine story $story_id ($story_name)"
        echo -e "${CYAN}📋 Mode BMAD: Story $story_id${RESET}" >&2

        # Charger le contenu de la story si le fichier existe
        local story_file="$BMAD_STORIES_DIR/${story_name}.md"
        local story_content=""
        if [[ -f "$story_file" ]]; then
            story_content="
STORY FILE CONTENT:
$(cat "$story_file")"
        fi

        bmad_instruction="
═══════════════════════════════════════════════════════════════════
📋 MODE BMAD ACTIVÉ - Implémentation User Story
═══════════════════════════════════════════════════════════════════

INSTRUCTION PRINCIPALE:
Exécute la commande /dev-story $story_id pour implémenter cette User Story.

STORY À IMPLÉMENTER: $story_name
STORY ID: $story_id
${story_content}

PROCESSUS:
1. Utilise /dev-story $story_id pour charger le workflow BMAD
2. Suis les acceptance criteria de la story
3. Implémente le code nécessaire
4. Écris les tests
5. Commit avec un message approprié
6. Met à jour le sprint-status.yaml quand terminé

IMPORTANT: Utilise le skill /dev-story, ne fais PAS l'implémentation manuellement !
"
    else
        # Mode classique: Liste des tâches TODO.md
        if [ -f "$TASK_FILE" ]; then
            tasks="
TÂCHES DISPONIBLES ($TASK_FILE):
$(cat "$TASK_FILE")"
        fi
    fi

    echo "${FAST_PROMPT}
${context}
${fix_plan}
${agent_config}
${current_task}
${tasks}
${bmad_instruction}

AGIS MAINTENANT. Choisis une tâche et implémente-la complètement."
}

# -----------------------------------------------------------------------------
# CUSTOMER EXPERIENCE TESTER - Fonction de test UX
# -----------------------------------------------------------------------------
run_cx_test() {
    local task_name="$1"
    local diff_summary="$2"
    local loop_num="$3"

    # Skip si CX désactivé
    if [[ "$CX_ENABLED" != "true" ]]; then
        return 0
    fi

    echo -e "${CYAN}🧪 Test Expérience Client...${RESET}"

    # Construire le prompt CX avec le contexte
    local cx_prompt="${CX_TESTER_PROMPT}"
    cx_prompt="${cx_prompt//%TASK%/$task_name}"
    cx_prompt="${cx_prompt//%DIFF%/$diff_summary}"

    # Timestamp pour le log
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local cx_log_entry="
================================================================================
[CX TEST] $timestamp | Loop #$loop_num | Task: $task_name
================================================================================
"

    local interaction=0
    local cx_result="PENDING"
    local cx_reason=""
    local full_response=""

    while [[ $interaction -lt $CX_MAX_INTERACTIONS && "$cx_result" == "PENDING" ]]; do
        ((interaction++))

        echo -e "  ${GRAY}│ Interaction $interaction/$CX_MAX_INTERACTIONS${RESET}"

        # Appel Claude avec timeout court (60s)
        local response=""
        response=$(claude_with_timeout 60 "$cx_prompt" 2>/dev/null)

        if [ -z "$response" ]; then
            echo -e "  ${YELLOW}│ Pas de réponse CX (timeout)${RESET}"
            cx_log_entry+="[Interaction $interaction] TIMEOUT - pas de réponse
"
            break
        fi

        full_response+="[Interaction $interaction]
$response
"

        # Afficher la question/action du testeur
        local question_part=$(echo "$response" | grep -v "CX_RESULT:" | head -5)
        if [ -n "$question_part" ]; then
            echo -e "  ${MAGENTA}│ 🧑 CX:${RESET} $(echo "$question_part" | head -1)"
        fi

        # Extraire le résultat CX
        if echo "$response" | grep -q "CX_RESULT:PASS"; then
            cx_result="PASS"
            echo -e "  ${GREEN}│ ✓ Test CX: PASS${RESET}"
        elif echo "$response" | grep -q "CX_RESULT:FAIL"; then
            cx_result="FAIL"
            cx_reason=$(echo "$response" | grep "CX_RESULT:FAIL" | sed 's/.*CX_RESULT:FAIL|\?//' | head -1)
            echo -e "  ${RED}│ ✗ Test CX: FAIL - $cx_reason${RESET}"
        else
            # Pas de résultat clair, on continue l'interaction
            cx_prompt="L'utilisateur répond: OK, continue ton test.

Maintenant tu DOIS conclure:
CX_RESULT:PASS ou CX_RESULT:FAIL|raison"
        fi
    done

    # Si toujours PENDING après max interactions, considérer comme PASS (bénéfice du doute)
    if [[ "$cx_result" == "PENDING" ]]; then
        cx_result="PASS"
        cx_reason="Max interactions atteint - bénéfice du doute"
        echo -e "  ${YELLOW}│ Test CX: PASS (par défaut après $CX_MAX_INTERACTIONS interactions)${RESET}"
    fi

    # Logger le résultat
    cx_log_entry+="$full_response
--- RÉSULTAT ---
Status: $cx_result
Raison: ${cx_reason:-N/A}
Interactions: $interaction
"

    # Écrire dans le log CX
    mkdir -p "$LOG_DIR"
    echo "$cx_log_entry" >> "$CX_LOG_FILE"

    # Émettre l'événement
    emit_event "CX_TEST" "loop=$loop_num" "task=$task_name" "result=$cx_result" "interactions=$interaction"

    # Si FAIL, marquer la tâche comme échouée dans TODO.md
    if [[ "$cx_result" == "FAIL" ]]; then
        mark_task_cx_failed "$task_name" "$cx_reason"
        return 1
    fi

    return 0
}

# Marquer une tâche comme échouée au test CX dans TODO.md
mark_task_cx_failed() {
    local task_name="$1"
    local reason="$2"

    if [[ ! -f "$TASK_FILE" ]]; then
        return
    fi

    # Chercher la tâche et ajouter le statut CX_FAIL
    # On cherche la ligne avec [x] et le nom de la tâche
    local escaped_task=$(echo "$task_name" | sed 's/[\/&]/\\&/g')
    local fail_marker="[CX_FAIL: $reason]"

    # Ajouter le marqueur à la fin de la ligne de la tâche
    if grep -q "\[x\].*$escaped_task" "$TASK_FILE" 2>/dev/null; then
        sed -i.bak "s/\(\[x\].*$escaped_task.*\)/\1 $fail_marker/" "$TASK_FILE"
        rm -f "$TASK_FILE.bak"
        log_info "Tâche marquée CX_FAIL: $task_name - $reason"
        echo -e "  ${RED}│ 📝 Tâche marquée [CX_FAIL] dans $TASK_FILE${RESET}"
    fi
}

# -----------------------------------------------------------------------------
# RISK ASSESSMENT - Évaluation du risque des tâches
# -----------------------------------------------------------------------------

# Initialiser le fichier de review queue si nécessaire
init_review_queue() {
    if [[ ! -f "$REVIEW_QUEUE_FILE" ]]; then
        cat > "$REVIEW_QUEUE_FILE" << 'EOF'
# Review Queue - Tâches nécessitant une review humaine

> Ce fichier est généré automatiquement par Claude Ultra.
> Les tâches à haut risque sont ajoutées ici pour review.

## Légende
- 🔴 HIGH - Review approfondie requise
- 🟡 MEDIUM - Review standard recommandée
- ⏳ En attente de review
- ✅ Reviewée et approuvée
- ❌ Reviewée et rejetée

---

## En attente de review

EOF
    fi
}

# Évaluer le risque d'une tâche
assess_task_risk() {
    local task_name="$1"
    local diff_summary="$2"
    local files_changed="$3"
    local loop_num="$4"

    # Skip si désactivé
    if [[ "$RISK_ENABLED" != "true" ]]; then
        echo "LOW"
        return 0
    fi

    echo -e "${CYAN}📊 Évaluation du risque...${RESET}"

    # Construire le prompt
    local risk_prompt="${RISK_ASSESSOR_PROMPT}"
    risk_prompt="${risk_prompt//%TASK%/$task_name}"
    risk_prompt="${risk_prompt//%DIFF%/$diff_summary}"
    risk_prompt="${risk_prompt//%FILES%/$files_changed}"

    # Timestamp pour le log
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Appel Claude avec timeout court (45s)
    local response=""
    response=$(claude_with_timeout 45 "$risk_prompt" 2>/dev/null)

    # Valeurs par défaut
    local risk_level="MEDIUM"
    local risk_reason="Évaluation automatique"
    local review_needed="false"
    local review_focus=""

    if [ -n "$response" ]; then
        # Extraire les valeurs de la réponse
        if echo "$response" | grep -q "RISK_LEVEL:"; then
            risk_level=$(echo "$response" | grep "RISK_LEVEL:" | sed 's/.*RISK_LEVEL://' | tr -d '[:space:]' | head -1)
        fi
        if echo "$response" | grep -q "RISK_REASON:"; then
            risk_reason=$(echo "$response" | grep "RISK_REASON:" | sed 's/.*RISK_REASON://' | head -1)
        fi
        if echo "$response" | grep -q "REVIEW_NEEDED:true"; then
            review_needed="true"
        fi
        if echo "$response" | grep -q "REVIEW_FOCUS:"; then
            review_focus=$(echo "$response" | grep "REVIEW_FOCUS:" | sed 's/.*REVIEW_FOCUS://' | head -1)
        fi
    fi

    # Normaliser le niveau de risque
    case "$risk_level" in
        LOW|low) risk_level="LOW" ;;
        MEDIUM|medium) risk_level="MEDIUM" ;;
        HIGH|high) risk_level="HIGH" ;;
        *) risk_level="MEDIUM" ;;
    esac

    # Affichage selon le niveau
    case "$risk_level" in
        LOW)
            echo -e "  ${GREEN}│ 🟢 Risque: FAIBLE${RESET} - $risk_reason"
            ;;
        MEDIUM)
            echo -e "  ${YELLOW}│ 🟡 Risque: MOYEN${RESET} - $risk_reason"
            ;;
        HIGH)
            echo -e "  ${RED}│ 🔴 Risque: ÉLEVÉ${RESET} - $risk_reason"
            if [ -n "$review_focus" ]; then
                echo -e "  ${RED}│ 👁 Focus review:${RESET} $review_focus"
            fi
            ;;
    esac

    # Logger le résultat
    mkdir -p "$LOG_DIR"
    cat >> "$RISK_LOG_FILE" << EOF
================================================================================
[RISK ASSESSMENT] $timestamp | Loop #$loop_num
================================================================================
Task: $task_name
Files: $files_changed
Risk Level: $risk_level
Reason: $risk_reason
Review Needed: $review_needed
Review Focus: $review_focus
--------------------------------------------------------------------------------
EOF

    # Émettre l'événement
    emit_event "RISK_ASSESSED" "loop=$loop_num" "task=$task_name" "level=$risk_level" "review=$review_needed"

    # Ajouter à la review queue si nécessaire
    if [[ "$review_needed" == "true" ]] || [[ "$risk_level" == "HIGH" ]]; then
        add_to_review_queue "$task_name" "$risk_level" "$risk_reason" "$review_focus" "$files_changed"
    fi

    # Retourner le niveau pour traitement ultérieur
    echo "$risk_level"
}

# Ajouter une tâche à la review queue
add_to_review_queue() {
    local task_name="$1"
    local risk_level="$2"
    local risk_reason="$3"
    local review_focus="$4"
    local files_changed="$5"

    init_review_queue

    local timestamp=$(date '+%Y-%m-%d %H:%M')
    local icon="🟡"
    [[ "$risk_level" == "HIGH" ]] && icon="🔴"

    # Ajouter l'entrée à la queue
    cat >> "$REVIEW_QUEUE_FILE" << EOF

### $icon [$risk_level] $task_name
- **Date**: $timestamp
- **Raison**: $risk_reason
- **Focus**: ${review_focus:-"Review générale"}
- **Fichiers**: $files_changed
- **Statut**: ⏳ En attente

EOF

    echo -e "  ${YELLOW}│ 📋 Ajouté à $REVIEW_QUEUE_FILE${RESET}"
    log_info "Tâche ajoutée à la review queue: $task_name ($risk_level)"
}

# Vérifier si on doit bloquer pour review (selon le seuil configuré)
should_pause_for_review() {
    local risk_level="$1"

    case "$RISK_PAUSE_THRESHOLD" in
        LOW)
            # Pause pour tout sauf rien
            [[ "$risk_level" != "" ]] && return 0
            ;;
        MEDIUM)
            # Pause pour MEDIUM et HIGH
            [[ "$risk_level" == "MEDIUM" || "$risk_level" == "HIGH" ]] && return 0
            ;;
        HIGH)
            # Pause seulement pour HIGH
            [[ "$risk_level" == "HIGH" ]] && return 0
            ;;
        NONE)
            # Jamais de pause
            return 1
            ;;
    esac

    return 1
}

# Vérifier si on peut auto-approve (skip CX test)
can_auto_approve() {
    local risk_level="$1"

    case "$RISK_AUTO_APPROVE" in
        LOW)
            [[ "$risk_level" == "LOW" ]] && return 0
            ;;
        MEDIUM)
            [[ "$risk_level" == "LOW" || "$risk_level" == "MEDIUM" ]] && return 0
            ;;
        HIGH)
            # Auto-approve tout (pas recommandé)
            return 0
            ;;
        NONE)
            # Jamais d'auto-approve
            return 1
            ;;
    esac

    return 1
}

# -----------------------------------------------------------------------------
# MODE FAST - Boucle principale
# -----------------------------------------------------------------------------
run_fast_mode() {
    # Mode events: initialiser les fichiers de contrôle
    if [[ "$OUTPUT_MODE" == "events" ]]; then
        START_TIME=$(date +%s)
        echo $$ > "$PID_FILE"
        echo "running" > "$STATUS_FILE"
        : > "$EVENTS_FILE"

        # Utilise la fonction qui compte TODO.md + BMAD
        local pending_tasks
        pending_tasks=$(get_total_pending_tasks)

        local mode_info="fast"
        should_use_bmad && mode_info="fast+bmad"

        emit_event "PIPELINE_START" "mode=$mode_info" "max_tasks=$MAX_TASKS" "pending_tasks=$pending_tasks"
    fi

    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║   ⚡ CLAUDE ULTRA - Pipeline CI/CD Autonome                  ║"
    echo "║   1 appel = 1 tâche complète | Détection fin intelligente   ║"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    draw_usage_dashboard

    local loop=0
    local tasks_completed=0
    local start_time=$(date +%s)

    while true; do
        ((loop++))

        # Mode events: vérifier les commandes de contrôle
        check_control_commands

        # Vérifier la limite de tâches (mode --single ou --tasks N)
        if [[ "$MAX_TASKS" -gt 0 && "$tasks_completed" -ge "$MAX_TASKS" ]]; then
            emit_event "MAX_TASKS_REACHED" "completed=$tasks_completed" "max=$MAX_TASKS"
            echo -e "${GREEN}✅ $MAX_TASKS tâche(s) terminée(s) - arrêt${RESET}"
            [[ "$OUTPUT_MODE" == "events" ]] && echo "completed" > "$STATUS_FILE"
            break
        fi

        # Vérifications avant cycle
        if ! check_quota; then
            emit_event "QUOTA_CRITICAL" "session_pct=$SESSION_QUOTA_PCT"
            echo -e "${RED}🛑 Quota critique - arrêt${RESET}"
            [[ "$OUTPUT_MODE" == "events" ]] && echo "stopped" > "$STATUS_FILE"
            break
        fi

        if check_task_completion; then
            emit_event "ALL_TASKS_DONE" "loops=$loop" "completed=$tasks_completed"
            echo -e "${GREEN}🎉 Toutes les tâches terminées !${RESET}"
            [[ "$OUTPUT_MODE" == "events" ]] && echo "completed" > "$STATUS_FILE"
            break
        fi

        if detect_no_changes; then
            emit_event "NO_PROGRESS" "consecutive=$CONSECUTIVE_NO_CHANGES"
            echo -e "${YELLOW}💤 Arrêt intelligent - pas de progrès${RESET}"
            [[ "$OUTPUT_MODE" == "events" ]] && echo "stopped" > "$STATUS_FILE"
            break
        fi

        # Rate limiting
        check_rate_limit

        # Lire la tâche en cours
        local current_task_name=""
        [[ -f "$CURRENT_TASK_FILE" ]] && current_task_name=$(head -5 "$CURRENT_TASK_FILE" 2>/dev/null | grep -v "^#" | head -1 | tr -d '\n')

        emit_event "LOOP_START" "loop=$loop" "task=$current_task_name"
        write_progress "$loop" "RUNNING" "$current_task_name" "running"

        # Header du loop
        echo ""
        echo -e "${BOLD}${MAGENTA}══════════════════════════════════════════════════════════${RESET}"
        echo -e "${MAGENTA}⚡ FAST LOOP #${loop}${RESET} $(date '+%H:%M:%S')"
        echo -e "${BOLD}${MAGENTA}══════════════════════════════════════════════════════════${RESET}"

        log_info "Fast loop #$loop"
        echo "--- FAST LOOP #$loop : $(date) ---" >> "$LOG_FILE"

        # Capturer le HEAD avant exécution pour détecter les commits faits par Claude
        local head_before
        head_before=$(git rev-parse HEAD 2>/dev/null || echo "")

        # Construire le prompt (avec spec si disponible)
        local full_prompt
        full_prompt=$(build_fast_prompt)

        # Exécuter Claude (UN SEUL appel)
        echo -e "${CYAN}📤 Exécution Claude...${RESET}"
        echo ""

        local tmp_output
        tmp_output=$(mktemp)
        local exit_code=0

        claude -p $CLAUDE_FLAGS --verbose --output-format stream-json "$full_prompt" 2>&1 | \
        while IFS= read -r line; do
            local msg_type
            msg_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)

            case "$msg_type" in
                "assistant")
                    local content
                    content=$(echo "$line" | jq -r '.message.content[]? | select(.type == "text") | .text // empty' 2>/dev/null)
                    if [ -n "$content" ]; then
                        echo "$content" | while IFS= read -r text_line; do
                            echo -e "  │ $text_line"
                            echo "$text_line" >> "$tmp_output"
                        done
                    fi
                    ;;
                "result")
                    update_usage_from_result "$line"
                    local is_error
                    is_error=$(echo "$line" | jq -r '.is_error // false' 2>/dev/null)
                    if [ "$is_error" = "true" ]; then
                        exit_code=1
                    fi
                    ;;
            esac
        done

        exit_code=${PIPESTATUS[0]:-$exit_code}

        # Log output
        if [ -f "$tmp_output" ]; then
            echo "[FAST LOOP #$loop]" >> "$LOG_FILE"
            cat "$tmp_output" >> "$LOG_FILE"
            rm -f "$tmp_output"
        fi

        echo ""
        echo -e "${GRAY}─────────────────────────────────────────────────────────${RESET}"

        # Vérifier les changements: fichiers modifiés OU commits faits par Claude
        local head_after
        head_after=$(git rev-parse HEAD 2>/dev/null || echo "")
        local has_uncommitted_changes=false
        local has_new_commits=false

        # Vérifier les fichiers modifiés non commités
        if ! git diff --quiet || ! git diff --cached --quiet; then
            has_uncommitted_changes=true
        fi

        # Vérifier si Claude a fait des commits
        if [ -n "$head_before" ] && [ "$head_before" != "$head_after" ]; then
            has_new_commits=true
        fi

        if [ "$has_uncommitted_changes" = true ] || [ "$has_new_commits" = true ]; then
            CONSECUTIVE_NO_CHANGES=0
            ((tasks_completed++))

            emit_event "TASK_PROGRESS" "loop=$loop" "tasks_completed=$tasks_completed" "task=$current_task_name"

            if [ "$has_new_commits" = true ]; then
                local commit_count
                commit_count=$(git rev-list --count "$head_before".."$head_after" 2>/dev/null || echo "1")
                echo -e "${GREEN}✓ Changements détectés (${commit_count} commit(s) par Claude)${RESET}"
                git log --oneline "$head_before".."$head_after" 2>/dev/null | while read -r line; do
                    echo -e "  ${GRAY}│${RESET} $line"
                done
            else
                echo -e "${GREEN}✓ Changements détectés${RESET}"
                git status --short | head -5 | while read -r line; do
                    echo -e "  ${GRAY}│${RESET} $line"
                done
            fi

            # Variable pour self_validate (doit être déclarée avant le bloc conditionnel)
            local diff_summary=""

            # Auto-commit des changements non commités restants
            if [ "$has_uncommitted_changes" = true ]; then
                git add -A

                diff_summary=$(git diff --cached --stat | tail -3)

                if [ -n "$diff_summary" ]; then
                    local commit_message
                    # Timeout court pour les messages de commit (30s max)
                    commit_message=$(claude_with_timeout 30 "Message commit conventionnel (1 ligne, format type(scope): desc) pour:
$diff_summary" | head -1 | tr -d '\n')

                    if [ -z "$commit_message" ]; then
                        commit_message="chore: fast-mode loop $loop"
                    fi

                    if git commit -m "$commit_message" >> "$LOG_FILE" 2>&1; then
                        local commit_hash=$(git rev-parse --short HEAD)
                        echo -e "${GREEN}📦 Commit:${RESET} $commit_message ${GRAY}($commit_hash)${RESET}"
                        log_success "Commit: $commit_message"
                    fi
                fi
            fi

            # Récupérer le diff et les fichiers modifiés pour l'évaluation
            local task_diff=""
            local files_changed=""
            if [ "$has_new_commits" = true ]; then
                task_diff=$(git diff "$head_before".."$head_after" --stat 2>/dev/null | head -15)
                files_changed=$(git diff "$head_before".."$head_after" --name-only 2>/dev/null | tr '\n' ', ')

                # Si current_task_name est vide, essayer de l'extraire du commit ou TODO.md
                if [ -z "$current_task_name" ]; then
                    # Option 1: Extraire depuis le dernier commit message
                    current_task_name=$(git log -1 --format='%s' 2>/dev/null | sed 's/^[a-z]*([^)]*): //' | head -1)
                fi
            else
                task_diff="$diff_summary"
                files_changed=$(git diff --cached --name-only 2>/dev/null | tr '\n' ', ')
            fi

            # 1. Évaluation du risque de la tâche
            local risk_level="MEDIUM"
            if [[ "$RISK_ENABLED" == "true" && -n "$current_task_name" ]]; then
                # Capturer le niveau de risque (dernière ligne de la sortie)
                risk_level=$(assess_task_risk "$current_task_name" "$task_diff" "$files_changed" "$loop" | tail -1)
            fi

            # 2. Décider si on doit faire le test CX
            local skip_cx_test=false

            # Auto-approve si risque faible
            if can_auto_approve "$risk_level"; then
                echo -e "  ${GREEN}│ ⚡ Auto-approve (risque $risk_level)${RESET}"
                skip_cx_test=true
            fi

            # 3. Customer Experience Test (sauf si auto-approved)
            if [[ "$skip_cx_test" == "false" && "$CX_ENABLED" == "true" && -n "$current_task_name" ]]; then
                # Exécuter le test CX (1-2 interactions max)
                if ! run_cx_test "$current_task_name" "$task_diff" "$loop"; then
                    # Test CX échoué - la tâche a été marquée FAIL
                    emit_event "CX_FAILED" "loop=$loop" "task=$current_task_name"
                fi
            fi

            # 4. Vérifier si on doit pauser pour review humaine
            if should_pause_for_review "$risk_level"; then
                echo -e "  ${RED}│ ⏸ PAUSE - Review humaine requise pour risque $risk_level${RESET}"
                echo -e "  ${YELLOW}│ Consultez $REVIEW_QUEUE_FILE puis relancez le pipeline${RESET}"
                emit_event "REVIEW_PAUSE" "loop=$loop" "task=$current_task_name" "risk=$risk_level"
                [[ "$OUTPUT_MODE" == "events" ]] && echo "paused" > "$STATUS_FILE"
                break
            fi

        else
            echo -e "${YELLOW}ℹ Pas de changements ce loop${RESET}"
        fi

        # Stats
        local elapsed=$(($(date +%s) - start_time))
        local mins=$((elapsed / 60))
        local secs=$((elapsed % 60))

        emit_event "LOOP_DONE" "loop=$loop" "tasks_completed=$tasks_completed" "elapsed=${mins}m${secs}s" "tokens=$SESSION_INPUT_TOKENS"
        write_progress "$loop" "DONE" "$current_task_name" "running"

        echo ""
        echo -e "${GRAY}📊 Loop $loop | Tâches: $tasks_completed | Temps: ${mins}m${secs}s | Quota: ${SESSION_QUOTA_PCT}%${RESET}"

        # Pause courte
        echo -e "${YELLOW}⏸${RESET}  Pause 2s... (Ctrl+C pour arrêter)"
        emit_event "WAITING" "seconds=2" "reason=inter_loop_pause"
        sleep 2
    done

    # Résumé final
    local total_time=$(($(date +%s) - start_time))
    local total_mins=$((total_time / 60))
    local total_secs=$((total_time % 60))

    echo ""
    echo -e "${BOLD}${GREEN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    ⚡ FAST MODE TERMINÉ                      ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    printf "║   Loops: %-5d    Tâches complétées: %-5d                  ║\n" "$loop" "$tasks_completed"
    printf "║   Temps total: %dm%02ds                                      ║\n" "$total_mins" "$total_secs"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    draw_usage_dashboard

    # Événement de fin de pipeline
    emit_event "PIPELINE_DONE" "loops=$loop" "tasks_completed=$tasks_completed" "duration=${total_mins}m${total_secs}s" "tokens=$SESSION_INPUT_TOKENS"
    write_progress "$loop" "" "" "completed"
}

# -----------------------------------------------------------------------------
# MODE PARALLÈLE - FONCTIONS
# -----------------------------------------------------------------------------

# Extraire les tâches de TODO.md
extract_tasks() {
    local max_tasks="$1"
    local tasks=()
    
    if [ ! -f "$TASK_FILE" ]; then
        echo "[]"
        return
    fi
    
    # Extraire les tâches non terminées (- [ ])
    while IFS= read -r line; do
        # Nettoyer la ligne
        local task=$(echo "$line" | sed 's/^[[:space:]]*- \[ \][[:space:]]*//' | tr -d '\n')
        if [ -n "$task" ] && [ ${#tasks[@]} -lt "$max_tasks" ]; then
            tasks+=("$task")
        fi
    done < <(grep -E "^\s*- \[ \]" "$TASK_FILE" | head -n "$max_tasks")
    
    # Retourner en format JSON-like pour parsing
    printf '%s\n' "${tasks[@]}"
}

# Créer un worktree pour un agent
create_worktree() {
    local agent_id="$1"
    local task="$2"
    
    # Sanitize branch name: remove special chars, accents, limit length
    local sanitized_task
    sanitized_task=$(echo "$task" | \
        tr '[:upper:]' '[:lower:]' | \
        sed 's/[àáâãäå]/a/g; s/[èéêë]/e/g; s/[ìíîï]/i/g; s/[òóôõö]/o/g; s/[ùúûü]/u/g; s/[ç]/c/g; s/[ñ]/n/g' | \
        tr -cd '[:alnum:] -' | \
        tr ' ' '-' | \
        tr -s '-' | \
        sed 's/^-//; s/-$//' | \
        cut -c1-30)
    
    # Fallback si sanitized est vide
    if [ -z "$sanitized_task" ]; then
        sanitized_task="task-${agent_id}"
    fi
    
    local branch_name="agent-${agent_id}/${sanitized_task}"
    local worktree_path="${WORKTREE_DIR}/agent-${agent_id}"
    
    echo "[worktree] Création: $worktree_path (branche: $branch_name)" >&2
    
    # Supprimer le worktree existant si présent
    if [ -d "$worktree_path" ]; then
        git worktree remove "$worktree_path" --force >/dev/null 2>&1 || rm -rf "$worktree_path"
    fi
    
    # Vérifier si la branche existe déjà et la supprimer (TOUT vers /dev/null)
    git branch -D "$branch_name" >/dev/null 2>&1 || true
    
    # Créer le répertoire parent
    mkdir -p "$WORKTREE_DIR"
    
    # Créer le worktree avec nouvelle branche
    local output
    output=$(git worktree add -b "$branch_name" "$worktree_path" HEAD 2>&1)
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        echo "[worktree] ✓ Créé: $worktree_path" >&2
        # SEUL stdout: le chemin du worktree
        echo "$worktree_path"
        return 0
    else
        echo "[worktree] ✗ Échec: $output" >&2
        echo ""
        return 1
    fi
}

# Créer le fichier de tâche spécifique pour un agent (une seule tâche)
# IMPORTANT: Utilise @agent-task.md pour NE PAS écraser TODO.md lors du merge
create_agent_todo() {
    local worktree_path="$1"
    local task="$2"

    # Créer le fichier de tâche agent (pas TODO.md !)
    cat > "${worktree_path}/${AGENT_TASK_FILE}" << EOF
# Agent Task

## Tâche assignée
- [ ] ${task}

## Terminé
EOF

    # Ajouter au .gitignore local pour ne jamais commiter ce fichier
    echo "${AGENT_TASK_FILE}" >> "${worktree_path}/.gitignore"
}

# Lancer un agent dans un worktree
launch_agent() {
    local agent_id="$1"
    local worktree_path="$2"
    local task="$3"
    local color="${AGENT_COLORS[$((agent_id % ${#AGENT_COLORS[@]}))]}"

    # Échapper les backticks pour éviter l'interprétation bash
    task=$(echo "$task" | sed 's/`/\\`/g')
    
    # Convertir en chemin absolu
    local abs_worktree_path="$(cd "$worktree_path" && pwd)"
    
    # Script wrapper pour l'agent
    local agent_script="${abs_worktree_path}/.agent-runner.sh"
    
    cat > "$agent_script" << AGENT_EOF
#!/bin/bash
# Agent $agent_id - Worktree: $abs_worktree_path

cd "$abs_worktree_path" || exit 1

# Couleur de l'agent
COLOR="\033[${color}m"
RESET="\033[0m"

echo -e "\${COLOR}╔════════════════════════════════════════╗\${RESET}"
echo -e "\${COLOR}║  🤖 AGENT $agent_id                              ║\${RESET}"
echo -e "\${COLOR}║  Task: ${task:0:30}...\${RESET}"
echo -e "\${COLOR}╚════════════════════════════════════════╝\${RESET}"

echo "Répertoire: \$(pwd)"
echo "Git status: \$(git status --short 2>/dev/null | head -3)"

# Lancer claude-ultra en mode single-task
export PARALLEL_MODE=false
export MAX_CONSECUTIVE_NO_CHANGES=2

# Exécuter le script principal (copié dans le worktree)
if [ -f "./claude-ultra.sh" ]; then
    echo "Lancement de claude-ultra.sh..."
    ./claude-ultra.sh
else
    echo "claude-ultra.sh non trouvé, utilisation de Claude directement..."
    # Fallback: utiliser claude directement
    claude -p --dangerously-skip-permissions "Tu travailles sur cette tâche unique: $task. 

Suis le processus TDD:
1. Écris les tests d'abord
2. Implémente le code
3. Refactorise
4. Documente

Quand terminé, marque la tâche comme [x] dans TODO.md"
fi

# Signaler la fin
echo -e "\${COLOR}✅ AGENT $agent_id TERMINÉ\${RESET}"
touch "$abs_worktree_path/.agent-done"

echo "Agent $agent_id terminé. Fichier .agent-done créé."
AGENT_EOF

    chmod +x "$agent_script"
    echo "$agent_script"
}

# Merge un worktree terminé vers main
merge_worktree() {
    local agent_id="$1"
    local worktree_path="${WORKTREE_DIR}/agent-${agent_id}"
    
    if [ ! -d "$worktree_path" ]; then
        log_error "Worktree agent-${agent_id} n'existe pas"
        return 1
    fi
    
    # Récupérer le nom de la branche
    local branch_name=$(cd "$worktree_path" && git branch --show-current)
    
    if [ -z "$branch_name" ]; then
        log_error "Impossible de trouver la branche pour agent-${agent_id}"
        return 1
    fi
    
    # Revenir au repo principal
    cd "$(git rev-parse --show-toplevel)" || return 1
    
    # Vérifier s'il y a des commits à merger
    local commits=$(git log main.."$branch_name" --oneline 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$commits" -eq 0 ]; then
        log_info "Agent $agent_id: Aucun commit à merger"
        return 0
    fi
    
    log_info "Agent $agent_id: Merge de $commits commit(s) depuis $branch_name"
    
    # Tenter le merge
    if git merge "$branch_name" --no-edit -m "🤖 Auto-merge agent-${agent_id}: ${branch_name}" 2>/dev/null; then
        log_success "Agent $agent_id: Merge réussi"
        
        # Nettoyer
        git worktree remove "$worktree_path" --force 2>/dev/null
        git branch -d "$branch_name" 2>/dev/null
        
        return 0
    else
        log_error "Agent $agent_id: Conflit de merge détecté"
        git merge --abort 2>/dev/null
        
        # Garder le worktree pour résolution manuelle ou par IA
        echo "$agent_id" >> "${WORKTREE_DIR}/.conflicts"
        return 1
    fi
}

# Résoudre UN fichier en conflit avec Claude AI
resolve_single_conflict_with_ai() {
    local file_path="$1"
    local branch_name="$2"

    log_info "🤖 Agent Merger: résolution de $file_path..."

    # Récupérer le contenu en conflit
    local conflict_content
    conflict_content=$(cat "$file_path" 2>/dev/null)

    if [ -z "$conflict_content" ]; then
        log_error "Fichier vide ou inaccessible: $file_path"
        return 1
    fi

    # Vérifier qu'il y a bien des marqueurs de conflit
    if ! echo "$conflict_content" | grep -q "^<<<<<<<"; then
        log_info "Pas de marqueurs de conflit dans $file_path"
        return 0
    fi

    # Construire le prompt pour le Merger
    local merge_prompt
    merge_prompt="${PERSONA_MERGER}

FICHIER EN CONFLIT: $file_path
BRANCHE SOURCE: $branch_name
BRANCHE CIBLE: main

CONTENU AVEC CONFLITS:
\`\`\`
$conflict_content
\`\`\`

INSTRUCTIONS:
1. Analyse les sections entre <<<<<<< et >>>>>>>
2. Comprends ce que chaque version voulait accomplir
3. Produis une version fusionnée qui:
   - Préserve les fonctionnalités des DEUX côtés
   - N'a AUCUN marqueur de conflit
   - Compile et fonctionne correctement

Réponds UNIQUEMENT avec le bloc:
\`\`\`resolved
[ton code résolu ici]
\`\`\`"

    # Appeler Claude pour résoudre
    local tmp_response
    tmp_response=$(mktemp)

    check_rate_limit

    echo -e "${CYAN}  📤 Appel Agent Merger...${RESET}"

    local resolved_content
    # Timeout pour la résolution de conflits (90s max)
    resolved_content=$(claude_with_timeout 90 "$merge_prompt")

    # Extraire le contenu entre ```resolved et ```
    local extracted_code
    extracted_code=$(echo "$resolved_content" | sed -n '/^```resolved$/,/^```$/p' | sed '1d;$d')

    if [ -z "$extracted_code" ]; then
        # Essayer sans le mot "resolved"
        extracted_code=$(echo "$resolved_content" | sed -n '/^```$/,/^```$/p' | sed '1d;$d')
    fi

    if [ -z "$extracted_code" ]; then
        log_error "Agent Merger n'a pas fourni de code résolu valide"
        echo "$resolved_content" >> "$LOG_FILE"
        return 1
    fi

    # Vérifier qu'il n'y a plus de marqueurs de conflit
    if echo "$extracted_code" | grep -q "^<<<<<<<\|^=======\|^>>>>>>>"; then
        log_error "Le code résolu contient encore des marqueurs de conflit"
        return 1
    fi

    # Écrire le fichier résolu
    echo "$extracted_code" > "$file_path"

    log_success "✅ Conflit résolu par IA: $file_path"
    return 0
}

# Résoudre TOUS les conflits d'un merge/rebase avec Claude
resolve_all_conflicts_with_ai() {
    local branch_name="$1"
    local conflicted_files

    # Lister les fichiers en conflit
    conflicted_files=$(git diff --name-only --diff-filter=U 2>/dev/null)

    if [ -z "$conflicted_files" ]; then
        log_info "Aucun fichier en conflit"
        return 0
    fi

    local total_files
    total_files=$(echo "$conflicted_files" | wc -l | tr -d ' ')
    local resolved_count=0
    local failed_count=0

    log_info "🔀 Agent Merger: $total_files fichier(s) en conflit à résoudre"

    echo "$conflicted_files" | while IFS= read -r file; do
        if [ -n "$file" ]; then
            if resolve_single_conflict_with_ai "$file" "$branch_name"; then
                git add "$file"
                ((resolved_count++))
            else
                ((failed_count++))
            fi
        fi
    done

    if [ "$failed_count" -gt 0 ]; then
        log_error "Agent Merger: $failed_count fichier(s) non résolus"
        return 1
    fi

    log_success "Agent Merger: tous les conflits résolus!"
    return 0
}

# Résoudre les conflits avec Claude (version améliorée avec Agent Merger)
resolve_conflicts() {
    local conflict_file="${WORKTREE_DIR}/.conflicts"
    local merging_file="${WORKTREE_DIR}/.merging"

    if [ ! -f "$conflict_file" ]; then
        return 0
    fi

    # Signaler que le merge est en cours (pour le dashboard)
    touch "$merging_file"

    log_info "🔀 Résolution des conflits avec Agent Merger..."

    local remaining_conflicts=()

    while IFS= read -r agent_id; do
        local worktree_path="${WORKTREE_DIR}/agent-${agent_id}"
        local branch_name=$(cd "$worktree_path" 2>/dev/null && git branch --show-current)

        if [ -z "$branch_name" ]; then
            continue
        fi

        log_info "Agent $agent_id ($branch_name): tentative de résolution..."

        # Revenir au repo principal
        cd "$(git rev-parse --show-toplevel)" || continue

        # Tenter le merge (qui va échouer avec des conflits)
        if ! git merge "$branch_name" --no-edit 2>/dev/null; then
            log_info "Conflits détectés, lancement de l'Agent Merger..."

            # Utiliser l'Agent Merger pour résoudre
            if resolve_all_conflicts_with_ai "$branch_name"; then
                # Finaliser le merge
                if git commit --no-edit -m "🤖 Auto-merge agent-${agent_id} (résolu par Agent Merger)"; then
                    log_success "Agent $agent_id: Merge réussi (résolu par IA)"

                    # Nettoyer le worktree
                    git worktree remove "$worktree_path" --force 2>/dev/null || true
                    git branch -d "$branch_name" 2>/dev/null || true
                else
                    log_error "Agent $agent_id: Échec du commit après résolution"
                    git merge --abort 2>/dev/null
                    remaining_conflicts+=("$agent_id")
                fi
            else
                log_error "Agent $agent_id: Agent Merger n'a pas pu résoudre tous les conflits"
                git merge --abort 2>/dev/null
                remaining_conflicts+=("$agent_id")
            fi
        else
            log_success "Agent $agent_id: Merge automatique réussi (pas de conflits)"
            git worktree remove "$worktree_path" --force 2>/dev/null || true
            git branch -d "$branch_name" 2>/dev/null || true
        fi
    done < "$conflict_file"

    rm -f "$conflict_file"

    # S'il reste des conflits non résolus
    if [ ${#remaining_conflicts[@]} -gt 0 ]; then
        log_error "Conflits non résolus pour: ${remaining_conflicts[*]}"
        log_info "Résolution manuelle requise dans les worktrees correspondants"

        # Réécrire les conflits restants
        for agent_id in "${remaining_conflicts[@]}"; do
            echo "$agent_id" >> "$conflict_file"
        done
        rm -f "$merging_file"
        return 1
    fi

    rm -f "$merging_file"
    log_success "🔀 Agent Merger: toutes les branches fusionnées avec succès!"
    return 0
}

# Dashboard de monitoring des agents
draw_swarm_dashboard() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                    🐝 CLAUDE SWARM - DASHBOARD                    ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    
    # Quotas
    fetch_usage_quotas 2>/dev/null
    local session_bar=$(build_progress_bar "$SESSION_QUOTA_PCT" 20)
    local weekly_bar=$(build_progress_bar "$WEEKLY_QUOTA_PCT" 20)
    
    echo -e "${BOLD}📊 Quotas:${RESET}"
    printf "  Session: ${session_bar} %3d%%\n" "$SESSION_QUOTA_PCT"
    printf "  Hebdo:   ${weekly_bar} %3d%%\n" "$WEEKLY_QUOTA_PCT"
    echo ""
    
    # Status des agents
    echo -e "${BOLD}🤖 Agents:${RESET}"
    
    for ((i=0; i<PARALLEL_AGENTS; i++)); do
        local worktree_path="${WORKTREE_DIR}/agent-${i}"
        local color="${AGENT_COLORS[$((i % ${#AGENT_COLORS[@]}))]}"
        local status="⏳ Running"
        local status_color="${YELLOW}"
        
        if [ -f "${worktree_path}/.agent-done" ]; then
            status="✅ Done"
            status_color="${GREEN}"
        elif [ ! -d "$worktree_path" ]; then
            status="⚪ Not started"
            status_color="${GRAY}"
        fi
        
        # Récupérer la tâche (depuis @agent-task.md, pas TODO.md)
        local task=""
        if [ -f "${worktree_path}/${AGENT_TASK_FILE}" ]; then
            task=$(grep -E "^\s*- \[ \]" "${worktree_path}/${AGENT_TASK_FILE}" 2>/dev/null | head -1 | sed 's/^[[:space:]]*- \[ \][[:space:]]*//' | cut -c1-40)
        fi
        
        printf "  \033[${color}m●\033[0m Agent %d: ${status_color}%-12s${RESET} %s\n" "$i" "$status" "$task"
    done
    
    echo ""
    echo -e "${GRAY}Refresh: 10s | Ctrl+C pour arrêter${RESET}"
}

# Analyser les tâches pour détecter les conflits potentiels
# Usage: analyze_task_conflicts "tâche1" "tâche2" "tâche3" ...
analyze_task_conflicts() {
    local task_list=("$@")
    local num_tasks=${#task_list[@]}
    local conflicts=()
    local has_conflict=false

    # Pattern pour détecter les fichiers mentionnés
    local file_pattern='[a-zA-Z0-9_/-]+\.(ts|js|tsx|jsx|py|sh|go|rs|java|rb|vue|svelte|css|scss|html|md)'

    for ((i=0; i<num_tasks; i++)); do
        local task_i="${task_list[$i]}"
        local task_i_lower=$(echo "$task_i" | tr '[:upper:]' '[:lower:]')

        for ((j=i+1; j<num_tasks; j++)); do
            local task_j="${task_list[$j]}"
            local task_j_lower=$(echo "$task_j" | tr '[:upper:]' '[:lower:]')

            # Extraire les fichiers/composants mentionnés
            local files_i=$(echo "$task_i" | grep -oE "$file_pattern" 2>/dev/null | sort -u || true)
            local files_j=$(echo "$task_j" | grep -oE "$file_pattern" 2>/dev/null | sort -u || true)

            # Vérifier les fichiers communs
            if [ -n "$files_i" ] && [ -n "$files_j" ]; then
                local common_files=$(comm -12 <(echo "$files_i") <(echo "$files_j") 2>/dev/null || true)
                if [ -n "$common_files" ]; then
                    conflicts+=("Agents $i et $j: fichiers communs ($(echo "$common_files" | tr '\n' ' '))")
                    has_conflict=true
                    continue
                fi
            fi

            # Vérifier les mots-clés similaires (composants, modules)
            local words_i=$(echo "$task_i_lower" | grep -oE '\b[a-z]{4,}\b' 2>/dev/null | sort -u || true)
            local words_j=$(echo "$task_j_lower" | grep -oE '\b[a-z]{4,}\b' 2>/dev/null | sort -u || true)

            if [ -n "$words_i" ] && [ -n "$words_j" ]; then
                local common_words=$(comm -12 <(echo "$words_i") <(echo "$words_j") 2>/dev/null | grep -v -E '^(pour|dans|avec|this|that|from|with|into|test|code|file|créer|fichier|avec|les)$' || true)

                # Si beaucoup de mots en commun, potentiel conflit
                local common_count=$(echo "$common_words" | grep -c . 2>/dev/null || echo 0)
                if [ "$common_count" -ge 4 ]; then
                    local sample_words=$(echo "$common_words" | head -3 | tr '\n' ', ')
                    conflicts+=("Agents $i et $j: termes similaires (${sample_words%,})")
                    has_conflict=true
                fi
            fi
        done
    done

    # Afficher les avertissements
    if [ "$has_conflict" = true ]; then
        echo ""
        echo -e "${YELLOW}⚠️  ATTENTION - Conflits potentiels détectés:${RESET}"
        for conflict in "${conflicts[@]}"; do
            echo -e "   ${YELLOW}• $conflict${RESET}"
        done
        echo ""
        echo -e "${GRAY}Conseil: Assurez-vous que les tâches travaillent sur des fichiers différents${RESET}"
        echo -e "${GRAY}pour minimiser les conflits de merge.${RESET}"
        echo ""

        # Demander confirmation
        echo -e "${YELLOW}Continuer malgré les conflits potentiels? [O/n]${RESET}"
        read -r -t 15 continue_anyway || continue_anyway="o"
        if [[ ! "$continue_anyway" =~ ^[Oo]?$ ]]; then
            log_info "Annulé par l'utilisateur (conflits potentiels)"
            return 1
        fi
    else
        echo -e "${GREEN}✓ Pas de conflit évident détecté entre les tâches${RESET}"
    fi

    return 0
}

# Boucle principale du mode parallèle
run_parallel_mode() {
    echo -e "${BOLD}${MAGENTA}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                                                                  ║"
    echo "║   🚀 CLAUDE SWARM - Mode Parallèle                              ║"
    echo "║                                                                  ║"
    echo "║   Agents: ${PARALLEL_AGENTS}                                                      ║"
    echo "║   Worktrees: ${WORKTREE_DIR}/                                          ║"
    echo "║                                                                  ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    
    # Vérifier qu'on est dans un repo Git
    if [ ! -d ".git" ]; then
        log_error "Pas un dépôt Git"
        return 1
    fi
    
    # Vérifier tmux
    if ! command -v tmux &> /dev/null; then
        log_error "tmux requis pour le mode parallèle"
        log_info "Installe avec: brew install tmux (macOS) ou apt install tmux (Linux)"
        return 1
    fi
    
    # Vérifier que le fichier TODO existe
    if [ ! -f "$TASK_FILE" ]; then
        log_error "Fichier $TASK_FILE introuvable"
        return 1
    fi

    # Protection contre les exécutions concurrentes
    local lockfile="${WORKTREE_DIR}/.swarm.lock"
    if [ -f "$lockfile" ]; then
        local lock_pid=$(cat "$lockfile" 2>/dev/null)
        if kill -0 "$lock_pid" 2>/dev/null; then
            log_error "Une autre instance du swarm est en cours (PID: $lock_pid)"
            log_info "Attendez qu'elle termine ou tuez-la: kill $lock_pid"
            return 1
        else
            log_info "Nettoyage d'un ancien verrou orphelin..."
            rm -f "$lockfile"
        fi
    fi
    mkdir -p "$WORKTREE_DIR"
    echo $$ > "$lockfile"
    trap "rm -f '$lockfile'" EXIT

    # Variables pour le mode resume
    local resume_agents=()
    local is_resuming=false

    # Mode RESUME : détecter et merger les branches/worktrees existants
    if [ "$RESUME_MODE" = "true" ]; then
        log_info "🔄 Mode RESUME - Détection des agents existants..."

        local existing_count=0
        local done_count=0
        local to_resume_count=0
        local merged_count=0

        # 1. D'abord, chercher les branches agent-* orphelines (sans worktree)
        local orphan_branches=$(git branch --list 'agent-*/*' 2>/dev/null)
        if [ -n "$orphan_branches" ]; then
            log_info "Branches orphelines détectées, tentative de merge..."
            while IFS= read -r branch; do
                branch=$(echo "$branch" | sed 's/^[* ]*//')
                [ -z "$branch" ] && continue

                local commits=$(git log main.."$branch" --oneline 2>/dev/null | wc -l | tr -d ' ')
                if [ "$commits" -gt 0 ]; then
                    log_info "  $branch: $commits commit(s) à merger"
                    if git merge "$branch" --no-edit -m "🔀 Resume merge: $branch" 2>/dev/null; then
                        log_success "  ✅ $branch mergé"
                        git branch -d "$branch" 2>/dev/null
                        ((merged_count++))
                    else
                        log_error "  ❌ Conflit sur $branch - résolution manuelle requise"
                        git merge --abort 2>/dev/null
                    fi
                else
                    log_info "  $branch: aucun commit, suppression..."
                    git branch -d "$branch" 2>/dev/null || git branch -D "$branch" 2>/dev/null
                fi
            done <<< "$orphan_branches"
        fi

        # 2. Ensuite, traiter les worktrees existants
        if [ -d "$WORKTREE_DIR" ]; then
            for wt in "$WORKTREE_DIR"/agent-*; do
                if [ -d "$wt" ]; then
                    ((existing_count++))
                    local agent_id=$(basename "$wt" | sed 's/agent-//')

                    if [ -f "$wt/.agent-done" ]; then
                        ((done_count++))
                        # Agent terminé, merger immédiatement
                        if [ ! -f "$wt/.merged" ]; then
                            log_info "  Agent $agent_id: ✅ Terminé, merge en cours..."
                            if merge_worktree "$agent_id"; then
                                ((merged_count++))
                            fi
                        else
                            log_info "  Agent $agent_id: ✅ Déjà mergé"
                        fi
                    else
                        ((to_resume_count++))
                        resume_agents+=("$agent_id")
                        log_info "  Agent $agent_id: ⏳ À reprendre"
                    fi
                fi
            done
        fi

        # Résumé
        if [ $merged_count -gt 0 ]; then
            log_success "$merged_count branche(s) mergée(s) avec succès"
        fi

        if [ $existing_count -gt 0 ]; then
            is_resuming=true
            PARALLEL_AGENTS=$existing_count
            log_success "Worktrees: $done_count terminé(s), $to_resume_count à reprendre"

            if [ $to_resume_count -eq 0 ]; then
                log_success "Tous les agents ont terminé et sont mergés !"
                # Nettoyer les worktrees
                log_info "Nettoyage des worktrees..."
                for wt in "$WORKTREE_DIR"/agent-*; do
                    [ -d "$wt" ] && git worktree remove "$wt" --force 2>/dev/null
                done
                rmdir "$WORKTREE_DIR" 2>/dev/null
                return 0
            fi
        elif [ $merged_count -gt 0 ]; then
            log_success "Toutes les branches orphelines ont été mergées !"
            return 0
        else
            log_info "Aucun agent à reprendre, démarrage normal..."
            RESUME_MODE="false"
        fi
    fi

    # Mode NORMAL : nettoyer et créer
    if [ "$is_resuming" = false ]; then
        # NETTOYER les anciens worktrees AVANT de commencer
        log_info "Nettoyage des anciens worktrees..."
        if [ -d "$WORKTREE_DIR" ]; then
            for old_wt in "$WORKTREE_DIR"/agent-*; do
                if [ -d "$old_wt" ]; then
                    log_info "  Suppression: $old_wt"
                    git worktree remove "$old_wt" --force 2>/dev/null || rm -rf "$old_wt"
                fi
            done
            rm -f "$WORKTREE_DIR"/.monitor.sh "$WORKTREE_DIR"/.conflicts 2>/dev/null
        fi
        git worktree prune 2>/dev/null || true
        log_success "Nettoyage terminé"

        # Extraire les tâches
        log_info "Extraction des tâches depuis $TASK_FILE..."
        local tasks=()
        while IFS= read -r task; do
            if [ -n "$task" ]; then
                tasks+=("$task")
                log_info "  Tâche trouvée: ${task:0:50}..."
            fi
        done < <(extract_tasks "$PARALLEL_AGENTS")

        local num_tasks=${#tasks[@]}

        if [ "$num_tasks" -eq 0 ]; then
            log_error "Aucune tâche trouvée dans $TASK_FILE"
            log_info "Assure-toi d'avoir des lignes au format: - [ ] Ma tâche"
            return 1
        fi

        log_success "Trouvé $num_tasks tâche(s) à paralléliser"

        # Analyser les conflits potentiels entre tâches
        if ! analyze_task_conflicts "${tasks[@]}"; then
            return 1
        fi

        # Ajuster le nombre d'agents si moins de tâches
        if [ "$num_tasks" -lt "$PARALLEL_AGENTS" ]; then
            PARALLEL_AGENTS=$num_tasks
            log_info "Ajusté à $PARALLEL_AGENTS agent(s)"
        fi
    fi
    
    # Sauvegarder le répertoire courant
    local ORIGINAL_DIR="$(pwd)"
    
    # Créer la session tmux
    log_info "Création session tmux: $SWARM_SESSION"
    tmux kill-session -t "$SWARM_SESSION" 2>/dev/null || true
    
    if ! tmux new-session -d -s "$SWARM_SESSION" -n "monitor"; then
        log_error "Impossible de créer la session tmux"
        return 1
    fi
    log_success "Session tmux créée"
    
    # Créer le script de monitoring
    local monitor_script="${WORKTREE_DIR}/.monitor.sh"
    mkdir -p "$WORKTREE_DIR"
    
    cat > "$monitor_script" << 'MONITOR_EOF'
#!/bin/bash
WORKTREE_DIR=".worktrees"
PARALLEL_AGENTS="$1"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
RESET='\033[0m'

while true; do
    clear
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║              🐝 CLAUDE SWARM - MONITOR                           ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    
    echo -e "${BOLD}📊 Status des Agents:${RESET}"
    echo ""
    
    done_count=0
    running_count=0
    
    for ((i=0; i<PARALLEL_AGENTS; i++)); do
        worktree_path="${WORKTREE_DIR}/agent-${i}"
        status_icon="⏳"
        status_text="Running"
        status_color="${YELLOW}"
        
        if [ -f "${worktree_path}/.agent-done" ]; then
            status_icon="✅"
            status_text="Terminé"
            status_color="${GREEN}"
            ((done_count++))
        elif [ ! -d "$worktree_path" ]; then
            status_icon="⚪"
            status_text="Non démarré"
            status_color="${GRAY}"
        else
            ((running_count++))
        fi
        
        # Récupérer la tâche (depuis @agent-task.md, pas TODO.md)
        task=""
        if [ -f "${worktree_path}/@agent-task.md" ]; then
            task=$(grep -E "^\s*- \[ \]" "${worktree_path}/@agent-task.md" 2>/dev/null | head -1 | sed 's/^[[:space:]]*- \[ \][[:space:]]*//' | cut -c1-50)
        fi
        
        printf "  ${status_color}${status_icon} Agent %d: %-10s${RESET}" "$i" "$status_text"
        if [ -n "$task" ]; then
            printf " │ ${GRAY}%s${RESET}" "${task:0:40}"
        fi
        echo ""
    done
    
    echo ""
    echo -e "${BOLD}📈 Progression:${RESET}"
    
    total=$PARALLEL_AGENTS
    pct=0
    if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null; then
        pct=$((done_count * 100 / total))
    fi
    
    # Barre de progression
    bar_width=40
    filled=$((pct * bar_width / 100))
    bar=""
    for ((j=0; j<bar_width; j++)); do
        if [ $j -lt $filled ]; then
            bar+="█"
        else
            bar+="░"
        fi
    done
    
    echo -e "  ${GREEN}${bar}${RESET} ${pct}% (${done_count}/${total})"
    echo ""

    # Section Agent Merger
    echo -e "${BOLD}🔀 Agent Merger:${RESET}"
    if [ -f "${WORKTREE_DIR}/.conflicts" ]; then
        conflict_count=$(wc -l < "${WORKTREE_DIR}/.conflicts" | tr -d ' ')
        echo -e "  ${YELLOW}⚠️  ${conflict_count} conflit(s) en attente de résolution${RESET}"
    elif [ -f "${WORKTREE_DIR}/.merging" ]; then
        echo -e "  ${CYAN}🔄 Résolution en cours...${RESET}"
    else
        echo -e "  ${GREEN}✅ Aucun conflit${RESET}"
    fi
    echo ""

    echo -e "${GRAY}─────────────────────────────────────────────────────────────────${RESET}"
    echo -e "${GRAY}Refresh: 5s │ Ctrl+B puis n/p pour naviguer │ Ctrl+B d pour détacher${RESET}"
    echo -e "${GRAY}Heure: $(date '+%H:%M:%S')${RESET}"

    # Vérifier si tous terminés
    if [ -n "$total" ] && [ "$total" -gt 0 ] && [ "$done_count" -eq "$total" ] 2>/dev/null; then
        echo ""
        echo -e "${GREEN}${BOLD}🎉 Tous les agents ont terminé !${RESET}"
        echo -e "${CYAN}🔀 Lancement de l'Agent Merger pour fusionner les branches...${RESET}"
        break
    fi
    
    sleep 5
done
MONITOR_EOF

    chmod +x "$monitor_script"
    
    # Lancer le monitor dans la première fenêtre
    tmux send-keys -t "${SWARM_SESSION}:monitor" "bash '$monitor_script' $PARALLEL_AGENTS" Enter
    
    # Copier le script dans chaque worktree et lancer les agents
    local launched=0
    local agent_scripts=()

    if [ "$is_resuming" = true ]; then
        # MODE RESUME : relancer uniquement les agents non terminés
        log_info "🔄 Reprise des agents interrompus..."

        for agent_id in "${resume_agents[@]}"; do
            local worktree_path="${WORKTREE_DIR}/agent-${agent_id}"

            if [ ! -d "$worktree_path" ]; then
                log_error "Worktree agent-$agent_id introuvable"
                continue
            fi

            # Récupérer la tâche depuis @agent-task.md
            local task=""
            if [ -f "${worktree_path}/${AGENT_TASK_FILE}" ]; then
                task=$(grep -E "^\s*- \[ \]" "${worktree_path}/${AGENT_TASK_FILE}" 2>/dev/null | head -1 | sed 's/^[[:space:]]*- \[ \][[:space:]]*//')
            fi
            log_info "Agent $agent_id: ${task:0:50}... (reprise)"

            # Mettre à jour le script principal
            cp "$0" "${worktree_path}/claude-ultra.sh" 2>/dev/null || true
            chmod +x "${worktree_path}/claude-ultra.sh" 2>/dev/null || true

            # Créer le script de l'agent
            local agent_script
            agent_script=$(launch_agent "$agent_id" "$worktree_path" "$task")

            if [ ! -f "$agent_script" ]; then
                log_error "Script agent non créé pour agent $agent_id"
                continue
            fi

            agent_scripts+=("$agent_script")
            ((launched++))
        done
    else
        # MODE NORMAL : créer les worktrees et lancer les agents
        for ((i=0; i<PARALLEL_AGENTS; i++)); do
            local task="${tasks[$i]}"
            log_info "Agent $i: ${task:0:50}..."

            # Créer le worktree
            local worktree_path
            worktree_path=$(create_worktree "$i" "$task")

            if [ -z "$worktree_path" ] || [ ! -d "$worktree_path" ]; then
                log_error "Impossible de créer le worktree pour agent $i"
                continue
            fi

            log_success "Worktree agent-$i créé"

            # Créer le TODO spécifique
            create_agent_todo "$worktree_path" "$task"

            # Copier le script principal
            cp "$0" "${worktree_path}/claude-ultra.sh" 2>/dev/null || true
            chmod +x "${worktree_path}/claude-ultra.sh" 2>/dev/null || true

            # Créer le script de l'agent
            local agent_script
            agent_script=$(launch_agent "$i" "$worktree_path" "$task")

            if [ ! -f "$agent_script" ]; then
                log_error "Script agent non créé pour agent $i"
                continue
            fi

            # Stocker le script pour lancement ultérieur
            agent_scripts+=("$agent_script")

            ((launched++))
        done
    fi

    if [ $launched -eq 0 ]; then
        log_error "Aucun agent n'a pu être lancé"
        tmux kill-session -t "$SWARM_SESSION" 2>/dev/null
        return 1
    fi

    # Créer la fenêtre "all-agents" avec vue split
    log_info "Création vue globale all-agents..."
    tmux new-window -t "$SWARM_SESSION" -n "all-agents"

    # Premier agent dans le pane principal
    tmux send-keys -t "${SWARM_SESSION}:all-agents" "bash '${agent_scripts[0]}'" Enter

    # Créer les panes pour les autres agents
    for ((i=1; i<launched; i++)); do
        if [ $((i % 2)) -eq 1 ]; then
            # Split horizontal
            tmux split-window -t "${SWARM_SESSION}:all-agents" -h
        else
            # Split vertical sur le dernier pane
            tmux split-window -t "${SWARM_SESSION}:all-agents" -v
        fi
        tmux send-keys -t "${SWARM_SESSION}:all-agents" "bash '${agent_scripts[$i]}'" Enter
    done

    # Réorganiser en grille équilibrée
    tmux select-layout -t "${SWARM_SESSION}:all-agents" tiled

    # Créer aussi les fenêtres individuelles pour zoom
    for ((i=0; i<launched; i++)); do
        tmux new-window -t "$SWARM_SESSION" -n "agent-$i"
        tmux send-keys -t "${SWARM_SESSION}:agent-$i" "bash '${agent_scripts[$i]}'" Enter
    done

    # Revenir sur la vue globale
    tmux select-window -t "${SWARM_SESSION}:all-agents"

    log_success "Swarm lancé avec $launched agents"
    echo ""
    echo -e "${BOLD}${GREEN}Pour voir les agents:${RESET}"
    echo -e "  ${CYAN}tmux attach -t $SWARM_SESSION${RESET}"
    echo ""
    echo -e "${BOLD}Navigation tmux:${RESET}"
    echo -e "  ${GRAY}Fenêtre 1: all-agents  - Vue globale (tous les agents)${RESET}"
    echo -e "  ${GRAY}Fenêtre 2+: agent-N    - Vue individuelle${RESET}"
    echo -e "  ${GRAY}Ctrl+B puis 1/2/3...   - Changer de fenêtre${RESET}"
    echo -e "  ${GRAY}Ctrl+B puis z          - Zoom/dézoom un pane${RESET}"
    echo -e "  ${GRAY}Ctrl+B puis d         - Détacher (agents continuent)${RESET}"
    echo ""
    
    # Demander si on veut attacher
    echo -e "${YELLOW}Attacher à la session tmux maintenant ? [O/n]${RESET}"
    read -r -t 10 attach_now || attach_now="o"
    
    if [[ "$attach_now" =~ ^[Oo]?$ ]]; then
        tmux attach -t "$SWARM_SESSION"
    else
        echo -e "${CYAN}Session en arrière-plan. Utilise: tmux attach -t $SWARM_SESSION${RESET}"
    fi
    
    # Boucle de surveillance (si on revient du tmux)
    echo ""
    echo -e "${YELLOW}Surveillance des agents... (Ctrl+C pour arrêter)${RESET}"
    
    local all_done=false
    local missing_worktrees=0

    while [ "$all_done" = false ]; do
        sleep 10

        all_done=true
        local done_count=0
        missing_worktrees=0

        for ((i=0; i<launched; i++)); do
            local worktree_path="${WORKTREE_DIR}/agent-${i}"

            if [ -f "${worktree_path}/.agent-done" ]; then
                ((done_count++))

                # Merger si pas encore fait
                if [ ! -f "${worktree_path}/.merged" ]; then
                    log_info "Agent $i terminé, tentative de merge..."
                    cd "$ORIGINAL_DIR" || continue
                    if merge_worktree "$i"; then
                        touch "${worktree_path}/.merged"
                    fi
                fi
            elif [ -d "$worktree_path" ]; then
                # Worktree existe mais agent pas encore terminé
                all_done=false
            else
                # Worktree disparu sans .agent-done = problème!
                ((missing_worktrees++))
            fi
        done

        if [ "$missing_worktrees" -gt 0 ] && [ "$done_count" -eq 0 ]; then
            echo ""
            log_error "$missing_worktrees worktree(s) ont disparu! Une autre exécution a peut-être nettoyé les worktrees."
            log_error "Arrêt de la surveillance. Relancez le script pour recommencer."
            break
        fi

        echo -ne "\r${CYAN}Progress: $done_count/$launched agents terminés${RESET}    "
    done
    
    echo ""
    log_success "Tous les agents ont terminé !"
    
    # Revenir au répertoire original
    cd "$ORIGINAL_DIR" || true
    
    # Résoudre les conflits restants
    resolve_conflicts
    
    # Nettoyer
    log_info "Nettoyage des worktrees..."
    for ((i=0; i<launched; i++)); do
        local worktree_path="${WORKTREE_DIR}/agent-${i}"
        git worktree remove "$worktree_path" --force 2>/dev/null || true
    done
    
    rmdir "$WORKTREE_DIR" 2>/dev/null || true
    
    # Fermer tmux
    tmux kill-session -t "$SWARM_SESSION" 2>/dev/null
    
    log_success "Swarm terminé avec succès !"
    draw_usage_dashboard
}

# Nettoyer le swarm en cas d'interruption
cleanup_swarm() {
    echo ""
    echo -e "${YELLOW}⚠️  Arrêt du swarm...${RESET}"
    
    # Tuer la session tmux
    tmux kill-session -t "$SWARM_SESSION" 2>/dev/null
    
    # Lister les worktrees actifs
    echo -e "${GRAY}Worktrees actifs:${RESET}"
    git worktree list 2>/dev/null | grep -v "^$(pwd)" | while read -r line; do
        echo "  $line"
    done
    
    echo ""
    echo -e "${YELLOW}Pour nettoyer manuellement:${RESET}"
    echo "  git worktree list"
    echo "  git worktree remove .worktrees/agent-N --force"
    
    exit 130
}

# -----------------------------------------------------------------------------
# GESTION DES SIGNAUX
# -----------------------------------------------------------------------------
# ARGUMENTS
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --parallel|-p)
            PARALLEL_MODE="true"
            shift
            ;;
        --agents|-a)
            PARALLEL_AGENTS="$2"
            shift 2
            ;;
        --resume|-r)
            RESUME_MODE="true"
            shift
            ;;
        --output|-o)
            OUTPUT_MODE="$2"
            shift 2
            ;;
        --single)
            MAX_TASKS=1
            shift
            ;;
        --tasks|-t)
            MAX_TASKS="$2"
            shift 2
            ;;
        --persistent|--no-stop)
            PERSISTENT_MODE="true"
            MAX_CONSECUTIVE_NO_CHANGES=9999
            shift
            ;;
        --max-calls)
            MAX_CALLS_PER_HOUR="$2"
            shift 2
            ;;
        --no-cx)
            CX_ENABLED="false"
            shift
            ;;
        --cx-interactions)
            CX_MAX_INTERACTIONS="$2"
            shift 2
            ;;
        --no-risk)
            RISK_ENABLED="false"
            shift
            ;;
        --risk-pause)
            # Seuil pour pause: LOW, MEDIUM, HIGH, NONE
            RISK_PAUSE_THRESHOLD="$2"
            shift 2
            ;;
        --auto-approve)
            # Seuil pour auto-approve: LOW, MEDIUM, HIGH, NONE
            RISK_AUTO_APPROVE="$2"
            shift 2
            ;;
        --autonomous)
            # Mode full autonome: pas de pause, auto-approve medium
            RISK_PAUSE_THRESHOLD="NONE"
            RISK_AUTO_APPROVE="MEDIUM"
            shift
            ;;
        --require-review)
            # Force la pause pour les tâches HIGH
            RISK_PAUSE_THRESHOLD="HIGH"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Modes:"
            echo "  (default)              Mode standard (1 appel Claude = 1 tâche)"
            echo "  --parallel, -p         Mode parallèle (N agents sur N tâches via worktrees)"
            echo ""
            echo "Options mode parallèle:"
            echo "  --agents N, -a N       Nombre d'agents parallèles (défaut: 3)"
            echo "  --resume, -r           Reprendre les agents interrompus"
            echo ""
            echo "Options générales:"
            echo "  --single               Exécute une seule tâche puis arrête"
            echo "  --tasks N, -t N        Exécute N tâches puis arrête (0 = illimité)"
            echo "  --persistent, --no-stop  Mode persistant (découpe auto les grosses tâches)"
            echo "  --max-calls N          Limite d'appels par heure (défaut: 50)"
            echo "  --output MODE, -o      Mode sortie: verbose (défaut), events, quiet"
            echo "  --help, -h             Affiche cette aide"
            echo ""
            echo "Customer Experience Tester:"
            echo "  --no-cx                Désactive le test CX après chaque tâche"
            echo "  --cx-interactions N    Nombre max d'interactions CX (défaut: 2)"
            echo "  Le CX Tester simule un utilisateur lambda pour valider l'UX."
            echo "  Si le test échoue, la tâche est marquée [CX_FAIL] dans TODO.md."
            echo "  Logs dans: logs/cx-tests-YYYYMMDD.log"
            echo ""
            echo "Risk Assessment (catégorisation des stories):"
            echo "  --no-risk              Désactive l'évaluation du risque"
            echo "  --risk-pause LEVEL     Pause pour review si risque >= LEVEL"
            echo "                         LEVEL: LOW, MEDIUM, HIGH, NONE (défaut)"
            echo "  --auto-approve LEVEL   Auto-approve (skip CX) si risque <= LEVEL"
            echo "                         LEVEL: LOW (défaut), MEDIUM, HIGH, NONE"
            echo "  --require-review       Force la pause pour HIGH (--risk-pause HIGH)"
            echo ""
            echo "  Niveaux de risque:"
            echo "    LOW    - Modifications mineures, patterns établis"
            echo "    MEDIUM - Nouvelles fonctionnalités simples"
            echo "    HIGH   - Nouvelles architectures, sécurité, DB migrations"
            echo ""
            echo "  Les tâches HIGH sont ajoutées à @review-queue.md"
            echo "  Logs dans: logs/risk-assessment-YYYYMMDD.log"
            echo ""
            echo "Intégration Claude Code (mode events):"
            echo "  --output events        Émet des événements JSON pour le skill /ultra"
            echo "  Fichiers de contrôle:"
            echo "    @ultra.events.log    Journal des événements JSON"
            echo "    @ultra.progress.json État de progression en temps réel"
            echo "    @ultra.command       Commandes: stop, pause, resume"
            echo "    @ultra.status        État: running, paused, stopped, completed"
            echo ""
            echo "Fichiers de contrôle:"
            echo "  TODO.md                Tâches du projet (1 par ligne: - [ ] tâche)"
            echo "  @fix_plan.md           Plan de correction prioritaire (optionnel)"
            echo "  @AGENT.md              Configuration agent (optionnel)"
            echo "  ARCHITECTURE.md        Documentation architecture"
            echo ""
            echo "Agent Merger (mode parallèle):"
            echo "  Quand des conflits Git surviennent entre branches parallèles,"
            echo "  l'Agent Merger utilise Claude pour résoudre intelligemment"
            echo "  les conflits en préservant les fonctionnalités des deux côtés."
            echo ""
            echo "Exemples:"
            echo "  $0                     # Mode standard"
            echo "  $0 --single            # Une seule tâche"
            echo "  $0 --persistent        # Continue jusqu'à TODO.md vide"
            echo "  $0 --parallel          # 3 agents parallèles"
            echo "  $0 -p -a 5             # 5 agents parallèles"
            echo "  $0 --single -o events  # Mode events (Claude Code)"
            exit 0
            ;;
        *)
            echo "Option inconnue: $1"
            echo "Utilise --help pour l'aide"
            exit 1
            ;;
    esac
done

# -----------------------------------------------------------------------------
# GESTION DES SIGNAUX (mise à jour pour swarm)
# -----------------------------------------------------------------------------
cleanup() {
    if [ "$PARALLEL_MODE" = "true" ]; then
        cleanup_swarm
    else
        echo ""
        echo -e "${YELLOW}⚠${RESET}  Interruption"
        draw_usage_dashboard
        log_info "Interrompu par l'utilisateur"
        exit 130
    fi
}

trap cleanup SIGINT SIGTERM

# -----------------------------------------------------------------------------
# DÉMARRAGE
# -----------------------------------------------------------------------------
if [ "$PARALLEL_MODE" = "true" ]; then
    run_parallel_mode
else
    init
    run_fast_mode
fi
