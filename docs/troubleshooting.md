# Troubleshooting / Dépannage

## Common Issues / Problèmes courants

---

### Claude CLI not found

**Error / Erreur:**
```
command not found: claude
```

**Solution:**
```bash
# Install Claude CLI / Installer Claude CLI
# Visit / Visiter: https://claude.ai/code

# Verify installation / Vérifier l'installation
claude --version
```

---

### Permission denied

**Error / Erreur:**
```
permission denied: ./claude-ultra.sh
```

**Solution:**
```bash
chmod +x claude-ultra.sh
```

---

### Not a Git repository

**Error / Erreur:**
```
⚠️  Ce dossier n'est pas un dépôt Git.
```

**Solution:**
```bash
git init
# or clone an existing repo / ou cloner un repo existant
```

---

### TODO.md not found

**Error / Erreur:**
```
Aucune tâche trouvée dans TODO.md
```

**Solution:**
Create a `TODO.md` file with tasks:
Créer un fichier `TODO.md` avec des tâches:

```markdown
# TODO

## En cours
- [ ] First task to implement
- [ ] Second task to implement

## Terminé
```

---

### Rate limit reached

**Error / Erreur:**
```
⏳ Rate limit atteint (50/50). Attente 1234s...
```

**Cause:** Too many API calls in one hour
**Cause:** Trop d'appels API en une heure

**Solutions:**
1. Wait for the cooldown / Attendre le cooldown
2. Increase limit / Augmenter la limite:
   ```bash
   MAX_CALLS_PER_HOUR=100 ./claude-ultra.sh
   ```

---

### Quota critical

**Error / Erreur:**
```
🛑 QUOTA SESSION CRITIQUE (95%)
```

**Cause:** API quota nearly exhausted
**Cause:** Quota API presque épuisé

**Solutions:**
1. Wait for quota reset (5h for session, 7d for weekly)
2. Adjust thresholds / Ajuster les seuils:
   ```bash
   QUOTA_STOP_SESSION=95 ./claude-ultra.sh
   ```

---

### tmux not installed (parallel mode)

**Error / Erreur:**
```
tmux requis pour le mode parallèle
```

**Solution:**
```bash
# macOS
brew install tmux

# Ubuntu/Debian
sudo apt install tmux

# Fedora
sudo dnf install tmux
```

---

### jq not installed

**Error / Erreur:**
```
jq: command not found
```

**Solution:**
```bash
# macOS
brew install jq

# Ubuntu/Debian
sudo apt install jq

# Fedora
sudo dnf install jq
```

---

### Worktree creation failed

**Error / Erreur:**
```
[worktree] ✗ Échec: fatal: 'agent-0/task' is already checked out
```

**Solution:**
```bash
# Clean up worktrees / Nettoyer les worktrees
rm -rf .worktrees
git worktree prune

# Delete orphan branches / Supprimer les branches orphelines
git branch | grep "agent-" | xargs git branch -D

# Retry / Réessayer
./claude-ultra.sh -p
```

---

### tmux session exists

**Error / Erreur:**
```
duplicate session: claude-swarm
```

**Solution:**
```bash
# Kill existing session / Tuer la session existante
tmux kill-session -t claude-swarm

# Retry / Réessayer
./claude-ultra.sh -p
```

---

### No changes detected (smart stop)

**Message:**
```
⚠️  3 cycles sans changements - arrêt intelligent
```

**Cause:** Pipeline ran 3 cycles without making any git changes
**Cause:** Le pipeline a tourné 3 cycles sans faire de changements git

**This is normal when:**
- All tasks are completed / Toutes les tâches sont terminées
- Tasks are blocked / Les tâches sont bloquées
- Claude couldn't make progress / Claude n'a pas pu progresser

**Solutions:**
1. Check `TODO.md` for remaining tasks
2. Check logs: `cat logs/dev-cycle-*.log`
3. Add more specific tasks to `TODO.md`

---

### OAuth token not found

**Error / Erreur:**
```
Quota monitoring unavailable
```

**Cause:** Claude CLI OAuth token not in keychain
**Cause:** Token OAuth de Claude CLI pas dans le keychain

**Solution:**
```bash
# Re-authenticate Claude CLI / Ré-authentifier Claude CLI
claude logout
claude login
```

---

### Merge conflicts not resolved

**Error / Erreur:**
```
Agent Merger n'a pas pu résoudre tous les conflits
```

**Cause:** Complex conflicts that AI couldn't resolve
**Cause:** Conflits complexes que l'IA n'a pas pu résoudre

**Solution:**
```bash
# Check conflict file / Vérifier le fichier de conflits
cat .worktrees/.conflicts

# Manually resolve in worktree / Résoudre manuellement dans le worktree
cd .worktrees/agent-X
git status
# Fix conflicts manually / Corriger les conflits manuellement
git add .
git commit

# Then merge from main repo / Puis fusionner depuis le repo principal
cd ../..
git merge agent-X/branch-name
```

---

## Logs / Journaux

### View today's log / Voir le log du jour

```bash
cat logs/dev-cycle-$(date +%Y%m%d).log
```

### Follow logs in real-time / Suivre les logs en temps réel

```bash
tail -f logs/dev-cycle-$(date +%Y%m%d).log
```

### Search for errors / Chercher les erreurs

```bash
grep -i "error\|échec\|fail" logs/dev-cycle-*.log
```

---

## Debug Mode / Mode debug

For verbose output, run with bash debug:
Pour une sortie verbeuse, exécuter avec debug bash:

```bash
bash -x ./claude-ultra.sh 2>&1 | tee debug.log
```

---

## Reset Everything / Tout réinitialiser

```bash
# Stop any running processes / Arrêter tous les processus
tmux kill-session -t claude-swarm 2>/dev/null

# Clean worktrees / Nettoyer les worktrees
rm -rf .worktrees
git worktree prune

# Clean control files / Nettoyer les fichiers de contrôle
rm -f @current_task.md @fix_plan.md

# Clean logs (optional) / Nettoyer les logs (optionnel)
rm -rf logs/

# Start fresh / Redémarrer proprement
./claude-ultra.sh
```

---

## Getting Help / Obtenir de l'aide

1. Check logs / Vérifier les logs
2. Run with `--help` / Exécuter avec `--help`
3. Open an issue on GitHub / Ouvrir une issue sur GitHub
