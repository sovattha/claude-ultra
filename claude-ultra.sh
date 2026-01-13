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

# Mode fast (1 appel Claude par cycle, style Ralph)
FAST_MODE="${FAST_MODE:-false}"

# -----------------------------------------------------------------------------
# AMÉLIORATIONS AUTONOMIE (Style Enterprise)
# -----------------------------------------------------------------------------
# Phase Specify: génère une spec automatique avant implémentation
SPECIFY_MODE="${SPECIFY_MODE:-false}"
SPEC_FILE="@spec.md"

# Self-validation: l'agent vérifie sa propre sortie
SELF_VALIDATE="${SELF_VALIDATE:-true}"

# Rollback automatique: revert si tests échouent après N tentatives
AUTO_ROLLBACK="${AUTO_ROLLBACK:-true}"
MAX_TEST_RETRIES=2
CURRENT_TEST_RETRIES=0

# Timeout pour l'exécution des tests (en secondes, 0 = pas de timeout)
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"  # 5 minutes par défaut

# Skip les tests (utile si les tests nécessitent une DB non disponible)
SKIP_TESTS="${SKIP_TESTS:-false}"

# Rapport de fin: génère un résumé des décisions
GENERATE_REPORT="${GENERATE_REPORT:-true}"
REPORT_FILE="@session-report.md"

# Tracking des décisions pour le rapport
declare -a SESSION_DECISIONS=()
declare -a SESSION_TASKS_COMPLETED=()
declare -a SESSION_ROLLBACKS=()

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
            # Vérifier s'il reste des tâches pendantes avant d'arrêter
            local pending_tasks=0
            if [ -f "$TASK_FILE" ]; then
                pending_tasks=$(grep -c "^[[:space:]]*- \[ \]" "$TASK_FILE" 2>/dev/null || echo "0")
            fi

            if [ "$pending_tasks" -gt 0 ]; then
                log_info "Pas de changements mais $pending_tasks tâche(s) restante(s) - on continue"
                echo -e "${YELLOW}⚠️  $MAX_CONSECUTIVE_NO_CHANGES cycles sans changements mais $pending_tasks tâche(s) restante(s)${RESET}"
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
                    # Marquer comme erreur potentielle, mais on vérifiera si du travail a été fait
                    exit_code=1
                fi
                ;;
        esac
    done

    local pipe_exit=${PIPESTATUS[0]:-0}

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

    # Logique de succès améliorée:
    # - Si Claude a produit une sortie significative (>100 chars), on considère que le travail est fait
    # - Même si is_error=true ou pipe_exit!=0, c'est souvent un faux positif
    # - On ne fail que si vraiment aucune sortie n'a été produite ET erreur signalée

    if [ "$output_size" -gt 100 ]; then
        # Travail significatif produit - succès même si erreur signalée
        if [ "$exit_code" -ne 0 ] || [ "$pipe_exit" -ne 0 ]; then
            echo -e "${YELLOW}⚠ Avertissement: erreur signalée mais travail effectué (${output_size} chars)${RESET}"
            log_info "Warning: $step_name signale une erreur mais a produit du travail"
        fi
        log_success "$step_name terminé (${duration}s)"
        return 0
    fi

    # Pas de sortie significative - vérifier les erreurs
    if [ "$exit_code" -ne 0 ] || [ "$pipe_exit" -ne 0 ]; then
        log_error "Échec: $step_name (${duration}s) - pas de sortie et erreur signalée"
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
5. MOCK OBLIGATOIRE: tous les tests doivent fonctionner SANS connexion DB/réseau
   - Mock Prisma, Supabase, fetch, et toute dépendance externe
   - Utilise vi.mock(), jest.mock() ou équivalent
6. NE POSE PAS DE QUESTION - teste et corrige"

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

# Fonction pour construire le prompt fast avec contexte
build_fast_prompt() {
    local context=""
    local fix_plan=""
    local agent_config=""
    local current_task=""

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

    # Liste des tâches
    local tasks=""
    if [ -f "$TASK_FILE" ]; then
        tasks="
TÂCHES DISPONIBLES ($TASK_FILE):
$(cat "$TASK_FILE")"
    fi

    echo "${FAST_PROMPT}
${context}
${fix_plan}
${agent_config}
${current_task}
${tasks}

${TOKEN_EFFICIENT_SUFFIX}

AGIS MAINTENANT. Choisis une tâche et implémente-la complètement."
}

# -----------------------------------------------------------------------------
# AMÉLIORATIONS AUTONOMIE - FONCTIONS
# -----------------------------------------------------------------------------

# Phase Specify: génère une spec automatique à partir de TODO.md
generate_spec() {
    if [ "$SPECIFY_MODE" != "true" ]; then
        return 0
    fi

    # Skip si spec existe déjà et est récente (< 1 heure)
    if [ -f "$SPEC_FILE" ]; then
        local spec_age=$(($(date +%s) - $(stat -f %m "$SPEC_FILE" 2>/dev/null || stat -c %Y "$SPEC_FILE" 2>/dev/null || echo 0)))
        if [ $spec_age -lt 3600 ]; then
            log_info "Spec existante (< 1h), réutilisation"
            return 0
        fi
    fi

    echo -e "${CYAN}📋 Génération de la spécification...${RESET}"

    local spec_prompt="Tu es un PRODUCT MANAGER Senior. Analyse le projet et génère une SPEC TECHNIQUE.

FICHIERS À ANALYSER:
- TODO.md: $(cat "$TASK_FILE" 2>/dev/null || echo "Vide")
- ARCHITECTURE.md: $(head -50 "$ARCHITECTURE_FILE" 2>/dev/null || echo "Non trouvé")

GÉNÈRE UNE SPEC AU FORMAT:

# Spécification du Projet

## Vue d'ensemble
[Résumé du projet en 2-3 phrases]

## Objectifs de la session
[Liste des tâches à accomplir, par priorité]

## Contraintes techniques
[Stack, patterns, règles à respecter]

## Critères de succès
[Comment savoir si c'est terminé]

## Risques identifiés
[Potentiels blocages et mitigations]

Écris UNIQUEMENT la spec, rien d'autre."

    local spec_result
    spec_result=$(claude -p $CLAUDE_FLAGS --output-format text "$spec_prompt" 2>/dev/null)

    if [ -n "$spec_result" ]; then
        echo "$spec_result" > "$SPEC_FILE"
        echo -e "${GREEN}✓ Spec générée: $SPEC_FILE${RESET}"
        track_decision "SPECIFY" "Spec générée automatiquement"
        log_success "Spec générée: $SPEC_FILE"
    else
        log_error "Échec génération spec"
    fi
}

# Self-validation: vérifie que la sortie est correcte
self_validate() {
    local task_description="$1"
    local changes_summary="$2"

    if [ "$SELF_VALIDATE" != "true" ]; then
        return 0
    fi

    echo -e "${CYAN}🔍 Auto-validation...${RESET}"

    local validate_prompt="Tu es un QA SENIOR. Vérifie si cette implémentation est correcte.

TÂCHE DEMANDÉE:
$task_description

CHANGEMENTS EFFECTUÉS:
$changes_summary

FICHIERS MODIFIÉS:
$(git diff --name-only HEAD~1 2>/dev/null | head -10)

DIFF RÉSUMÉ:
$(git diff --stat HEAD~1 2>/dev/null | tail -5)

VÉRIFIE:
1. La tâche est-elle complète?
2. Y a-t-il des bugs évidents?
3. Les tests passent-ils? (lance-les si nécessaire)
4. Le code respecte-t-il les standards?

RÉPONDS EN JSON:
{
  \"valid\": true/false,
  \"issues\": [\"issue1\", \"issue2\"],
  \"fixes_needed\": [\"fix1\", \"fix2\"],
  \"confidence\": 0-100
}

Si valid=false et fixes_needed non vide, applique les corrections toi-même."

    local validation_result
    validation_result=$(claude -p $CLAUDE_FLAGS --output-format text "$validate_prompt" 2>/dev/null)

    # Parser le résultat JSON
    local is_valid
    is_valid=$(echo "$validation_result" | jq -r '.valid // true' 2>/dev/null || echo "true")
    local confidence
    confidence=$(echo "$validation_result" | jq -r '.confidence // 80' 2>/dev/null || echo "80")

    if [ "$is_valid" = "true" ]; then
        echo -e "${GREEN}✓ Validation OK (confiance: ${confidence}%)${RESET}"
        track_decision "VALIDATE" "Auto-validation réussie (${confidence}%)"
        return 0
    else
        local issues
        issues=$(echo "$validation_result" | jq -r '.issues[]?' 2>/dev/null | head -3)
        echo -e "${YELLOW}⚠ Validation: issues détectées${RESET}"
        echo "$issues" | while read -r issue; do
            echo -e "  ${GRAY}└─ $issue${RESET}"
        done
        track_decision "VALIDATE" "Issues détectées: $issues"
        return 1
    fi
}

# Rollback automatique si tests échouent
auto_rollback() {
    local commit_to_revert="$1"

    if [ "$AUTO_ROLLBACK" != "true" ]; then
        return 0
    fi

    ((CURRENT_TEST_RETRIES++))

    if [ $CURRENT_TEST_RETRIES -ge $MAX_TEST_RETRIES ]; then
        echo -e "${RED}🔄 Rollback automatique après $MAX_TEST_RETRIES échecs${RESET}"

        if [ -n "$commit_to_revert" ]; then
            git revert --no-commit "$commit_to_revert" 2>/dev/null
            git checkout HEAD -- . 2>/dev/null

            local rollback_msg="Rollback: tests échoués après $MAX_TEST_RETRIES tentatives"
            SESSION_ROLLBACKS+=("$(date '+%H:%M:%S') - $rollback_msg")
            track_decision "ROLLBACK" "$rollback_msg"

            echo -e "${YELLOW}↩ Revert effectué, passage à la tâche suivante${RESET}"
            log_info "$rollback_msg"
        fi

        CURRENT_TEST_RETRIES=0
        return 1
    fi

    echo -e "${YELLOW}⚠ Tentative $CURRENT_TEST_RETRIES/$MAX_TEST_RETRIES${RESET}"
    return 0
}

# Exécuter les tests et gérer rollback
run_tests_with_rollback() {
    local commit_before="$1"

    # DEBUG: Entrée dans la fonction
    echo -e "${GRAY}[DEBUG] run_tests_with_rollback() appelée${RESET}"
    echo "[DEBUG] run_tests_with_rollback() started at $(date)" >> "$LOG_FILE"

    # Option pour skip les tests complètement
    if [ "$SKIP_TESTS" = "true" ]; then
        echo -e "${YELLOW}⏭ Tests ignorés (SKIP_TESTS=true)${RESET}"
        track_decision "TESTS" "Tests ignorés par configuration"
        CURRENT_TEST_RETRIES=0
        return 0
    fi

    # Détecter le type de projet et lancer les tests appropriés
    local test_cmd=""
    local test_result=0
    local test_framework=""

    if [ -f "package.json" ]; then
        if grep -q '"test"' package.json 2>/dev/null; then
            # Détecter le framework de test (Vitest vs Jest vs autres)
            if grep -qE '"vitest"|"@vitest"' package.json 2>/dev/null; then
                test_framework="vitest"
                # Vitest: utiliser --run pour mode non-interactif
                test_cmd="npm test -- --run --reporter=basic"
            elif grep -qE '"jest"|"@jest"' package.json 2>/dev/null; then
                test_framework="jest"
                # Jest: utiliser --watchAll=false et --ci
                test_cmd="npm test -- --watchAll=false --ci --passWithNoTests"
            else
                test_framework="unknown"
                # Fallback générique: essayer les deux syntaxes
                test_cmd="npm test -- --run 2>/dev/null || npm test -- --watchAll=false --ci 2>/dev/null || CI=true npm test"
            fi
            echo -e "${GRAY}[DEBUG] Framework détecté: $test_framework${RESET}"
            echo "[DEBUG] Test framework: $test_framework" >> "$LOG_FILE"
        fi
    elif [ -f "Cargo.toml" ]; then
        test_cmd="cargo test"
        test_framework="cargo"
    elif [ -f "go.mod" ]; then
        test_cmd="go test ./..."
        test_framework="go"
    elif [ -f "pytest.ini" ] || [ -f "setup.py" ] || [ -d "tests" ]; then
        test_cmd="pytest -q"
        test_framework="pytest"
    elif [ -f "Makefile" ] && grep -q "^test:" Makefile 2>/dev/null; then
        test_cmd="make test"
        test_framework="make"
    fi

    if [ -z "$test_cmd" ]; then
        # Pas de tests trouvés, considérer comme succès
        echo -e "${GRAY}[DEBUG] Aucune commande de test trouvée, skip${RESET}"
        CURRENT_TEST_RETRIES=0
        return 0
    fi

    echo -e "${CYAN}🧪 Exécution des tests: $test_cmd${RESET}"
    echo "[DEBUG] Running: $test_cmd" >> "$LOG_FILE"

    # Exécuter avec timeout si configuré
    local exit_code=0
    if [ "$TEST_TIMEOUT" -gt 0 ] 2>/dev/null; then
        echo -e "${GRAY}[DEBUG] Timeout configuré: ${TEST_TIMEOUT}s${RESET}"

        # Timeout cross-platform (macOS + Linux)
        # IMPORTANT: Fermer stdin avec < /dev/null pour éviter les blocages interactifs
        ( eval "$test_cmd" < /dev/null >> "$LOG_FILE" 2>&1 ) &
        local test_pid=$!
        local waited=0

        echo -e "${GRAY}[DEBUG] Test PID: $test_pid${RESET}"
        echo "[DEBUG] Test PID: $test_pid" >> "$LOG_FILE"

        while kill -0 $test_pid 2>/dev/null; do
            if [ $waited -ge "$TEST_TIMEOUT" ]; then
                echo -e "${GRAY}[DEBUG] Timeout atteint, killing PID $test_pid${RESET}"
                echo "[DEBUG] Timeout reached, killing PID $test_pid" >> "$LOG_FILE"

                # Tuer le processus et tous ses enfants
                pkill -P $test_pid 2>/dev/null || true
                kill -9 $test_pid 2>/dev/null || true
                wait $test_pid 2>/dev/null || true

                echo -e "${RED}✗ Tests timeout après ${TEST_TIMEOUT}s${RESET}"
                track_decision "TESTS" "Tests timeout après ${TEST_TIMEOUT}s: $test_cmd"
                if ! auto_rollback "$commit_before"; then
                    return 1
                fi
                return 2
            fi

            # Afficher la progression toutes les 10 secondes
            if [ $((waited % 10)) -eq 0 ] && [ $waited -gt 0 ]; then
                echo -e "${GRAY}[DEBUG] Tests en cours... ${waited}s/${TEST_TIMEOUT}s${RESET}"
            fi

            sleep 1
            ((waited++))
        done

        wait $test_pid
        exit_code=$?
        echo -e "${GRAY}[DEBUG] Tests terminés en ${waited}s avec code: $exit_code${RESET}"
        echo "[DEBUG] Tests finished in ${waited}s with exit code: $exit_code" >> "$LOG_FILE"
    else
        echo -e "${GRAY}[DEBUG] Exécution sans timeout${RESET}"
        # IMPORTANT: Fermer stdin avec < /dev/null pour éviter les blocages interactifs
        eval "$test_cmd" < /dev/null >> "$LOG_FILE" 2>&1
        exit_code=$?
        echo -e "${GRAY}[DEBUG] Tests terminés avec code: $exit_code${RESET}"
        echo "[DEBUG] Tests finished with exit code: $exit_code" >> "$LOG_FILE"
    fi

    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ Tests passés${RESET}"
        CURRENT_TEST_RETRIES=0
        track_decision "TESTS" "Tests passés: $test_cmd"
        return 0
    else
        echo -e "${RED}✗ Tests échoués (code: $exit_code)${RESET}"
        # Afficher les dernières lignes du log pour debug
        echo -e "${GRAY}[DEBUG] Dernières lignes du log:${RESET}"
        tail -20 "$LOG_FILE" 2>/dev/null | head -10

        track_decision "TESTS" "Tests échoués: $test_cmd"

        if ! auto_rollback "$commit_before"; then
            return 1
        fi
        return 2  # Retry possible
    fi
}

# Tracker une décision pour le rapport
track_decision() {
    local category="$1"
    local decision="$2"
    local timestamp
    timestamp=$(date '+%H:%M:%S')

    SESSION_DECISIONS+=("[$timestamp] [$category] $decision")
}

# Générer le rapport de session
generate_session_report() {
    if [ "$GENERATE_REPORT" != "true" ]; then
        return 0
    fi

    local end_time
    end_time=$(date '+%Y-%m-%d %H:%M:%S')
    local session_duration="$1"
    local tasks_count="$2"
    local loops_count="$3"

    echo -e "${CYAN}📊 Génération du rapport de session...${RESET}"

    cat > "$REPORT_FILE" << EOF
# Rapport de Session Claude Ultra

**Date:** $end_time
**Durée:** ${session_duration}
**Mode:** $([ "$FAST_MODE" = "true" ] && echo "Fast" || echo "Standard")

## Résumé

| Métrique | Valeur |
|----------|--------|
| Loops exécutés | $loops_count |
| Tâches complétées | $tasks_count |
| Quota utilisé | ${SESSION_QUOTA_PCT}% |
| Tokens entrée | ${SESSION_INPUT_TOKENS} |
| Tokens sortie | ${SESSION_OUTPUT_TOKENS} |

## Décisions prises

EOF

    # Ajouter les décisions
    if [ ${#SESSION_DECISIONS[@]} -gt 0 ]; then
        for decision in "${SESSION_DECISIONS[@]}"; do
            echo "- $decision" >> "$REPORT_FILE"
        done
    else
        echo "_Aucune décision trackée_" >> "$REPORT_FILE"
    fi

    # Ajouter les tâches complétées
    echo "" >> "$REPORT_FILE"
    echo "## Tâches complétées" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    # Extraire les tâches marquées [x] dans TODO.md
    if [ -f "$TASK_FILE" ]; then
        grep -E "^\s*- \[x\]" "$TASK_FILE" 2>/dev/null | head -20 | while read -r line; do
            echo "- $line" >> "$REPORT_FILE"
        done
    fi

    # Ajouter les rollbacks si présents
    if [ ${#SESSION_ROLLBACKS[@]} -gt 0 ]; then
        echo "" >> "$REPORT_FILE"
        echo "## Rollbacks effectués" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
        for rollback in "${SESSION_ROLLBACKS[@]}"; do
            echo "- ⚠️ $rollback" >> "$REPORT_FILE"
        done
    fi

    # Ajouter les commits de la session
    echo "" >> "$REPORT_FILE"
    echo "## Commits de la session" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    echo '```' >> "$REPORT_FILE"
    git log --oneline -20 --since="2 hours ago" 2>/dev/null >> "$REPORT_FILE" || echo "Aucun commit récent" >> "$REPORT_FILE"
    echo '```' >> "$REPORT_FILE"

    echo "" >> "$REPORT_FILE"
    echo "---" >> "$REPORT_FILE"
    echo "_Rapport généré automatiquement par Claude Ultra_" >> "$REPORT_FILE"

    echo -e "${GREEN}✓ Rapport généré: $REPORT_FILE${RESET}"
    log_success "Rapport de session: $REPORT_FILE"
}

# Prompt enrichi avec spec si disponible
build_fast_prompt_with_spec() {
    local base_prompt
    base_prompt=$(build_fast_prompt)

    # Ajouter la spec si disponible
    if [ -f "$SPEC_FILE" ]; then
        local spec_content
        spec_content=$(cat "$SPEC_FILE")
        echo "${base_prompt}

SPÉCIFICATION DU PROJET (@spec.md):
${spec_content}

Respecte cette spec dans ton implémentation."
    else
        echo "$base_prompt"
    fi
}

# -----------------------------------------------------------------------------
# MODE FAST - Boucle principale
# -----------------------------------------------------------------------------
run_fast_mode() {
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║   ⚡ MODE FAST - 1 appel = 1 tâche complète                  ║"
    echo "║   Style Ralph: prompt unifié, détection fin intelligente    ║"
    echo "║                                                              ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    printf "║   Specify: %-5s  Validate: %-5s  Rollback: %-5s  Report: %-5s║\n" \
        "$([ "$SPECIFY_MODE" = "true" ] && echo "ON" || echo "OFF")" \
        "$([ "$SELF_VALIDATE" = "true" ] && echo "ON" || echo "OFF")" \
        "$([ "$AUTO_ROLLBACK" = "true" ] && echo "ON" || echo "OFF")" \
        "$([ "$GENERATE_REPORT" = "true" ] && echo "ON" || echo "OFF")"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    draw_usage_dashboard

    # Phase Specify: générer spec automatique si activé
    generate_spec

    local loop=0
    local tasks_completed=0
    local start_time=$(date +%s)

    while true; do
        ((loop++))

        # Vérifications avant cycle
        if ! check_quota; then
            echo -e "${RED}🛑 Quota critique - arrêt${RESET}"
            break
        fi

        if check_task_completion; then
            echo -e "${GREEN}🎉 Toutes les tâches terminées !${RESET}"
            break
        fi

        if detect_no_changes; then
            echo -e "${YELLOW}💤 Arrêt intelligent - pas de progrès${RESET}"
            break
        fi

        # Rate limiting
        check_rate_limit

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
        full_prompt=$(build_fast_prompt_with_spec)

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

            # Auto-commit des changements non commités restants
            if [ "$has_uncommitted_changes" = true ]; then
                git add -A

                local diff_summary
                diff_summary=$(git diff --cached --stat | tail -3)

                if [ -n "$diff_summary" ]; then
                    local commit_message
                    commit_message=$(claude -p $CLAUDE_FLAGS --output-format text "Message commit conventionnel (1 ligne, format type(scope): desc) pour:
$diff_summary" 2>/dev/null | head -1 | tr -d '\n')

                    if [ -z "$commit_message" ]; then
                        commit_message="chore: fast-mode loop $loop"
                    fi

                    if git commit -m "$commit_message" >> "$LOG_FILE" 2>&1; then
                        local commit_hash=$(git rev-parse --short HEAD)
                        echo -e "${GREEN}📦 Commit:${RESET} $commit_message ${GRAY}($commit_hash)${RESET}"
                        log_success "Commit: $commit_message"
                        track_decision "COMMIT" "$commit_message"
                    fi
                fi
            fi

            # Tests avec rollback automatique
            local current_head
            current_head=$(git rev-parse HEAD 2>/dev/null || echo "")
            local test_result
            run_tests_with_rollback "$head_before"
            test_result=$?

            if [ $test_result -eq 1 ]; then
                # Rollback effectué, décrementer le compteur de tâches
                ((tasks_completed--)) || true
                continue
            fi

            # Self-validation (vérifie la qualité du travail)
            local current_task_desc=""
            if [ -f "$CURRENT_TASK_FILE" ]; then
                current_task_desc=$(head -10 "$CURRENT_TASK_FILE")
            fi
            self_validate "$current_task_desc" "$diff_summary"

        else
            echo -e "${YELLOW}ℹ Pas de changements ce loop${RESET}"
        fi

        # Stats
        local elapsed=$(($(date +%s) - start_time))
        local mins=$((elapsed / 60))
        local secs=$((elapsed % 60))

        echo ""
        echo -e "${GRAY}📊 Loop $loop | Tâches: $tasks_completed | Temps: ${mins}m${secs}s | Quota: ${SESSION_QUOTA_PCT}%${RESET}"

        # Pause courte
        echo -e "${YELLOW}⏸${RESET}  Pause 2s... (Ctrl+C pour arrêter)"
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

    # Générer le rapport de session
    generate_session_report "${total_mins}m${total_secs}s" "$tasks_completed" "$loop"
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
export FAST_MODE=${FAST_MODE:-false}

# Exécuter le script principal (copié dans le worktree)
if [ -f "./claude-ultra.sh" ]; then
    if [ "\$FAST_MODE" = "true" ]; then
        echo "Lancement de claude-ultra.sh en mode FAST..."
        ./claude-ultra.sh --fast
    else
        echo "Lancement de claude-ultra.sh..."
        ./claude-ultra.sh
    fi
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
    merge_prompt=$(build_prompt "$PERSONA_MERGER" "
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
\`\`\`")

    # Appeler Claude pour résoudre
    local tmp_response
    tmp_response=$(mktemp)

    check_rate_limit

    echo -e "${CYAN}  📤 Appel Agent Merger...${RESET}"

    local resolved_content
    resolved_content=$(claude -p $CLAUDE_FLAGS --output-format text "$merge_prompt" 2>/dev/null)

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
    local mode_label="Mode Parallèle"
    local mode_icon="🐝"
    if [ "$FAST_MODE" = "true" ]; then
        mode_label="Mode Parallèle + FAST ⚡"
        mode_icon="🚀"
    fi

    echo -e "${BOLD}${MAGENTA}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                                                                  ║"
    printf "║   %s CLAUDE SWARM - %-30s        ║\n" "$mode_icon" "$mode_label"
    echo "║                                                                  ║"
    echo "║   Agents: ${PARALLEL_AGENTS}                                                      ║"
    echo "║   Worktrees: ${WORKTREE_DIR}/                                          ║"
    if [ "$FAST_MODE" = "true" ]; then
    echo "║   Mode: FAST (1 appel unifié par agent)                         ║"
    fi
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
        --resume|-r)
            RESUME_MODE="true"
            shift
            ;;
        --token-efficient)
            TOKEN_EFFICIENT_MODE="true"
            shift
            ;;
        --fast|-f)
            FAST_MODE="true"
            shift
            ;;
        --specify|-s)
            SPECIFY_MODE="true"
            shift
            ;;
        --no-validate)
            SELF_VALIDATE="false"
            shift
            ;;
        --no-rollback)
            AUTO_ROLLBACK="false"
            shift
            ;;
        --no-report)
            GENERATE_REPORT="false"
            shift
            ;;
        --enterprise|-e)
            # Mode enterprise: active toutes les améliorations
            SPECIFY_MODE="true"
            SELF_VALIDATE="true"
            AUTO_ROLLBACK="true"
            GENERATE_REPORT="true"
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
            echo "  (default)              Mode séquentiel (1 agent, pipeline 8 étapes)"
            echo "  --fast, -f             Mode fast (1 appel = 1 tâche, ~7x plus rapide)"
            echo "  --parallel, -p         Mode parallèle (N agents sur N tâches)"
            echo "  --parallel --fast      Mode parallèle + fast (N agents rapides)"
            echo ""
            echo "Options mode parallèle:"
            echo "  --agents N, -a N       Nombre d'agents parallèles (défaut: 3)"
            echo "  --resume, -r           Reprendre les agents interrompus"
            echo ""
            echo "Options générales:"
            echo "  --token-efficient      Mode économie de tokens (réponses courtes)"
            echo "  --max-calls N          Limite d'appels par heure (défaut: 50)"
            echo "  --help, -h             Affiche cette aide"
            echo ""
            echo "Options autonomie (Enterprise):"
            echo "  --enterprise, -e       Active toutes les options ci-dessous"
            echo "  --specify, -s          Génère une spec automatique avant exécution"
            echo "  --no-validate          Désactive l'auto-validation après commit"
            echo "  --no-rollback          Désactive le rollback auto si tests échouent"
            echo "  --no-report            Désactive le rapport de session"
            echo ""
            echo "Fichiers de contrôle:"
            echo "  TODO.md                Tâches du projet (1 par ligne: - [ ] tâche)"
            echo "  @fix_plan.md           Plan de correction prioritaire (optionnel)"
            echo "  @AGENT.md              Configuration agent (optionnel)"
            echo "  ARCHITECTURE.md        Documentation architecture"
            echo ""
            echo "Fichiers générés (mode Enterprise):"
            echo "  @spec.md               Spécification générée automatiquement"
            echo "  @session-report.md     Rapport de session avec décisions"
            echo ""
            echo "Agent Merger (mode parallèle):"
            echo "  Quand des conflits Git surviennent entre branches parallèles,"
            echo "  l'Agent Merger utilise Claude pour résoudre intelligemment"
            echo "  les conflits en préservant les fonctionnalités des deux côtés."
            echo ""
            echo "Exemples:"
            echo "  $0                     # Mode normal, pipeline 8 étapes"
            echo "  $0 --fast              # Mode rapide, 1 appel/tâche (~7x plus rapide)"
            echo "  $0 --parallel          # 3 agents parallèles sur 3 tâches"
            echo "  $0 -p -a 5             # 5 agents parallèles sur 5 tâches"
            echo "  $0 -f --token-efficient # Fast + économie tokens"
            echo "  $0 -f -e               # Fast + Enterprise (spec + validation + rollback + rapport)"
            echo "  $0 -f --specify        # Fast avec génération de spec"
            echo "  $0 -p -f -e            # Parallèle + Fast + Enterprise (autonomie maximale)"
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
elif [ "$FAST_MODE" = "true" ]; then
    init
    run_fast_mode
else
    main
fi
