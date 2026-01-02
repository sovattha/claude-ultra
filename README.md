# Claude Ultra

Pipeline CI/CD autonome avec Claude AI pour le développement logiciel.

## Fonctionnalités

- **8 Personas experts** : Product Owner, Architect, Implementer, Refactorer, QA Engineer, Security Auditor, Documenter, Commiteur
- **Mode séquentiel** : Pipeline complet avec un agent
- **Mode parallèle** : Swarm de N agents sur N tâches via Git Worktrees + tmux
- **Agent Merger** : Résolution intelligente des conflits Git avec IA
- **Monitoring** : Suivi des quotas API (session 5h, hebdo 7j)
- **Rate limiting** : Protection contre le dépassement de quota
- **Détection intelligente** : Arrêt automatique quand plus de progrès

## Prérequis

- [Claude CLI](https://claude.ai/code) installé et configuré
- Git
- tmux (pour le mode parallèle)
- jq (pour le parsing JSON)

## Installation

```bash
git clone <repo-url>
cd claude-ultra
chmod +x claude-ultra.sh
```

## Utilisation

### Mode séquentiel (défaut)

```bash
./claude-ultra.sh
```

Exécute le pipeline complet sur une tâche à la fois depuis `TODO.md`.

### Mode parallèle

```bash
./claude-ultra.sh --parallel           # 3 agents par défaut
./claude-ultra.sh -p -a 5              # 5 agents parallèles
./claude-ultra.sh -p --token-efficient # Mode économie de tokens
```

### Options

| Option | Description |
|--------|-------------|
| `--parallel`, `-p` | Active le mode parallèle (swarm) |
| `--agents N`, `-a N` | Nombre d'agents parallèles (défaut: 3) |
| `--token-efficient` | Réponses courtes pour économiser les tokens |
| `--max-calls N` | Limite d'appels API par heure (défaut: 50) |
| `--help`, `-h` | Affiche l'aide |

## Fichiers de contrôle

| Fichier | Description |
|---------|-------------|
| `TODO.md` | Liste des tâches (`- [ ] Ma tâche`) |
| `@fix_plan.md` | Plan de correction prioritaire (optionnel) |
| `@AGENT.md` | Configuration agent personnalisée (optionnel) |
| `ARCHITECTURE.md` | Documentation architecture (auto-généré) |
| `@current_task.md` | Tâche en cours (généré par le PO) |

## Pipeline (Mode séquentiel)

```
1. Product Owner    → Sélectionne UNE tâche prioritaire
2. Architect        → Valide/enrichit l'architecture
3. Implementer      → Code en TDD (Red-Green-Refactor)
4. Refactorer       → Élimine les code smells
5. QA Engineer      → Tests edge cases
6. Security Auditor → Audit OWASP Top 10
7. Documenter       → Met à jour TODO.md et docs
8. Commiteur        → Commit conventionnel automatique
```

## Mode Parallèle (Swarm)

Le mode parallèle utilise Git Worktrees pour exécuter plusieurs agents simultanément :

1. Extrait N tâches de `TODO.md`
2. Crée N worktrees avec branches isolées
3. Lance N agents en parallèle via tmux
4. Fusionne les branches terminées
5. Résout les conflits avec l'Agent Merger (IA)

### Navigation tmux

- `Ctrl+B` puis `0/1/2...` : Aller à une fenêtre
- `Ctrl+B` puis `n/p` : Fenêtre suivante/précédente
- `Ctrl+B` puis `d` : Détacher (agents continuent)

## Variables d'environnement

```bash
PARALLEL_MODE=true           # Active le mode parallèle
PARALLEL_AGENTS=3            # Nombre d'agents
TOKEN_EFFICIENT_MODE=true    # Mode économie tokens
MAX_CALLS_PER_HOUR=50        # Limite rate limiting
QUOTA_WARN_SESSION=70        # Alerte quota session (%)
QUOTA_STOP_SESSION=90        # Stop quota session (%)
QUOTA_WARN_WEEKLY=80         # Alerte quota hebdo (%)
QUOTA_STOP_WEEKLY=95         # Stop quota hebdo (%)
```

## Intégration MCP

Les personas utilisent automatiquement les outils MCP disponibles :

- **Context7** : Documentation officielle des frameworks
- **Sequential-thinking** : Raisonnement complexe étape par étape
- **Playwright** : Tests E2E cross-browser
- **Chrome DevTools** : Debug performance, DOM, Network

## Credits

Ce projet s'inspire de plusieurs approches excellentes :

- **[SuperClaude](https://github.com/NomenAK/SuperClaude)** - Personas experts, mode token-efficient, approche evidence-based
- **[Ralph](https://github.com/rvanmarkus/ralph)** - Détection intelligente de fin de tâche, rate limiting, fichiers de contrôle `@`

Merci à ces projets pour leurs idées et patterns !

## Licence

MIT
