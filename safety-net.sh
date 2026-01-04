#!/bin/bash

# =============================================================================
# SAFETY NET - Protection contre les commandes destructives
# =============================================================================
# Inspiré de claude-code-safety-net par kenryu42
# https://github.com/kenryu42/claude-code-safety-net
#
# Ce script intercepte les commandes avant exécution et bloque celles qui
# sont potentiellement destructives.
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
SAFETY_NET_VERSION="1.0.0"
SAFETY_NET_CONFIG_FILE=".safety-net.json"
SAFETY_NET_USER_CONFIG="${HOME}/.cc-safety-net/config.json"
SAFETY_NET_LOG_FILE="./logs/safety-net-$(date +%Y%m%d).log"

# Mode paranoid: bloque aussi les one-liners d'interpréteurs
PARANOID_MODE="${PARANOID_MODE:-false}"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------
log_safety() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    mkdir -p "$(dirname "$SAFETY_NET_LOG_FILE")"
    echo "[$timestamp] [$level] $message" >> "$SAFETY_NET_LOG_FILE"
}

# -----------------------------------------------------------------------------
# RÈGLES GIT DESTRUCTIVES
# -----------------------------------------------------------------------------
# Commandes git qui peuvent perdre du travail de manière irréversible

check_git_rules() {
    local cmd="$1"

    # git checkout -- (abandonne les modifications locales)
    if echo "$cmd" | grep -qE 'git\s+checkout\s+--\s'; then
        echo "BLOCK|git checkout --|Abandonne les modifications locales non committées"
        return 0
    fi

    # git reset --hard (perte de commits/modifications)
    if echo "$cmd" | grep -qE 'git\s+reset\s+--hard'; then
        echo "BLOCK|git reset --hard|Perte irréversible de commits et modifications"
        return 0
    fi

    # git clean -f (supprime fichiers non trackés)
    if echo "$cmd" | grep -qE 'git\s+clean\s+.*-[a-zA-Z]*f'; then
        echo "BLOCK|git clean -f|Supprime les fichiers non trackés"
        return 0
    fi

    # git push --force (réécrit l'historique distant)
    if echo "$cmd" | grep -qE 'git\s+push\s+.*--force|git\s+push\s+.*-f\s'; then
        echo "BLOCK|git push --force|Réécrit l'historique distant, peut perdre le travail d'autres"
        return 0
    fi

    # git branch -D (suppression forcée de branche)
    if echo "$cmd" | grep -qE 'git\s+branch\s+.*-D\s'; then
        echo "BLOCK|git branch -D|Suppression forcée de branche (même non mergée)"
        return 0
    fi

    # git stash drop/clear sans confirmation
    if echo "$cmd" | grep -qE 'git\s+stash\s+(drop|clear)'; then
        echo "BLOCK|git stash drop/clear|Perte potentielle de travail stashé"
        return 0
    fi

    # git rebase sans branche spécifiée sur main/master
    if echo "$cmd" | grep -qE 'git\s+rebase\s+(-i\s+)?(origin/)?(main|master)'; then
        echo "WARN|git rebase main/master|Attention: rebase sur branche principale"
        return 0
    fi

    echo "OK"
    return 0
}

# -----------------------------------------------------------------------------
# RÈGLES DE SUPPRESSION DE FICHIERS
# -----------------------------------------------------------------------------
# Commandes rm dangereuses

check_rm_rules() {
    local cmd="$1"

    # rm -rf / ou ~
    if echo "$cmd" | grep -qE 'rm\s+.*-[a-zA-Z]*r[a-zA-Z]*f.*\s+(/|~|/home|/Users|\$HOME)\s*$'; then
        echo "BLOCK|rm -rf /|Tentative de suppression du système de fichiers racine ou home"
        return 0
    fi

    # rm -rf /* (tout le système)
    if echo "$cmd" | grep -qE 'rm\s+.*-[a-zA-Z]*r[a-zA-Z]*f.*\s+/\*'; then
        echo "BLOCK|rm -rf /*|Tentative de suppression de tout le système"
        return 0
    fi

    # rm -rf avec des paths sensibles
    if echo "$cmd" | grep -qE 'rm\s+.*-[a-zA-Z]*r[a-zA-Z]*f.*\s+(/etc|/var|/usr|/bin|/sbin|/lib|/boot)'; then
        echo "BLOCK|rm -rf système|Tentative de suppression de répertoires système"
        return 0
    fi

    # rm -rf .git (perte du repo)
    if echo "$cmd" | grep -qE 'rm\s+.*-[a-zA-Z]*r[a-zA-Z]*f.*\s+\.git\s*$'; then
        echo "BLOCK|rm -rf .git|Suppression du répertoire git"
        return 0
    fi

    # rm -rf node_modules (souvent une erreur)
    if echo "$cmd" | grep -qE 'rm\s+.*-[a-zA-Z]*r[a-zA-Z]*f.*\s+node_modules\s*$'; then
        echo "WARN|rm -rf node_modules|Suppression de node_modules (long à réinstaller)"
        return 0
    fi

    echo "OK"
    return 0
}

# -----------------------------------------------------------------------------
# RÈGLES DE PIPES DANGEREUX
# -----------------------------------------------------------------------------
# Commandes avec pipes qui peuvent être destructives

check_pipe_rules() {
    local cmd="$1"

    # xargs rm -rf
    if echo "$cmd" | grep -qE '\|\s*xargs\s+.*rm\s+.*-[a-zA-Z]*r[a-zA-Z]*f'; then
        echo "BLOCK|xargs rm -rf|Suppression massive via xargs"
        return 0
    fi

    # find -delete en dehors de /tmp
    if echo "$cmd" | grep -qE 'find\s+[^/]*(/[^t]|/t[^m]|/tm[^p]).*-delete'; then
        echo "BLOCK|find -delete|Suppression massive via find hors /tmp"
        return 0
    fi

    # parallel rm
    if echo "$cmd" | grep -qE '\|\s*parallel\s+.*rm'; then
        echo "BLOCK|parallel rm|Suppression parallèle massive"
        return 0
    fi

    # > pour écraser des fichiers système
    if echo "$cmd" | grep -qE '>\s*(/etc/|/var/|/usr/)'; then
        echo "BLOCK|> fichier système|Écrasement de fichier système"
        return 0
    fi

    echo "OK"
    return 0
}

# -----------------------------------------------------------------------------
# RÈGLES MODE PARANOID
# -----------------------------------------------------------------------------
# Bloque les one-liners d'interpréteurs qui peuvent cacher des commandes

check_paranoid_rules() {
    local cmd="$1"

    if [ "$PARANOID_MODE" != "true" ]; then
        echo "OK"
        return 0
    fi

    # python -c
    if echo "$cmd" | grep -qE 'python[23]?\s+-c\s'; then
        echo "WARN|python -c|One-liner Python (mode paranoid)"
        return 0
    fi

    # node -e
    if echo "$cmd" | grep -qE 'node\s+-e\s'; then
        echo "WARN|node -e|One-liner Node.js (mode paranoid)"
        return 0
    fi

    # ruby -e
    if echo "$cmd" | grep -qE 'ruby\s+-e\s'; then
        echo "WARN|ruby -e|One-liner Ruby (mode paranoid)"
        return 0
    fi

    # perl -e
    if echo "$cmd" | grep -qE 'perl\s+-e\s'; then
        echo "WARN|perl -e|One-liner Perl (mode paranoid)"
        return 0
    fi

    # bash -c avec rm ou autre commande dangereuse
    if echo "$cmd" | grep -qE 'bash\s+-c\s.*rm\s'; then
        echo "BLOCK|bash -c rm|Commande rm cachée dans bash -c"
        return 0
    fi

    # eval (toujours dangereux)
    if echo "$cmd" | grep -qE '\beval\b'; then
        echo "WARN|eval|Utilisation de eval (potentiellement dangereux)"
        return 0
    fi

    echo "OK"
    return 0
}

# -----------------------------------------------------------------------------
# RÈGLES PERSONNALISÉES
# -----------------------------------------------------------------------------
# Charge et applique les règles depuis .safety-net.json

check_custom_rules() {
    local cmd="$1"
    local config_file=""

    # Chercher le fichier de config
    if [ -f "$SAFETY_NET_CONFIG_FILE" ]; then
        config_file="$SAFETY_NET_CONFIG_FILE"
    elif [ -f "$SAFETY_NET_USER_CONFIG" ]; then
        config_file="$SAFETY_NET_USER_CONFIG"
    fi

    if [ -z "$config_file" ] || ! command -v jq &>/dev/null; then
        echo "OK"
        return 0
    fi

    # Parser les règles avec jq
    local rules_count
    rules_count=$(jq -r '.rules | length // 0' "$config_file" 2>/dev/null)

    if [ "$rules_count" -eq 0 ]; then
        echo "OK"
        return 0
    fi

    for ((i=0; i<rules_count; i++)); do
        local rule_name rule_cmd rule_subcmd block_args reason
        rule_name=$(jq -r ".rules[$i].name // \"\"" "$config_file")
        rule_cmd=$(jq -r ".rules[$i].command // \"\"" "$config_file")
        rule_subcmd=$(jq -r ".rules[$i].subcommand // \"\"" "$config_file")
        reason=$(jq -r ".rules[$i].reason // \"Règle personnalisée\"" "$config_file")

        # Vérifier si la commande match
        if echo "$cmd" | grep -qE "^$rule_cmd\s+$rule_subcmd"; then
            # Vérifier les arguments bloqués
            local block_args_count
            block_args_count=$(jq -r ".rules[$i].block_args | length // 0" "$config_file")

            for ((j=0; j<block_args_count; j++)); do
                local blocked_arg
                blocked_arg=$(jq -r ".rules[$i].block_args[$j]" "$config_file")

                if echo "$cmd" | grep -qE "\s$blocked_arg(\s|$)"; then
                    echo "BLOCK|$rule_name|$reason"
                    return 0
                fi
            done
        fi
    done

    echo "OK"
    return 0
}

# -----------------------------------------------------------------------------
# FONCTION PRINCIPALE DE VÉRIFICATION
# -----------------------------------------------------------------------------
check_command() {
    local cmd="$1"
    local result

    # Skip si commande vide
    if [ -z "$cmd" ]; then
        echo '{"status": "OK", "command": ""}'
        return 0
    fi

    # Normaliser la commande (enlever espaces multiples)
    cmd=$(echo "$cmd" | tr -s ' ')

    # Appliquer les règles dans l'ordre
    local checks=("check_git_rules" "check_rm_rules" "check_pipe_rules" "check_paranoid_rules" "check_custom_rules")

    for check_fn in "${checks[@]}"; do
        result=$($check_fn "$cmd")

        if [ "$result" != "OK" ]; then
            local status rule reason
            status=$(echo "$result" | cut -d'|' -f1)
            rule=$(echo "$result" | cut -d'|' -f2)
            reason=$(echo "$result" | cut -d'|' -f3)

            log_safety "$status" "Command: $cmd | Rule: $rule | Reason: $reason"

            echo "{\"status\": \"$status\", \"rule\": \"$rule\", \"reason\": \"$reason\", \"command\": \"$cmd\"}"
            return 0
        fi
    done

    log_safety "OK" "Command allowed: $cmd"
    echo '{"status": "OK", "command": "'"$cmd"'"}'
    return 0
}

# -----------------------------------------------------------------------------
# INTERFACE CLI
# -----------------------------------------------------------------------------
show_help() {
    echo "Usage: $0 [options] <command>"
    echo ""
    echo "Safety Net - Protection contre les commandes destructives"
    echo "Version: $SAFETY_NET_VERSION"
    echo ""
    echo "Options:"
    echo "  --check <cmd>     Vérifie une commande"
    echo "  --paranoid        Active le mode paranoid"
    echo "  --list-rules      Liste toutes les règles actives"
    echo "  --test            Lance les tests intégrés"
    echo "  --help, -h        Affiche cette aide"
    echo ""
    echo "Configuration:"
    echo "  Projet:     $SAFETY_NET_CONFIG_FILE"
    echo "  Utilisateur: $SAFETY_NET_USER_CONFIG"
    echo ""
    echo "Exemple de configuration (.safety-net.json):"
    echo '  {'
    echo '    "version": 1,'
    echo '    "rules": ['
    echo '      {'
    echo '        "name": "block-git-add-all",'
    echo '        "command": "git",'
    echo '        "subcommand": "add",'
    echo '        "block_args": ["-A", "--all", "."],'
    echo '        "reason": "Utiliser git add <fichiers-spécifiques>"'
    echo '      }'
    echo '    ]'
    echo '  }'
}

list_rules() {
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}  🛡️  SAFETY NET - Règles actives${RESET}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${RESET}"
    echo ""

    echo -e "${BOLD}📦 Règles Git:${RESET}"
    echo "  • git checkout --     → Bloqué (abandonne modifications)"
    echo "  • git reset --hard    → Bloqué (perte irréversible)"
    echo "  • git clean -f        → Bloqué (supprime non trackés)"
    echo "  • git push --force    → Bloqué (réécrit historique)"
    echo "  • git branch -D       → Bloqué (suppression forcée)"
    echo "  • git stash drop/clear → Bloqué (perte de stash)"
    echo "  • git rebase main     → Avertissement"
    echo ""

    echo -e "${BOLD}🗑️  Règles Suppression:${RESET}"
    echo "  • rm -rf /            → Bloqué (racine)"
    echo "  • rm -rf ~            → Bloqué (home)"
    echo "  • rm -rf /etc,/var... → Bloqué (système)"
    echo "  • rm -rf .git         → Bloqué (repo git)"
    echo "  • rm -rf node_modules → Avertissement"
    echo ""

    echo -e "${BOLD}🔗 Règles Pipes:${RESET}"
    echo "  • xargs rm -rf        → Bloqué"
    echo "  • find -delete        → Bloqué (hors /tmp)"
    echo "  • parallel rm         → Bloqué"
    echo "  • > fichier système   → Bloqué"
    echo ""

    if [ "$PARANOID_MODE" = "true" ]; then
        echo -e "${BOLD}🔒 Mode Paranoid (actif):${RESET}"
        echo "  • python -c           → Avertissement"
        echo "  • node -e             → Avertissement"
        echo "  • ruby -e             → Avertissement"
        echo "  • perl -e             → Avertissement"
        echo "  • bash -c rm          → Bloqué"
        echo "  • eval                → Avertissement"
        echo ""
    fi

    # Règles personnalisées
    if [ -f "$SAFETY_NET_CONFIG_FILE" ] && command -v jq &>/dev/null; then
        local rules_count
        rules_count=$(jq -r '.rules | length // 0' "$SAFETY_NET_CONFIG_FILE" 2>/dev/null)

        if [ "$rules_count" -gt 0 ]; then
            echo -e "${BOLD}⚙️  Règles Personnalisées ($SAFETY_NET_CONFIG_FILE):${RESET}"
            for ((i=0; i<rules_count; i++)); do
                local name reason
                name=$(jq -r ".rules[$i].name" "$SAFETY_NET_CONFIG_FILE")
                reason=$(jq -r ".rules[$i].reason" "$SAFETY_NET_CONFIG_FILE")
                echo "  • $name → $reason"
            done
            echo ""
        fi
    fi
}

run_tests() {
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}  🧪 SAFETY NET - Tests${RESET}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${RESET}"
    echo ""

    local passed=0
    local failed=0

    test_command() {
        local cmd="$1"
        local expected="$2"
        local result

        result=$(check_command "$cmd" | jq -r '.status' 2>/dev/null)

        if [ "$result" = "$expected" ]; then
            echo -e "  ${GREEN}✓${RESET} $cmd → $expected"
            ((passed++))
        else
            echo -e "  ${RED}✗${RESET} $cmd → Expected $expected, got $result"
            ((failed++))
        fi
    }

    echo -e "${BOLD}Git Rules:${RESET}"
    test_command "git checkout -- ." "BLOCK"
    test_command "git checkout -b feature" "OK"
    test_command "git reset --hard HEAD" "BLOCK"
    test_command "git reset --soft HEAD" "OK"
    test_command "git push --force origin main" "BLOCK"
    test_command "git push origin main" "OK"
    test_command "git clean -fd" "BLOCK"
    test_command "git status" "OK"
    echo ""

    echo -e "${BOLD}Rm Rules:${RESET}"
    test_command "rm -rf /" "BLOCK"
    test_command "rm -rf ~" "BLOCK"
    test_command "rm -rf /etc" "BLOCK"
    test_command "rm -rf .git" "BLOCK"
    test_command "rm -rf ./temp" "OK"
    test_command "rm file.txt" "OK"
    echo ""

    echo -e "${BOLD}Pipe Rules:${RESET}"
    test_command "find /home -name '*.tmp' | xargs rm -rf" "BLOCK"
    test_command "find /tmp -name '*.tmp' -delete" "OK"
    test_command "ls | parallel rm" "BLOCK"
    test_command "echo test > /etc/passwd" "BLOCK"
    test_command "echo test > ./output.txt" "OK"
    echo ""

    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${RESET}"
    echo -e "  Résultats: ${GREEN}$passed passés${RESET}, ${RED}$failed échoués${RESET}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════${RESET}"

    return $failed
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
main() {
    case "${1:-}" in
        --check)
            shift
            check_command "$*"
            ;;
        --paranoid)
            PARANOID_MODE="true"
            shift
            check_command "$*"
            ;;
        --list-rules)
            list_rules
            ;;
        --test)
            run_tests
            ;;
        --help|-h)
            show_help
            ;;
        --version|-v)
            echo "Safety Net v$SAFETY_NET_VERSION"
            ;;
        *)
            # Mode par défaut: vérifier la commande
            if [ -n "${1:-}" ]; then
                check_command "$*"
            else
                show_help
            fi
            ;;
    esac
}

# Exécuter seulement si appelé directement (pas sourcé)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
