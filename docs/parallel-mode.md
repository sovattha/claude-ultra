# Parallel Mode / Mode Parallèle

## Overview / Vue d'ensemble

Parallel mode (Swarm) allows running multiple Claude agents simultaneously on different tasks using Git Worktrees.

Le mode parallèle (Swarm) permet d'exécuter plusieurs agents Claude simultanément sur différentes tâches via Git Worktrees.

---

## How It Works / Comment ça fonctionne

### 1. Task Extraction / Extraction des tâches

```bash
# From TODO.md / Depuis TODO.md
- [ ] Implement user authentication    → Agent 0
- [ ] Add payment integration          → Agent 1
- [ ] Create dashboard widgets         → Agent 2
```

### 2. Worktree Creation / Création des worktrees

Each agent gets its own isolated workspace:
Chaque agent obtient son propre espace de travail isolé:

```
.worktrees/
├── agent-0/              # Branch: agent-0/implement-user-auth
│   ├── TODO.md           # Only task 1
│   ├── claude-ultra.sh
│   └── ...
├── agent-1/              # Branch: agent-1/add-payment-integration
│   ├── TODO.md           # Only task 2
│   └── ...
└── agent-2/              # Branch: agent-2/create-dashboard-widgets
    ├── TODO.md           # Only task 3
    └── ...
```

### 3. Parallel Execution / Exécution parallèle

```
┌─────────────────────────────────────────────────────────┐
│                    tmux session                          │
├─────────────────────────────────────────────────────────┤
│  Window 0: monitor    │ Live dashboard with status      │
│  Window 1: agent-0    │ Claude working on task 1        │
│  Window 2: agent-1    │ Claude working on task 2        │
│  Window 3: agent-2    │ Claude working on task 3        │
└─────────────────────────────────────────────────────────┘
```

### 4. Merge & Conflict Resolution / Fusion et résolution de conflits

```
agent-0/branch ──┐
                 ├──▶ Merger Agent ──▶ main ✓
agent-1/branch ──┤         │
                 │    (AI conflict
agent-2/branch ──┘     resolution)
```

---

## Usage / Utilisation

### Basic / Basique

```bash
# 3 agents by default / 3 agents par défaut
./claude-ultra.sh --parallel
./claude-ultra.sh -p
```

### Custom agent count / Nombre d'agents personnalisé

```bash
# 5 parallel agents / 5 agents parallèles
./claude-ultra.sh -p -a 5
./claude-ultra.sh --parallel --agents 5
```

### With token saving / Avec économie de tokens

```bash
./claude-ultra.sh -p --token-efficient
```

---

## tmux Navigation

| Keys | Action |
|------|--------|
| `Ctrl+B` then `0` | Go to monitor window |
| `Ctrl+B` then `1/2/3...` | Go to agent window |
| `Ctrl+B` then `n` | Next window |
| `Ctrl+B` then `p` | Previous window |
| `Ctrl+B` then `d` | Detach (agents continue) |

### Reattach / Rattacher

```bash
tmux attach -t claude-swarm
```

---

## Monitor Dashboard

```
╔══════════════════════════════════════════════════════════════════╗
║              🐝 CLAUDE SWARM - MONITOR                           ║
╚══════════════════════════════════════════════════════════════════╝

📊 Status des Agents:

  ✅ Agent 0: Terminé    │ Implement user authentication
  ⏳ Agent 1: Running    │ Add payment integration
  ⏳ Agent 2: Running    │ Create dashboard widgets

📈 Progression:
  █████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░ 33% (1/3)

🔀 Agent Merger:
  ✅ Aucun conflit

─────────────────────────────────────────────────────────────────
Refresh: 5s │ Ctrl+B puis n/p pour naviguer │ Ctrl+B d pour détacher
```

---

## Merger Agent / Agent de fusion

### When conflicts occur / Quand des conflits surviennent

The Merger Agent uses Claude AI to intelligently resolve Git conflicts:

L'Agent Merger utilise Claude AI pour résoudre intelligemment les conflits Git:

1. **Analyze** both versions / Analyser les deux versions
2. **Understand** intent of each branch / Comprendre l'intention de chaque branche
3. **Combine** or choose best solution / Combiner ou choisir la meilleure solution
4. **Validate** code compiles and works / Valider que le code compile et fonctionne

### Example / Exemple

**Conflict / Conflit:**
```javascript
<<<<<<< HEAD
function getUser(id) {
  return db.findById(id);
}
=======
async function getUser(id) {
  const user = await api.fetchUser(id);
  return user;
}
>>>>>>> agent-1/add-api-integration
```

**Merged by AI / Fusionné par IA:**
```javascript
async function getUser(id, source = 'db') {
  if (source === 'api') {
    return await api.fetchUser(id);
  }
  return db.findById(id);
}
```

---

## Cleanup / Nettoyage

### Automatic / Automatique

Worktrees are automatically cleaned after successful merge.
Les worktrees sont automatiquement nettoyés après une fusion réussie.

### Manual / Manuel

```bash
# List worktrees / Lister les worktrees
git worktree list

# Remove specific worktree / Supprimer un worktree spécifique
git worktree remove .worktrees/agent-0 --force

# Prune stale worktrees / Nettoyer les worktrees obsolètes
git worktree prune
```

---

## Troubleshooting / Dépannage

### tmux session already exists

```bash
tmux kill-session -t claude-swarm
./claude-ultra.sh -p
```

### Worktree creation fails

```bash
# Clean up and retry / Nettoyer et réessayer
rm -rf .worktrees
git worktree prune
./claude-ultra.sh -p
```

### Branch already exists

```bash
# Delete orphan branches / Supprimer les branches orphelines
git branch -D agent-0/task-name
```

---

## Best Practices / Bonnes pratiques

1. **Independent tasks** / Tâches indépendantes
   - Choose tasks that don't modify the same files
   - Choisir des tâches qui ne modifient pas les mêmes fichiers

2. **Reasonable agent count** / Nombre d'agents raisonnable
   - 3-5 agents is usually optimal
   - 3-5 agents est généralement optimal

3. **Monitor quotas** / Surveiller les quotas
   - Parallel mode consumes more API quota
   - Le mode parallèle consomme plus de quota API

4. **Start small** / Commencer petit
   - Test with 2 agents first
   - Tester d'abord avec 2 agents
