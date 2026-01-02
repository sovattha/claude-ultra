#!/bin/bash

# =============================================================================
# 🚀 DEV CYCLE ULTRA - Pipeline CI/CD avec Claude AI
# =============================================================================
# Combine les meilleures pratiques de :
# - Script autonome (boucle continue, monitoring quotas, commits auto)
# - SuperClaude (personas experts, evidence-based, réduction tokens)
# - Ralph (détection fin de tâche, rate limiting, fichiers de contrôle)
# =============================================================================

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

# Mode token-efficient (style SuperClaude)
TOKEN_EFFICIENT_MODE="${TOKEN_EFFICIENT_MODE:-false}"

# -----------------------------------------------------------------------------
# MODE PARALLÈLE (Git Worktrees)
# -----------------------------------------------------------------------------
PARALLEL_MODE="${PARALLEL_MODE:-false}"
PARALLEL_AGENTS="${PARALLEL_AGENTS:-3}"
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

# Définition des étapes du cycle
STEPS=("PRODUCT OWNER" "ARCHITECT" "IMPLEMENTER" "REFACTORER" "QA ENGINEER" "SECURITY AUDITOR" "DOCUMENTER" "COMMITEUR")
STEP_ICONS=("📋" "🏗️" "💻" "🧹" "🧪" "🔒" "📝" "📦")
TOTAL_STEPS=${#STEPS[@]}

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

PERSONA_PO="Tu es un PRODUCT OWNER Senior avec 15 ans d'expérience.
${MCP_TOOLS}
${NO_QUESTIONS}

EXPERTISE:
- Priorisation MoSCoW et WSJF
- User stories INVEST
- Découpage vertical des features
- Impact business et ROI

TA MISSION UNIQUE:
1. Analyse $TASK_FILE et identifie UNE tâche prioritaire faisable en <30min
2. Écris ta décision dans le fichier $CURRENT_TASK_FILE avec ce format exact:

# Tâche Sélectionnée
[Nom de la tâche]

## Description
[Ce qu'il faut faire concrètement]

## Fichiers concernés
[Liste des fichiers à modifier]

## Critères de succès
- [ ] [Critère 1]
- [ ] [Critère 2]

## Justification
[Pourquoi cette tâche en priorité]

3. AGIS: crée/mets à jour le fichier $CURRENT_TASK_FILE maintenant

RÈGLES ABSOLUES:
- [CRITICAL] Écris TOUJOURS dans $CURRENT_TASK_FILE
- [CRITICAL] Une seule tâche par cycle
- [CRITICAL] La tâche doit être completable en <30 min
- [HIGH] Privilégie les quick wins à fort impact"

PERSONA_ARCHITECT="Tu es un SOFTWARE ARCHITECT Senior spécialisé Clean Architecture.
${MCP_TOOLS}
${NO_QUESTIONS}

UTILISE Context7 POUR:
- Vérifier les patterns officiels des frameworks utilisés
- Consulter la doc des librairies avant de les intégrer

EXPERTISE:
- Clean Architecture / Hexagonal / Onion
- Domain-Driven Design (DDD)
- SOLID principles
- Design Patterns (GoF, Enterprise)

TA MISSION:
1. Lis le fichier $CURRENT_TASK_FILE pour connaître la tâche à implémenter
2. Analyse si la tâche respecte l'architecture existante
3. Si des fichiers doivent être créés/modifiés, mets à jour $CURRENT_TASK_FILE avec les détails techniques
4. AGIS: ajoute les détails d'architecture dans $CURRENT_TASK_FILE

RÈGLES ABSOLUES:
- [CRITICAL] Lis $CURRENT_TASK_FILE en premier
- [CRITICAL] Dependency Rule: dépendances vers l'intérieur uniquement
- [CRITICAL] Entities ne dépendent de rien
- [HIGH] Use Cases orchestrent, ne contiennent pas de logique infra"

PERSONA_IMPLEMENTER="Tu es un SENIOR DEVELOPER avec expertise TDD.
${MCP_TOOLS}
${NO_QUESTIONS}

UTILISE Context7 POUR:
- Consulter la doc officielle AVANT chaque nouvelle API/lib
- Vérifier la syntaxe exacte des fonctions

UTILISE Sequential-thinking POUR:
- Décomposer les implémentations complexes
- Planifier l'ordre des tests TDD

TA MISSION:
1. Lis $CURRENT_TASK_FILE pour connaître exactement ce que tu dois implémenter
2. Applique TDD strict:
   - Écris d'abord le test qui échoue (RED)
   - Écris le code minimal pour passer (GREEN)
   - Refactorise si nécessaire
3. AGIS: implémente la fonctionnalité MAINTENANT

RÈGLES ABSOLUES:
- [CRITICAL] Lis $CURRENT_TASK_FILE en premier
- [CRITICAL] Aucun code sans test correspondant
- [CRITICAL] Fonctions pures quand possible
- [HIGH] Pas de commentaires, code auto-documenté
- [HIGH] Early return, pas de nested if
- [MEDIUM] Max 20 lignes par fonction"

PERSONA_REFACTORER="Tu es un REFACTORING EXPERT obsédé par la qualité.
${MCP_TOOLS}
${NO_QUESTIONS}

UTILISE Sequential-thinking POUR:
- Analyser les dépendances avant refactoring
- Planifier les étapes de refactoring en séquence sûre

TA MISSION:
1. Analyse le code modifié dans ce cycle (git diff)
2. Identifie les code smells avec leurs noms exacts
3. AGIS: refactorise UN smell à la fois, vérifie que les tests passent

RÈGLES ABSOLUES:
- [CRITICAL] Ne jamais changer le comportement
- [CRITICAL] Tests verts avant ET après
- [HIGH] Un refactoring = un commit
- [MEDIUM] Documente le smell corrigé"

PERSONA_QA="Tu es un QA ENGINEER Senior avec expertise testing.
${MCP_TOOLS}
${NO_QUESTIONS}

UTILISE Playwright POUR:
- Tests E2E cross-browser (Chromium, Firefox, WebKit)
- Simuler les interactions utilisateur réelles
- Capturer des screenshots de régression

UTILISE Chrome DevTools POUR:
- Vérifier les erreurs console
- Analyser les requêtes réseau
- Détecter les memory leaks

TA MISSION:
1. Lis $CURRENT_TASK_FILE pour connaître ce qui a été implémenté
2. Vérifie que tous les tests passent (lance-les!)
3. Identifie les edge cases non testés
4. AGIS: écris les tests manquants MAINTENANT

RÈGLES ABSOLUES:
- [CRITICAL] Lance les tests existants d'abord
- [CRITICAL] Teste les cas limites: null, undefined, empty, max, min
- [CRITICAL] Teste les erreurs: network, timeout, invalid input
- [HIGH] Arrange-Act-Assert pattern
- [HIGH] Un test = un comportement"

PERSONA_SECURITY="Tu es un SECURITY ENGINEER spécialisé AppSec.
${MCP_TOOLS}
${NO_QUESTIONS}

UTILISE Context7 POUR:
- Vérifier les best practices de sécurité des frameworks
- Consulter la doc des libs de validation/sanitization

UTILISE Chrome DevTools POUR:
- Inspecter les headers de sécurité (CSP, CORS, etc.)
- Vérifier les cookies (HttpOnly, Secure, SameSite)
- Analyser les requêtes pour détecter les fuites de données

TA MISSION:
1. Analyse le code modifié dans ce cycle (git diff)
2. Cherche les vulnérabilités OWASP Top 10
3. AGIS: corrige les vulnérabilités Critical/High MAINTENANT

RÈGLES ABSOLUES:
- [CRITICAL] Jamais de secrets en dur
- [CRITICAL] Toujours valider/sanitizer les inputs
- [CRITICAL] Parameterized queries uniquement
- [HIGH] Principe du moindre privilège
- [HIGH] Escape output selon contexte (HTML, JS, SQL)"

PERSONA_DOCUMENTER="Tu es un TECHNICAL WRITER Senior.
${MCP_TOOLS}
${NO_QUESTIONS}

UTILISE Context7 POUR:
- Vérifier le format standard de documentation des libs utilisées
- S'inspirer des bonnes pratiques de doc officielles

TA MISSION:
1. Lis $CURRENT_TASK_FILE pour connaître ce qui a été fait
2. Mets à jour $TASK_FILE: marque la tâche comme [x] terminée avec la date
3. Mets à jour $ARCHITECTURE_FILE si des choix architecturaux ont été faits
4. AGIS: mets à jour la documentation MAINTENANT
5. Supprime le fichier $CURRENT_TASK_FILE quand tu as fini

RÈGLES ABSOLUES:
- [CRITICAL] $TASK_FILE doit refléter l'état réel
- [CRITICAL] Marquer la tâche terminée avec date: - [x] Tâche (YYYY-MM-DD)
- [HIGH] $ARCHITECTURE_FILE à jour avec les choix
- [HIGH] Supprimer $CURRENT_TASK_FILE à la fin"

# -----------------------------------------------------------------------------
# MODE TOKEN-EFFICIENT (Style SuperClaude)
# -----------------------------------------------------------------------------
TOKEN_EFFICIENT_SUFFIX=""
if [ "$TOKEN_EFFICIENT_MODE" = "true" ]; then
    TOKEN_EFFICIENT_SUFFIX="

MODE ULTRA-COMPACT ACTIVÉ:
- Utilise symboles: → (leads to), & (and), w/ (with), != (not equal)
- Pas de phrases complètes, bullet points uniquement
- Code sans commentaires
- Pas d'explications, juste les actions
- Réponse max 500 tokens"
fi

# -----------------------------------------------------------------------------
# PROMPTS COMBINÉS (Persona + Context + Rules)
# -----------------------------------------------------------------------------
build_prompt() {
    local persona="$1"
    local task="$2"
    local context=""
    
    # Charger le contexte local si présent
    if [ -f "$CONTEXT_FILE" ]; then
        context="CONTEXTE PROJET: $(cat "$CONTEXT_FILE")"
    fi
    
    # Charger le fix_plan si présent (style Ralph)
    local fix_plan=""
    if [ -f "$FIX_PLAN_FILE" ]; then
        fix_plan="
PLAN DE CORRECTION PRIORITAIRE (@fix_plan.md):
$(cat "$FIX_PLAN_FILE")

INSTRUCTION: Suis ce plan en priorité si applicable."
    fi
    
    # Charger la config agent si présente (style Ralph)
    local agent_config=""
    if [ -f "$AGENT_CONFIG_FILE" ]; then
        agent_config="
CONFIGURATION AGENT (@AGENT.md):
$(cat "$AGENT_CONFIG_FILE")"
    fi
    
    echo "${persona}

${context}
${fix_plan}
${agent_config}

TÂCHE ACTUELLE:
${task}

${TOKEN_EFFICIENT_SUFFIX}"
}

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
    # Vérifie si toutes les tâches sont terminées dans TODO.md
    if [ -f "$TASK_FILE" ]; then
        local pending_tasks
        pending_tasks=$(grep -c "^\s*- \[ \]" "$TASK_FILE" 2>/dev/null || echo "0")
        
        if [ "$pending_tasks" -eq 0 ]; then
            echo -e "${GREEN}🎉 Toutes les tâches sont terminées !${RESET}"
            log_success "Toutes les tâches complétées"
            return 0
        fi
    fi
    return 1
}

detect_no_changes() {
    # Vérifie s'il y a eu des changements git
    if git diff --quiet && git diff --cached --quiet; then
        ((CONSECUTIVE_NO_CHANGES++))
        log_info "Pas de changements détectés ($CONSECUTIVE_NO_CHANGES/$MAX_CONSECUTIVE_NO_CHANGES)"
        
        if [ $CONSECUTIVE_NO_CHANGES -ge $MAX_CONSECUTIVE_NO_CHANGES ]; then
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
# EXÉCUTION D'UNE ÉTAPE
# -----------------------------------------------------------------------------
run_step() {
    local step_num="$1"
    local step_name="$2"
    local persona="$3"
    local task="$4"
    
    local start_time
    start_time=$(date +%s)
    
    # Rate limiting
    check_rate_limit
    
    draw_progress_bar "$step_num" "$step_name" "running"
    draw_steps_overview "$step_num"
    
    log_info "Démarrage: $step_name"
    
    local full_prompt
    full_prompt=$(build_prompt "$persona" "$task")
    
    echo -e "${GRAY}─────────────────────────────────────────────────────────${RESET}"
    echo -e "${CYAN}📤 $step_name:${RESET}"
    echo ""
    
    local tmp_output
    tmp_output=$(mktemp)
    
    local exit_code=0
    
    claude -p $CLAUDE_FLAGS --verbose --output-format stream-json "$full_prompt" 2>&1 | \
    while IFS= read -r line; do
        local msg_type
        msg_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
        
        case "$msg_type" in
            "system")
                local model
                model=$(echo "$line" | jq -r '.model // empty' 2>/dev/null)
                if [ -n "$model" ]; then
                    echo -e "  ${GRAY}│ 🤖 $model${RESET}"
                fi
                ;;
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
    
    local output_size=0
    if [ -f "$tmp_output" ]; then
        output_size=$(wc -c < "$tmp_output" | tr -d ' ')
        echo "[CLAUDE - $step_name]" >> "$LOG_FILE"
        cat "$tmp_output" >> "$LOG_FILE"
        rm -f "$tmp_output"
    fi
    
    echo ""
    echo -e "${GRAY}─────────────────────────────────────────────────────────${RESET}"
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if [ "$exit_code" -ne 0 ]; then
        log_error "Échec: $step_name (${duration}s)"
        return 1
    fi
    
    log_success "$step_name terminé (${duration}s)"
    return 0
}

# -----------------------------------------------------------------------------
# ÉTAPE COMMITEUR
# -----------------------------------------------------------------------------
run_commit_step() {
    local step_num="$1"
    
    draw_progress_bar "$step_num" "COMMITEUR" "running"
    draw_steps_overview "$step_num"
    
    log_info "Vérification des changements..."
    
    if git diff --quiet && git diff --cached --quiet; then
        log_info "Aucun changement à commiter"
        echo -e "${YELLOW}ℹ${RESET}  Aucun fichier modifié"
        return 0
    fi
    
    echo -e "${CYAN}📋 Changements:${RESET}"
    git status --short | head -10 | while read -r line; do
        echo -e "  ${GRAY}│${RESET} $line"
    done
    
    git add -A
    
    check_rate_limit
    
    local diff_summary
    diff_summary=$(git diff --cached --stat | tail -5)
    
    local commit_prompt="Génère un message de commit conventionnel.
Format: type(scope): description

Types: feat|fix|refactor|docs|test|chore
Scope: le module/fichier principal modifié

Changements:
$diff_summary

Réponds UNIQUEMENT avec le message, rien d'autre."
    
    local commit_message
    commit_message=$(claude -p $CLAUDE_FLAGS --output-format text "$commit_prompt" 2>/dev/null | head -1 | tr -d '\n')
    
    if [ -z "$commit_message" ]; then
        commit_message="chore: auto-commit cycle $(date '+%Y%m%d-%H%M%S')"
    fi
    
    echo -e "${CYAN}📦 Commit:${RESET} $commit_message"
    
    if git commit -m "$commit_message" >> "$LOG_FILE" 2>&1; then
        log_success "Commit: $commit_message"
        local commit_hash
        commit_hash=$(git rev-parse --short HEAD)
        echo -e "  ${GRAY}└─ Hash: ${commit_hash}${RESET}"
        # Reset le compteur de "no changes" car un commit = du progrès
        CONSECUTIVE_NO_CHANGES=0
    else
        log_error "Échec du commit"
        return 1
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# PROMPTS DES TÂCHES (Directifs, pas de questions)
# -----------------------------------------------------------------------------
TASK_PO="MODE AUTONOME - AGIS MAINTENANT.

1. Lis $TASK_FILE et identifie les tâches non terminées (- [ ])
2. Sélectionne UNE SEULE tâche faisable en moins de 30 minutes
3. Crée le fichier $CURRENT_TASK_FILE avec ta décision (format spécifié dans ton persona)
4. NE POSE PAS DE QUESTION - décide et écris le fichier

Si aucune tâche actionnable: crée une tâche d'amélioration technique."

TASK_ARCHITECT="MODE AUTONOME - AGIS MAINTENANT.

1. Lis $CURRENT_TASK_FILE pour connaître la tâche sélectionnée par le PO
2. Analyse si l'implémentation respecte Clean Architecture
3. Identifie les fichiers à créer/modifier
4. Ajoute une section '## Architecture' dans $CURRENT_TASK_FILE avec:
   - Les fichiers concernés
   - La couche de chaque fichier
   - Les patterns à utiliser
5. NE POSE PAS DE QUESTION - analyse et mets à jour le fichier"

TASK_IMPLEMENTER="MODE AUTONOME - AGIS MAINTENANT.

1. Lis $CURRENT_TASK_FILE pour connaître exactement ce que tu dois faire
2. Applique TDD strict:
   a) Écris le test qui échoue (RED)
   b) Écris le code minimal pour passer (GREEN)  
   c) Lance les tests pour vérifier
3. Implémente la fonctionnalité décrite dans $CURRENT_TASK_FILE
4. NE POSE PAS DE QUESTION - code directement"

TASK_REFACTORER="MODE AUTONOME - AGIS MAINTENANT.

1. Exécute: git diff HEAD~1 pour voir le code modifié
2. Identifie les code smells (Long Method, Feature Envy, etc.)
3. Si smell trouvé: refactorise-le (tests verts avant/après)
4. Si aucun smell: passe à l'étape suivante
5. NE POSE PAS DE QUESTION - refactorise ou passe"

TASK_QA="MODE AUTONOME - AGIS MAINTENANT.

1. Lis $CURRENT_TASK_FILE pour connaître ce qui a été implémenté
2. Lance les tests existants: npm test ou pytest
3. Identifie les edge cases non testés (null, empty, erreurs)
4. Écris les tests manquants
5. NE POSE PAS DE QUESTION - teste et corrige"

TASK_SECURITY="MODE AUTONOME - AGIS MAINTENANT.

1. Exécute: git diff HEAD~1 pour voir le code modifié
2. Cherche les vulnérabilités OWASP Top 10:
   - Injection (SQL, XSS, Command)
   - Secrets en dur
   - Auth faible
3. Si vulnérabilité Critical/High: corrige-la immédiatement
4. NE POSE PAS DE QUESTION - audite et corrige"

TASK_DOCUMENTER="MODE AUTONOME - AGIS MAINTENANT.

1. Lis $CURRENT_TASK_FILE pour savoir ce qui a été fait
2. Dans $TASK_FILE: transforme la ligne '- [ ] tâche' en '- [x] tâche ($(date +%Y-%m-%d))'
3. Si choix d'architecture fait: mets à jour $ARCHITECTURE_FILE
4. Supprime le fichier $CURRENT_TASK_FILE (rm $CURRENT_TASK_FILE)
5. NE POSE PAS DE QUESTION - documente et nettoie"

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

# Résoudre les conflits avec Claude
resolve_conflicts() {
    local conflict_file="${WORKTREE_DIR}/.conflicts"
    
    if [ ! -f "$conflict_file" ]; then
        return 0
    fi
    
    log_info "Résolution des conflits..."
    
    while IFS= read -r agent_id; do
        local worktree_path="${WORKTREE_DIR}/agent-${agent_id}"
        local branch_name=$(cd "$worktree_path" 2>/dev/null && git branch --show-current)
        
        if [ -z "$branch_name" ]; then
            continue
        fi
        
        log_info "Tentative de rebase pour agent-${agent_id}..."
        
        cd "$worktree_path" || continue
        
        # Rebase sur main
        if git rebase main 2>/dev/null; then
            log_success "Rebase réussi pour agent-${agent_id}"
            
            # Retour au repo principal pour merger
            cd "$(git rev-parse --show-toplevel)" || continue
            merge_worktree "$agent_id"
        else
            git rebase --abort 2>/dev/null
            log_error "Agent $agent_id: Conflit non résolu automatiquement"
            log_info "  → Résolution manuelle requise dans: $worktree_path"
        fi
    done < "$conflict_file"
    
    rm -f "$conflict_file"
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

# Boucle principale du mode parallèle
run_parallel_mode() {
    echo -e "${BOLD}${MAGENTA}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                                                                  ║"
    echo "║   🐝 CLAUDE SWARM - Mode Parallèle                               ║"
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
    
    # Ajuster le nombre d'agents si moins de tâches
    if [ "$num_tasks" -lt "$PARALLEL_AGENTS" ]; then
        PARALLEL_AGENTS=$num_tasks
        log_info "Ajusté à $PARALLEL_AGENTS agent(s)"
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
    
    echo -e "${GRAY}─────────────────────────────────────────────────────────────────${RESET}"
    echo -e "${GRAY}Refresh: 5s │ Ctrl+B puis n/p pour naviguer │ Ctrl+B d pour détacher${RESET}"
    echo -e "${GRAY}Heure: $(date '+%H:%M:%S')${RESET}"
    
    # Vérifier si tous terminés
    if [ -n "$total" ] && [ "$total" -gt 0 ] && [ "$done_count" -eq "$total" ] 2>/dev/null; then
        echo ""
        echo -e "${GREEN}${BOLD}🎉 Tous les agents ont terminé !${RESET}"
        echo -e "${CYAN}Les branches sont prêtes à être mergées.${RESET}"
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
        
        # Créer une fenêtre tmux pour cet agent
        log_info "Création fenêtre tmux agent-$i"
        tmux new-window -t "$SWARM_SESSION" -n "agent-$i"
        tmux send-keys -t "${SWARM_SESSION}:agent-$i" "bash '$agent_script'" Enter
        
        ((launched++))
    done
    
    if [ $launched -eq 0 ]; then
        log_error "Aucun agent n'a pu être lancé"
        tmux kill-session -t "$SWARM_SESSION" 2>/dev/null
        return 1
    fi
    
    log_success "Swarm lancé avec $launched agents"
    echo ""
    echo -e "${BOLD}${GREEN}Pour voir les agents:${RESET}"
    echo -e "  ${CYAN}tmux attach -t $SWARM_SESSION${RESET}"
    echo ""
    echo -e "${BOLD}Navigation tmux:${RESET}"
    echo -e "  ${GRAY}Ctrl+B puis 0/1/2...  - Aller à une fenêtre${RESET}"
    echo -e "  ${GRAY}Ctrl+B puis n         - Fenêtre suivante${RESET}"
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
    while [ "$all_done" = false ]; do
        sleep 10
        
        all_done=true
        local done_count=0
        
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
            else
                if [ -d "$worktree_path" ]; then
                    all_done=false
                fi
            fi
        done
        
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
main() {
    init
    
    echo -e "${BOLD}${GREEN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║   🚀 DEV CYCLE ULTRA                                         ║"
    echo "║   Autonome + SuperClaude Personas + Ralph Intelligence       ║"
    echo "║                                                              ║"
    echo "║   Logs: $LOG_FILE"
    echo "║   Rate: ${MAX_CALLS_PER_HOUR}/h | Mode: $([ "$TOKEN_EFFICIENT_MODE" = "true" ] && echo "Efficient" || echo "Standard")"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    
    draw_usage_dashboard
    
    local round=1
    
    while true; do
        # Vérifications avant cycle
        if ! check_quota; then
            echo -e "${RED}🛑 Quota critique - arrêt${RESET}"
            draw_usage_dashboard
            exit 1
        fi
        
        if check_task_completion; then
            echo -e "${GREEN}🎉 Projet terminé !${RESET}"
            draw_usage_dashboard
            exit 0
        fi
        
        if detect_no_changes; then
            echo -e "${YELLOW}💤 Arrêt intelligent - pas de progrès${RESET}"
            draw_usage_dashboard
            exit 0
        fi
        
        draw_cycle_header "$round"
        echo "--- CYCLE #$round : $(date) ---" >> "$LOG_FILE"
        
        # Pipeline complet avec personas experts
        
        # 1. Product Owner
        if ! run_step 1 "PRODUCT OWNER" "$PERSONA_PO" "$TASK_PO"; then
            log_error "Échec PO"; exit 1
        fi
        
        # 2. Architect
        if ! run_step 2 "ARCHITECT" "$PERSONA_ARCHITECT" "$TASK_ARCHITECT"; then
            log_error "Échec Architect"; exit 1
        fi
        
        # 3. Implementer
        if ! run_step 3 "IMPLEMENTER" "$PERSONA_IMPLEMENTER" "$TASK_IMPLEMENTER"; then
            log_error "Échec Implementer"; exit 1
        fi
        
        # 4. Refactorer
        if ! run_step 4 "REFACTORER" "$PERSONA_REFACTORER" "$TASK_REFACTORER"; then
            log_error "Échec Refactorer"; exit 1
        fi
        
        # 5. QA Engineer
        if ! run_step 5 "QA ENGINEER" "$PERSONA_QA" "$TASK_QA"; then
            log_error "Échec QA"; exit 1
        fi
        
        # 6. Security Auditor
        if ! run_step 6 "SECURITY AUDITOR" "$PERSONA_SECURITY" "$TASK_SECURITY"; then
            log_error "Échec Security"; exit 1
        fi
        
        # 7. Documenter
        if ! run_step 7 "DOCUMENTER" "$PERSONA_DOCUMENTER" "$TASK_DOCUMENTER"; then
            log_error "Échec Documenter"; exit 1
        fi
        
        # 8. Commiteur
        if ! run_commit_step 8; then
            log_error "Échec Commit"; exit 1
        fi
        
        draw_usage_dashboard
        
        echo ""
        echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════${RESET}"
        echo -e "${GREEN}✅ CYCLE #$round TERMINÉ${RESET}"
        echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════${RESET}"
        
        log_success "Cycle #$round terminé"
        ((round++))
        
        echo ""
        echo -e "${YELLOW}⏸${RESET}  Pause 5s... (Ctrl+C pour arrêter)"
        sleep 5
    done
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
        --token-efficient)
            TOKEN_EFFICIENT_MODE="true"
            shift
            ;;
        --max-calls)
            MAX_CALLS_PER_HOUR="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Modes:"
            echo "  (default)              Mode séquentiel (1 agent, pipeline complet)"
            echo "  --parallel, -p         Mode parallèle (N agents sur N tâches)"
            echo ""
            echo "Options mode parallèle:"
            echo "  --agents N, -a N       Nombre d'agents parallèles (défaut: 3)"
            echo ""
            echo "Options générales:"
            echo "  --token-efficient      Mode économie de tokens (réponses courtes)"
            echo "  --max-calls N          Limite d'appels par heure (défaut: 50)"
            echo "  --help, -h             Affiche cette aide"
            echo ""
            echo "Fichiers de contrôle:"
            echo "  TODO.md                Tâches du projet (1 par ligne: - [ ] tâche)"
            echo "  @fix_plan.md           Plan de correction prioritaire (optionnel)"
            echo "  @AGENT.md              Configuration agent (optionnel)"
            echo "  ARCHITECTURE.md        Documentation architecture"
            echo ""
            echo "Exemples:"
            echo "  $0                     # Mode normal, 1 tâche à la fois"
            echo "  $0 --parallel          # 3 agents parallèles sur 3 tâches"
            echo "  $0 -p -a 5             # 5 agents parallèles sur 5 tâches"
            echo "  $0 -p --token-efficient # Parallèle + économie tokens"
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
    main
fi
